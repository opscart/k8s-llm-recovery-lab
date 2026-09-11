#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE=llm-recovery-lab
DEPLOYMENT=vllm-qwen25-coder-14b-awq
SERVICE=vllm-qwen25-coder
SERVED_MODEL=qwen2.5-coder-14b-awq
LOCAL_PORT="${LOCAL_PORT:-18000}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-600}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_cmd curl
require_cmd kubectl
require_cmd nvidia-smi
require_cmd python3

[[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || fail "LOCAL_PORT must be an integer"
(( LOCAL_PORT >= 1024 && LOCAL_PORT <= 65535 )) || fail "LOCAL_PORT must be between 1024 and 65535"
[[ "$REQUEST_TIMEOUT" =~ ^[0-9]+$ ]] || fail "REQUEST_TIMEOUT must be an integer number of seconds"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "RUN_ID contains unsupported characters"

if [[ -z "${KUBECONFIG:-}" && -r /etc/kubernetes/admin.conf ]]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/results/vllm-smoke/$RUN_ID}"
mkdir -p "$OUTPUT_DIR"

PORT_FORWARD_LOG="$OUTPUT_DIR/port-forward.log"
VLLM_LOG="$OUTPUT_DIR/vllm-log-tail.txt"
PF_PID=""

cleanup() {
  status=$?

  if [[ "$status" -ne 0 ]]; then
    kubectl logs "deployment/$DEPLOYMENT" -n "$NAMESPACE" --tail=120 >"$VLLM_LOG" 2>&1 || true
    echo "Failure diagnostics: $VLLM_LOG" >&2
  fi

  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" 2>/dev/null || true
  fi

  exit "$status"
}
trap cleanup EXIT

kubectl rollout status "deployment/$DEPLOYMENT" -n "$NAMESPACE" --timeout=10s >/dev/null \
  || fail "vLLM deployment is not Ready"

POD="$(kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || fail "vLLM pod was not found"

cat >"$OUTPUT_DIR/request.json" <<'JSON'
{
  "model": "qwen2.5-coder-14b-awq",
  "temperature": 0,
  "max_tokens": 500,
  "stream": false,
  "messages": [
    {
      "role": "system",
      "content": "You are a cautious Kubernetes code reviewer. Use only the supplied manifest. Prefer minimal, actionable changes and never claim that you changed a cluster."
    },
    {
      "role": "user",
      "content": "Review this non-production Deployment and identify exactly three highest-priority operational risks. For each risk, state the evidence and one minimal fix. Do not use Markdown.\n\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: payments-api\nspec:\n  replicas: 1\n  selector:\n    matchLabels:\n      app: payments-api\n  template:\n    metadata:\n      labels:\n        app: payments-api\n    spec:\n      containers:\n        - name: api\n          image: ghcr.io/example/payments:latest\n          securityContext:\n            privileged: true"
    }
  ]
}
JSON

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "namespace=$NAMESPACE"
  echo "deployment=$DEPLOYMENT"
  echo "pod=$POD"
  echo "served_model=$SERVED_MODEL"
  echo "git_commit=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unavailable)"
} >"$OUTPUT_DIR/run-metadata.txt"

kubectl get pod "$POD" -n "$NAMESPACE" -o yaml >"$OUTPUT_DIR/pod.yaml"
nvidia-smi --query-gpu=name,uuid,driver_version,memory.total,memory.used,memory.free,utilization.gpu \
  --format=csv,noheader >"$OUTPUT_DIR/gpu-before.csv"

python3 - "$LOCAL_PORT" <<'PY'
import socket
import sys

port = int(sys.argv[1])
try:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", port))
except OSError as error:
    raise SystemExit(f"local port {port} is unavailable: {error}") from None
PY

kubectl port-forward "service/$SERVICE" "$LOCAL_PORT:8000" -n "$NAMESPACE" \
  --address 127.0.0.1 >"$PORT_FORWARD_LOG" 2>&1 &
PF_PID=$!

HEALTHY=false
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$LOCAL_PORT/health" >/dev/null 2>&1; then
    HEALTHY=true
    break
  fi

  kill -0 "$PF_PID" >/dev/null 2>&1 || break
  sleep 1
done

if [[ "$HEALTHY" != "true" ]]; then
  sed -n '1,80p' "$PORT_FORWARD_LOG" >&2 || true
  fail "the local vLLM health endpoint did not become reachable"
fi

curl --fail-with-body -sS --max-time 30 \
  "http://127.0.0.1:$LOCAL_PORT/v1/models" \
  -o "$OUTPUT_DIR/models.json"

curl --fail-with-body -sS --max-time "$REQUEST_TIMEOUT" \
  -H 'Content-Type: application/json' \
  --data-binary "@$OUTPUT_DIR/request.json" \
  "http://127.0.0.1:$LOCAL_PORT/v1/chat/completions" \
  -o "$OUTPUT_DIR/response.json"

python3 - "$SERVED_MODEL" "$OUTPUT_DIR/models.json" "$OUTPUT_DIR/response.json" "$OUTPUT_DIR/answer.txt" <<'PY'
import json
import pathlib
import sys

served_model, models_path, response_path, answer_path = sys.argv[1:]

with open(models_path, encoding="utf-8") as handle:
    models = json.load(handle)

model_ids = [item.get("id") for item in models.get("data", [])]
if served_model not in model_ids:
    raise SystemExit(f"served model not reported by /v1/models: {model_ids}")

with open(response_path, encoding="utf-8") as handle:
    response = json.load(handle)

choices = response.get("choices", [])
if not choices:
    raise SystemExit("chat completion returned no choices")

answer = choices[0].get("message", {}).get("content", "").strip()
if not answer:
    raise SystemExit("chat completion returned an empty answer")

finish_reason = choices[0].get("finish_reason")
if finish_reason != "stop":
    raise SystemExit(f"chat completion did not finish cleanly: {finish_reason}")

pathlib.Path(answer_path).write_text(answer + "\n", encoding="utf-8")
print(f"model={response.get('model', 'unknown')}")
print(f"finish_reason={finish_reason}")
print(f"answer_characters={len(answer)}")
print(f"usage={json.dumps(response.get('usage', {}), sort_keys=True)}")
PY

nvidia-smi --query-gpu=name,uuid,driver_version,memory.total,memory.used,memory.free,utilization.gpu \
  --format=csv,noheader >"$OUTPUT_DIR/gpu-after.csv"
kubectl logs "deployment/$DEPLOYMENT" -n "$NAMESPACE" --tail=120 >"$VLLM_LOG" 2>&1 || true

echo
echo "Controlled inference succeeded."
echo "Evidence directory: $OUTPUT_DIR"
echo "Review the answer at: $OUTPUT_DIR/answer.txt"
echo "After preserving the evidence, deallocate the VM with:"
echo "  scripts/cloud/azure/deallocate-gpu-vm.sh"
