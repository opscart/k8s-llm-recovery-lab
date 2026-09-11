#!/usr/bin/env bash

set -euo pipefail

NAMESPACE=llm-recovery-lab
MODEL_MOUNT=/var/lib/llm-recovery/ollama
MIN_FREE_GIB="${MIN_FREE_GIB:-20}"
STAGE_TIMEOUT="${STAGE_TIMEOUT:-45m}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

[[ "${EUID}" -eq 0 ]] || fail "run with sudo"

require_cmd df
require_cmd findmnt
require_cmd kubectl

[[ -d "$MODEL_MOUNT" ]] || fail "model mount directory does not exist: $MODEL_MOUNT"

MOUNT_DETAILS="$(findmnt -rn -M "$MODEL_MOUNT" -o TARGET,SOURCE,FSTYPE || true)"
[[ -n "$MOUNT_DETAILS" ]] || fail "$MODEL_MOUNT is not a mounted filesystem; refusing to download the model to the OS disk"

[[ "$MIN_FREE_GIB" =~ ^[0-9]+$ ]] || fail "MIN_FREE_GIB must be an integer"
AVAILABLE_KIB="$(df --output=avail -k "$MODEL_MOUNT" | awk 'NR == 2 {print $1}')"
REQUIRED_KIB=$((MIN_FREE_GIB * 1024 * 1024))
(( AVAILABLE_KIB >= REQUIRED_KIB )) || fail "model disk has less than ${MIN_FREE_GIB} GiB free"

if [[ -z "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi
[[ -r "$KUBECONFIG" ]] || fail "KUBECONFIG is not readable: $KUBECONFIG"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STORAGE_MANIFEST="$REPO_ROOT/manifests/storage/qwen25-coder-gpu-local-pv.yaml"
CONFIG_MANIFEST="$REPO_ROOT/manifests/runtimes/vllm/qwen25-coder-14b-awq-config.yaml"
STAGE_MANIFEST="$REPO_ROOT/manifests/runtimes/vllm/qwen25-coder-14b-awq-stage.yaml"

for manifest in "$STORAGE_MANIFEST" "$CONFIG_MANIFEST" "$STAGE_MANIFEST"; do
  [[ -r "$manifest" ]] || fail "missing manifest: $manifest"
done

GPU_NODES="$(kubectl get nodes -l llm-recovery-role=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[[ "$GPU_NODES" == "1" ]] || fail "expected exactly one node labeled llm-recovery-role=gpu; found $GPU_NODES"

if kubectl get pv ollama-models-gpu >/dev/null 2>&1; then
  fail "ollama-models-gpu already exists and overlaps $MODEL_MOUNT; remove the unused Ollama PV before staging Qwen"
fi

echo "Qwen model staging plan"
echo "Namespace       : $NAMESPACE"
echo "Model mount     : $MODEL_MOUNT"
echo "Mounted storage : $MOUNT_DETAILS"
echo "Minimum free    : ${MIN_FREE_GIB} GiB"
echo "Timeout         : $STAGE_TIMEOUT"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$STORAGE_MANIFEST"
kubectl apply -f "$CONFIG_MANIFEST"

JOB_NAME=stage-qwen25-coder-14b-awq

if kubectl get job "$JOB_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  if kubectl wait --for=condition=Complete "job/$JOB_NAME" -n "$NAMESPACE" --timeout=1s >/dev/null 2>&1; then
    echo "Model staging Job already completed; reusing the pinned snapshot."
  elif kubectl wait --for=condition=Failed "job/$JOB_NAME" -n "$NAMESPACE" --timeout=1s >/dev/null 2>&1; then
    kubectl logs "job/$JOB_NAME" -n "$NAMESPACE" --all-containers=true >&2 || true
    fail "existing model staging Job failed; preserve its logs before deleting and retrying it"
  else
    echo "Model staging Job already exists; waiting for it."
  fi
else
  kubectl create -f "$STAGE_MANIFEST"
fi

kubectl wait --for=condition=Complete "job/$JOB_NAME" -n "$NAMESPACE" --timeout="$STAGE_TIMEOUT"
kubectl logs "job/$JOB_NAME" -n "$NAMESPACE" --all-containers=true

echo
echo "Model staging completed."
du -sh "$MODEL_MOUNT"
echo "The model server has not been started. The VM may be deallocated at this checkpoint."
