#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-recovery-lab}"
DEPLOYMENT="${DEPLOYMENT:-ollama}"
CLIENT_POD="${CLIENT_POD:-ollama-client}"
MODEL="${MODEL:-llama3.2:3b}"

SOURCE_NODE="${SOURCE_NODE:-}"
TARGET_NODE="${TARGET_NODE:-}"

OUT="${OUT:-results/cloud-cpu/ollama/llama3.2-3b/cold-node/node-b-recovery.csv}"

POD_READY_TIMEOUT_SECONDS="${POD_READY_TIMEOUT_SECONDS:-300}"
RUNTIME_TIMEOUT_SECONDS="${RUNTIME_TIMEOUT_SECONDS:-180}"

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

wait_for_new_ready_pod() {
  local old_pod="$1"
  local deadline=$((SECONDS + POD_READY_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    local pod
    pod=$(kubectl get pod -n "$NAMESPACE" -l app=ollama       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -n "$pod" && "$pod" != "$old_pod" ]]; then
      local phase
      local ready

      phase=$(kubectl get pod -n "$NAMESPACE" "$pod"         -o jsonpath='{.status.phase}' 2>/dev/null || true)

      ready=$(kubectl get pod -n "$NAMESPACE" "$pod"         -o jsonpath='{.status.containerStatuses[0].ready}'         2>/dev/null || true)

      if [[ "$phase" == "Running" && "$ready" == "true" ]]; then
        echo "$pod"
        return 0
      fi
    fi

    sleep 0.1
  done

  return 1
}

wait_for_runtime() {
  local deadline=$((SECONDS + RUNTIME_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    local http

    http=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" --       curl --connect-timeout 1 --max-time 2       -s -o /dev/null       -w "%{http_code}"       http://ollama:11434/api/tags       2>/dev/null || true)

    if [[ "$http" == "200" ]]; then
      return 0
    fi

    sleep 0.1
  done

  return 1
}

SOURCE_UNCORDON_NEEDED=false

cleanup() {
  if [[ "$SOURCE_UNCORDON_NEEDED" == "true" && -n "$SOURCE_NODE" ]]; then
    echo
    echo "Restoring scheduling on source node: $SOURCE_NODE"
    kubectl uncordon "$SOURCE_NODE" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

require_cmd kubectl
require_cmd python3

[[ -n "$SOURCE_NODE" ]] || fail "SOURCE_NODE is required"
[[ -n "$TARGET_NODE" ]] || fail "TARGET_NODE is required"
[[ "$SOURCE_NODE" != "$TARGET_NODE" ]] || fail "SOURCE_NODE and TARGET_NODE must differ"

kubectl get node "$SOURCE_NODE" >/dev/null 2>&1   || fail "source node not found: $SOURCE_NODE"

kubectl get node "$TARGET_NODE" >/dev/null 2>&1   || fail "target node not found: $TARGET_NODE"

SOURCE_READY=$(kubectl get node "$SOURCE_NODE"   -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

TARGET_READY=$(kubectl get node "$TARGET_NODE"   -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

[[ "$SOURCE_READY" == "True" ]]   || fail "source node is not Ready: $SOURCE_NODE"

[[ "$TARGET_READY" == "True" ]]   || fail "target node is not Ready: $TARGET_NODE"

OLD_POD=$(kubectl get pod -n "$NAMESPACE" -l app=ollama   -o jsonpath='{.items[0].metadata.name}')

[[ -n "$OLD_POD" ]] || fail "no Ollama pod found"

OLD_POD_NODE=$(kubectl get pod -n "$NAMESPACE" "$OLD_POD"   -o jsonpath='{.spec.nodeName}')

[[ "$OLD_POD_NODE" == "$SOURCE_NODE" ]] || fail   "current Ollama pod is on $OLD_POD_NODE, expected source node $SOURCE_NODE"

CLIENT_PHASE=$(kubectl get pod -n "$NAMESPACE" "$CLIENT_POD"   -o jsonpath='{.status.phase}' 2>/dev/null || true)

[[ "$CLIENT_PHASE" == "Running" ]]   || fail "client pod is not Running: $CLIENT_POD"

echo "Cold-node recovery validation"
echo "Source node : $SOURCE_NODE"
echo "Target node : $TARGET_NODE"
echo "Old pod     : $OLD_POD"
echo "Model       : $MODEL"

echo
echo "Checking source runtime state..."

SOURCE_MODEL_RESIDENT=false

if kubectl exec -n "$NAMESPACE" "$OLD_POD" -- ollama ps 2>/dev/null   | grep -Fq "$MODEL"; then
  SOURCE_MODEL_RESIDENT=true
fi

echo "Source model resident before failure: $SOURCE_MODEL_RESIDENT"

echo
echo "Cordoning source node before T0..."
kubectl cordon "$SOURCE_NODE" >/dev/null
SOURCE_UNCORDON_NEEDED=true

mkdir -p "$(dirname "$OUT")"

echo "run,recovery_condition,source_node,target_node,replacement_node,node_changed,source_model_resident_before_failure,artifact_present_before_inference,target_model_resident_before_inference,t0_delete_ms,t1_k8s_ready_ms,t2_runtime_ms,t3_inference_start_ms,t4_inference_done_ms,pod_recovery_ms,runtime_recovery_ms,ready_to_runtime_ms,functional_recovery_ms,ready_to_inference_ms,request_wall_ms,http_code,total_duration_ms,load_duration_ms,prompt_eval_duration_ms,eval_duration_ms,memory_current_bytes"   > "$OUT"

T0=$(now_ms)

kubectl delete pod -n "$NAMESPACE" "$OLD_POD"   --wait=false >/dev/null

echo "Waiting for replacement pod to become Kubernetes Ready..."

if ! NEW_POD=$(wait_for_new_ready_pod "$OLD_POD"); then
  echo
  echo "Replacement pod did not become Ready within ${POD_READY_TIMEOUT_SECONDS}s."
  kubectl get pods -n "$NAMESPACE" -o wide || true
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 30 || true
  fail "cold-node replacement did not become Ready"
fi

T1=$(now_ms)

REPLACEMENT_NODE=$(kubectl get pod -n "$NAMESPACE" "$NEW_POD"   -o jsonpath='{.spec.nodeName}')

NODE_CHANGED=false
if [[ "$REPLACEMENT_NODE" != "$SOURCE_NODE" ]]; then
  NODE_CHANGED=true
fi

[[ "$REPLACEMENT_NODE" == "$TARGET_NODE" ]] || fail   "replacement pod landed on $REPLACEMENT_NODE, expected target node $TARGET_NODE"

echo "New pod      : $NEW_POD"
echo "Replacement  : $REPLACEMENT_NODE"
echo "Node changed : $NODE_CHANGED"

echo
echo "Waiting for Ollama HTTP runtime..."

if ! wait_for_runtime; then
  fail "Ollama runtime did not become reachable within ${RUNTIME_TIMEOUT_SECONDS}s"
fi

T2=$(now_ms)

ARTIFACT_PRESENT=false

if kubectl exec -n "$NAMESPACE" "$NEW_POD" -- ollama list 2>/dev/null   | grep -Fq "$MODEL"; then
  ARTIFACT_PRESENT=true
fi

TARGET_MODEL_RESIDENT=false

if kubectl exec -n "$NAMESPACE" "$NEW_POD" -- ollama ps 2>/dev/null   | grep -Fq "$MODEL"; then
  TARGET_MODEL_RESIDENT=true
fi

echo
echo "Target pre-inference state"
echo "Artifact present : $ARTIFACT_PRESENT"
echo "Model resident   : $TARGET_MODEL_RESIDENT"

if [[ "$ARTIFACT_PRESENT" != "true" ]]; then
  fail "model artifact is not present on the target before first inference; this would mix cold-node recovery with cold model acquisition"
fi

echo
echo "Starting first post-relocation inference..."

T3=$(now_ms)

set +e
BODY=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" --   curl --max-time 180 -s   http://ollama:11434/api/generate   -H "Content-Type: application/json"   -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with exactly: READY\",\"stream\":false}")
CURL_RC=$?
set -e

T4=$(now_ms)

if [[ "$CURL_RC" -eq 0 ]] && echo "$BODY" | grep -q '"done":true'; then
  HTTP_CODE="200"
else
  HTTP_CODE="FAIL"
fi

TOTAL_NS=$(echo "$BODY"   | sed -n 's/.*"total_duration":\([0-9]*\).*/\1/p')

LOAD_NS=$(echo "$BODY"   | sed -n 's/.*"load_duration":\([0-9]*\).*/\1/p')

PROMPT_NS=$(echo "$BODY"   | sed -n 's/.*"prompt_eval_duration":\([0-9]*\).*/\1/p')

EVAL_NS=$(echo "$BODY"   | sed -n 's/.*"eval_duration":\([0-9]*\).*/\1/p')

TOTAL_MS=$(( ${TOTAL_NS:-0} / 1000000 ))
LOAD_MS=$(( ${LOAD_NS:-0} / 1000000 ))
PROMPT_MS=$(( ${PROMPT_NS:-0} / 1000000 ))
EVAL_MS=$(( ${EVAL_NS:-0} / 1000000 ))

POD_RECOVERY=$((T1 - T0))
RUNTIME_RECOVERY=$((T2 - T0))
READY_TO_RUNTIME=$((T2 - T1))
FUNCTIONAL_RECOVERY=$((T4 - T0))
READY_TO_INFERENCE=$((T4 - T1))
REQUEST_WALL=$((T4 - T3))

MEMORY_CURRENT=$(kubectl exec -n "$NAMESPACE" "$NEW_POD" --   cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)

echo
echo "Cold-node recovery result"
echo "  Source node            : $SOURCE_NODE"
echo "  Target node            : $TARGET_NODE"
echo "  Replacement node       : $REPLACEMENT_NODE"
echo "  Kubernetes Ready       : ${POD_RECOVERY} ms"
echo "  Runtime reachable      : ${RUNTIME_RECOVERY} ms"
echo "  Ready -> Runtime       : ${READY_TO_RUNTIME} ms"
echo "  Functional recovery    : ${FUNCTIONAL_RECOVERY} ms"
echo "  Ready -> Inference     : ${READY_TO_INFERENCE} ms"
echo "  Request wall time      : ${REQUEST_WALL} ms"
echo "  Ollama load            : ${LOAD_MS} ms"
echo "  Prompt evaluation      : ${PROMPT_MS} ms"
echo "  Token evaluation       : ${EVAL_MS} ms"
echo "  Ollama total           : ${TOTAL_MS} ms"
echo "  HTTP                   : ${HTTP_CODE}"
echo "  Memory after inference : ${MEMORY_CURRENT} bytes"

echo "1,cold-node,$SOURCE_NODE,$TARGET_NODE,$REPLACEMENT_NODE,$NODE_CHANGED,$SOURCE_MODEL_RESIDENT,$ARTIFACT_PRESENT,$TARGET_MODEL_RESIDENT,$T0,$T1,$T2,$T3,$T4,$POD_RECOVERY,$RUNTIME_RECOVERY,$READY_TO_RUNTIME,$FUNCTIONAL_RECOVERY,$READY_TO_INFERENCE,$REQUEST_WALL,$HTTP_CODE,$TOTAL_MS,$LOAD_MS,$PROMPT_MS,$EVAL_MS,$MEMORY_CURRENT"   >> "$OUT"

echo
echo "Result written to:"
echo "$OUT"

echo
echo "Important:"
echo "This script intentionally performs one measured relocation."
echo "A second run against the same target node is no longer a first-use cold-node condition."
