#!/usr/bin/env bash

set -euo pipefail

NAMESPACE=llm-recovery-lab
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-30m}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v kubectl >/dev/null 2>&1 || fail "required command not found: kubectl"

if [[ -z "${KUBECONFIG:-}" && -r /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_MANIFEST="$REPO_ROOT/manifests/runtimes/vllm/qwen25-coder-14b-awq.yaml"
[[ -r "$RUNTIME_MANIFEST" ]] || fail "missing manifest: $RUNTIME_MANIFEST"

JOB_NAME=stage-qwen25-coder-14b-awq
DEPLOYMENT_NAME=vllm-qwen25-coder-14b-awq

kubectl wait --for=condition=Complete "job/$JOB_NAME" -n "$NAMESPACE" --timeout=1s >/dev/null 2>&1 \
  || fail "the pinned model snapshot has not been staged; run scripts/cloud/stage-qwen25-coder-awq.sh first"

GPU="$(kubectl get nodes -l llm-recovery-role=gpu -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
[[ "$GPU" == "1" ]] || fail "the GPU node does not advertise nvidia.com/gpu=1"

echo "Deploying Qwen2.5-Coder-14B-Instruct-AWQ with vLLM"
echo "Namespace : $NAMESPACE"
echo "Timeout   : $ROLLOUT_TIMEOUT"

kubectl apply -f "$RUNTIME_MANIFEST"

if ! kubectl rollout status "deployment/$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"; then
  kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT_NAME" -o wide >&2 || true
  kubectl logs "deployment/$DEPLOYMENT_NAME" -n "$NAMESPACE" --tail=200 >&2 || true
  fail "vLLM deployment did not become Ready"
fi

kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE"
kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT_NAME" -o wide
kubectl get service vllm-qwen25-coder -n "$NAMESPACE"

echo
echo "vLLM is Ready inside the cluster."
echo "It is ClusterIP-only and is not exposed on the VM public IP."
echo "Next verification: inspect GPU memory, then run one controlled inference request."
