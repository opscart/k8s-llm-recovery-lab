#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-recovery-lab}"
DEPLOYMENT="${DEPLOYMENT:-ollama}"
CLIENT_POD="${CLIENT_POD:-ollama-client}"
MODEL="${MODEL:-llama3.2:3b}"

SOURCE_NODE="${SOURCE_NODE:-}"
TARGET_NODE="${TARGET_NODE:-}"

SOURCE_ROLE="${SOURCE_ROLE:-source}"
TARGET_ROLE="${TARGET_ROLE:-target}"

SOURCE_PVC="${SOURCE_PVC:-ollama-models-source}"
TARGET_PVC="${TARGET_PVC:-ollama-models-target}"

POD_SELECTOR="${POD_SELECTOR:-app=ollama,experiment=cold-node-recovery}"

OUT="${OUT:-results/cloud-cpu/ollama/llama3.2-3b/cold-node/node-b-recovery.csv}"

POD_READY_TIMEOUT_SECONDS="${POD_READY_TIMEOUT_SECONDS:-300}"
RUNTIME_TIMEOUT_SECONDS="${RUNTIME_TIMEOUT_SECONDS:-180}"
INFERENCE_TIMEOUT_SECONDS="${INFERENCE_TIMEOUT_SECONDS:-180}"

SOURCE_UNCORDON_NEEDED=false

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

cleanup() {
  if [[ "$SOURCE_UNCORDON_NEEDED" == "true" && -n "$SOURCE_NODE" ]]; then
    echo
    echo "Restoring scheduling on source node: $SOURCE_NODE"
    kubectl uncordon "$SOURCE_NODE" >/dev/null 2>&1 || true
  fi
}

wait_for_new_ready_pod() {
  local old_pod="$1"
  local deadline=$((SECONDS + POD_READY_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    while IFS= read -r pod; do
      [[ -n "$pod" ]] || continue
      [[ "$pod" != "$old_pod" ]] || continue

      local phase
      local ready
      local node

      phase=$(kubectl get pod -n "$NAMESPACE" "$pod" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)

      ready=$(kubectl get pod -n "$NAMESPACE" "$pod" \
        -o jsonpath='{.status.containerStatuses[0].ready}' \
        2>/dev/null || true)

      node=$(kubectl get pod -n "$NAMESPACE" "$pod" \
        -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)

      if [[ "$phase" == "Running" && "$ready" == "true" && "$node" == "$TARGET_NODE" ]]; then
        echo "$pod"
        return 0
      fi
    done < <(
      kubectl get pods -n "$NAMESPACE" -l "$POD_SELECTOR" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        2>/dev/null || true
    )

    sleep 0.1
  done

  return 1
}

wait_for_runtime() {
  local deadline=$((SECONDS + RUNTIME_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    local http

    http=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
      curl --connect-timeout 1 --max-time 2 \
      -s -o /dev/null \
      -w "%{http_code}" \
      http://ollama:11434/api/tags \
      2>/dev/null || true)

    if [[ "$http" == "200" ]]; then
      return 0
    fi

    sleep 0.1
  done

  return 1
}

trap cleanup EXIT

require_cmd kubectl
require_cmd python3
require_cmd sed
require_cmd grep

[[ -n "$SOURCE_NODE" ]] || fail "SOURCE_NODE is required"
[[ -n "$TARGET_NODE" ]] || fail "TARGET_NODE is required"
[[ "$SOURCE_NODE" != "$TARGET_NODE" ]] \
  || fail "SOURCE_NODE and TARGET_NODE must differ"

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || fail "namespace not found: $NAMESPACE"

kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" >/dev/null 2>&1 \
  || fail "deployment not found: $NAMESPACE/$DEPLOYMENT"

kubectl get pod -n "$NAMESPACE" "$CLIENT_POD" >/dev/null 2>&1 \
  || fail "client pod not found: $NAMESPACE/$CLIENT_POD"

kubectl get node "$SOURCE_NODE" >/dev/null 2>&1 \
  || fail "source node not found: $SOURCE_NODE"

kubectl get node "$TARGET_NODE" >/dev/null 2>&1 \
  || fail "target node not found: $TARGET_NODE"

kubectl get pvc -n "$NAMESPACE" "$SOURCE_PVC" >/dev/null 2>&1 \
  || fail "source PVC not found: $NAMESPACE/$SOURCE_PVC"

kubectl get pvc -n "$NAMESPACE" "$TARGET_PVC" >/dev/null 2>&1 \
  || fail "target PVC not found: $NAMESPACE/$TARGET_PVC"

SOURCE_READY=$(kubectl get node "$SOURCE_NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

TARGET_READY=$(kubectl get node "$TARGET_NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

[[ "$SOURCE_READY" == "True" ]] \
  || fail "source node is not Ready: $SOURCE_NODE"

[[ "$TARGET_READY" == "True" ]] \
  || fail "target node is not Ready: $TARGET_NODE"

SOURCE_PVC_PHASE=$(kubectl get pvc -n "$NAMESPACE" "$SOURCE_PVC" \
  -o jsonpath='{.status.phase}')

TARGET_PVC_PHASE=$(kubectl get pvc -n "$NAMESPACE" "$TARGET_PVC" \
  -o jsonpath='{.status.phase}')

[[ "$SOURCE_PVC_PHASE" == "Bound" ]] \
  || fail "source PVC is not Bound: $SOURCE_PVC"

[[ "$TARGET_PVC_PHASE" == "Bound" ]] \
  || fail "target PVC is not Bound: $TARGET_PVC"

CURRENT_ROLE=$(kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.nodeSelector.llm-recovery-role}' \
  2>/dev/null || true)

CURRENT_PVC=$(kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="models")].persistentVolumeClaim.claimName}' \
  2>/dev/null || true)

[[ "$CURRENT_ROLE" == "$SOURCE_ROLE" ]] || fail \
  "deployment is not in source state: role=$CURRENT_ROLE expected=$SOURCE_ROLE"

[[ "$CURRENT_PVC" == "$SOURCE_PVC" ]] || fail \
  "deployment is not using source PVC: pvc=$CURRENT_PVC expected=$SOURCE_PVC"

OLD_POD=$(kubectl get pods -n "$NAMESPACE" -l "$POD_SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

[[ -n "$OLD_POD" ]] || fail "no cold-node Ollama pod found"

OLD_POD_NODE=$(kubectl get pod -n "$NAMESPACE" "$OLD_POD" \
  -o jsonpath='{.spec.nodeName}')

[[ "$OLD_POD_NODE" == "$SOURCE_NODE" ]] || fail \
  "current Ollama pod is on $OLD_POD_NODE, expected source node $SOURCE_NODE"

OLD_POD_READY=$(kubectl get pod -n "$NAMESPACE" "$OLD_POD" \
  -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)

[[ "$OLD_POD_READY" == "true" ]] || fail \
  "source Ollama pod is not Ready: $OLD_POD"

CLIENT_PHASE=$(kubectl get pod -n "$NAMESPACE" "$CLIENT_POD" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)

[[ "$CLIENT_PHASE" == "Running" ]] \
  || fail "client pod is not Running: $CLIENT_POD"

echo "Cold-node recovery experiment"
echo "Namespace      : $NAMESPACE"
echo "Deployment     : $DEPLOYMENT"
echo "Model          : $MODEL"
echo "Source node    : $SOURCE_NODE"
echo "Target node    : $TARGET_NODE"
echo "Source PVC     : $SOURCE_PVC"
echo "Target PVC     : $TARGET_PVC"
echo "Old pod        : $OLD_POD"

echo
echo "Establishing active source-serving state before T0..."

SOURCE_ARTIFACT_PRESENT=false

if kubectl exec -n "$NAMESPACE" "$OLD_POD" -- ollama list 2>/dev/null \
  | grep -Fq "$MODEL"; then
  SOURCE_ARTIFACT_PRESENT=true
fi

[[ "$SOURCE_ARTIFACT_PRESENT" == "true" ]] || fail \
  "source model artifact is not present: $MODEL"

set +e
PREWARM_BODY=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
  curl --max-time "$INFERENCE_TIMEOUT_SECONDS" -s \
  http://ollama:11434/api/generate \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with exactly: WARM\",\"stream\":false}")
PREWARM_RC=$?
set -e

if [[ "$PREWARM_RC" -ne 0 ]] || ! echo "$PREWARM_BODY" | grep -q '"done":true'; then
  fail "source preconditioning inference failed"
fi

SOURCE_MODEL_RESIDENT=false

for _ in $(seq 1 30); do
  if kubectl exec -n "$NAMESPACE" "$OLD_POD" -- ollama ps 2>/dev/null \
    | grep -Fq "$MODEL"; then
    SOURCE_MODEL_RESIDENT=true
    break
  fi
  sleep 1
done

[[ "$SOURCE_MODEL_RESIDENT" == "true" ]] || fail \
  "source model did not become resident after preconditioning inference"

echo "Source artifact present before failure: $SOURCE_ARTIFACT_PRESENT"
echo "Source model resident before failure : $SOURCE_MODEL_RESIDENT"

echo
echo "Cordoning source node before measured transition..."
kubectl cordon "$SOURCE_NODE" >/dev/null
SOURCE_UNCORDON_NEEDED=true

mkdir -p "$(dirname "$OUT")"

echo "run,recovery_condition,source_node,target_node,replacement_node,node_changed,source_pvc,target_pvc,source_artifact_present_before_failure,source_model_resident_before_failure,target_artifact_present_before_inference,target_model_resident_before_inference,t0_transition_ms,t1_k8s_ready_ms,t2_runtime_ms,t3_inference_start_ms,t4_inference_done_ms,pod_recovery_ms,runtime_recovery_ms,ready_to_runtime_ms,functional_recovery_ms,ready_to_inference_ms,request_wall_ms,http_code,total_duration_ms,load_duration_ms,prompt_eval_duration_ms,eval_duration_ms,memory_current_bytes" \
  > "$OUT"

echo
echo "Starting measured source -> target transition..."

T0=$(now_ms)

PATCH=$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "nodeSelector": {
          "llm-recovery-role": "$TARGET_ROLE"
        },
        "volumes": [
          {
            "name": "models",
            "persistentVolumeClaim": {
              "claimName": "$TARGET_PVC"
            }
          }
        ]
      }
    }
  }
}
EOF
)

kubectl patch deployment -n "$NAMESPACE" "$DEPLOYMENT" \
  --type=strategic \
  -p "$PATCH" >/dev/null

echo "T0 captured immediately before Deployment patch."
echo "Waiting for replacement pod on target node to become Kubernetes Ready..."

if ! NEW_POD=$(wait_for_new_ready_pod "$OLD_POD"); then
  echo
  echo "Replacement pod did not become Ready within ${POD_READY_TIMEOUT_SECONDS}s."
  kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" -o wide || true
  kubectl get pods -n "$NAMESPACE" -o wide || true
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 40 || true
  fail "target replacement did not become Ready"
fi

T1=$(now_ms)

REPLACEMENT_NODE=$(kubectl get pod -n "$NAMESPACE" "$NEW_POD" \
  -o jsonpath='{.spec.nodeName}')

NODE_CHANGED=false

if [[ "$REPLACEMENT_NODE" != "$SOURCE_NODE" ]]; then
  NODE_CHANGED=true
fi

[[ "$REPLACEMENT_NODE" == "$TARGET_NODE" ]] || fail \
  "replacement pod landed on $REPLACEMENT_NODE, expected target node $TARGET_NODE"

NEW_POD_PVC=$(kubectl get pod -n "$NAMESPACE" "$NEW_POD" \
  -o jsonpath='{.spec.volumes[?(@.name=="models")].persistentVolumeClaim.claimName}')

[[ "$NEW_POD_PVC" == "$TARGET_PVC" ]] || fail \
  "replacement pod is using PVC $NEW_POD_PVC, expected $TARGET_PVC"

echo "New pod          : $NEW_POD"
echo "Replacement node : $REPLACEMENT_NODE"
echo "Replacement PVC  : $NEW_POD_PVC"
echo "Node changed     : $NODE_CHANGED"

echo
echo "Waiting for Ollama HTTP runtime..."

if ! wait_for_runtime; then
  fail "Ollama runtime did not become reachable within ${RUNTIME_TIMEOUT_SECONDS}s"
fi

T2=$(now_ms)

TARGET_ARTIFACT_PRESENT=false

if kubectl exec -n "$NAMESPACE" "$NEW_POD" -- ollama list 2>/dev/null \
  | grep -Fq "$MODEL"; then
  TARGET_ARTIFACT_PRESENT=true
fi

TARGET_MODEL_RESIDENT=false

if kubectl exec -n "$NAMESPACE" "$NEW_POD" -- ollama ps 2>/dev/null \
  | grep -Fq "$MODEL"; then
  TARGET_MODEL_RESIDENT=true
fi

echo
echo "Target pre-inference state"
echo "Artifact present : $TARGET_ARTIFACT_PRESENT"
echo "Model resident   : $TARGET_MODEL_RESIDENT"

[[ "$TARGET_ARTIFACT_PRESENT" == "true" ]] || fail \
  "model artifact is not present on target before first inference; refusing to mix cold-node recovery with model acquisition"

[[ "$TARGET_MODEL_RESIDENT" == "false" ]] || fail \
  "model is already resident on target before measured inference; target is not in the intended cold runtime state"

echo
echo "Starting first post-relocation inference..."

T3=$(now_ms)

set +e
BODY=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
  curl --max-time "$INFERENCE_TIMEOUT_SECONDS" -s \
  http://ollama:11434/api/generate \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with exactly: READY\",\"stream\":false}")
CURL_RC=$?
set -e

T4=$(now_ms)

if [[ "$CURL_RC" -eq 0 ]] && echo "$BODY" | grep -q '"done":true'; then
  HTTP_CODE="200"
else
  HTTP_CODE="FAIL"
fi

TOTAL_NS=$(echo "$BODY" \
  | sed -n 's/.*"total_duration":\([0-9]*\).*/\1/p')

LOAD_NS=$(echo "$BODY" \
  | sed -n 's/.*"load_duration":\([0-9]*\).*/\1/p')

PROMPT_NS=$(echo "$BODY" \
  | sed -n 's/.*"prompt_eval_duration":\([0-9]*\).*/\1/p')

EVAL_NS=$(echo "$BODY" \
  | sed -n 's/.*"eval_duration":\([0-9]*\).*/\1/p')

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

MEMORY_CURRENT=$(kubectl exec -n "$NAMESPACE" "$NEW_POD" -- \
  cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)

echo
echo "Cold-node recovery result"
echo "  Source node            : $SOURCE_NODE"
echo "  Target node            : $TARGET_NODE"
echo "  Replacement node       : $REPLACEMENT_NODE"
echo "  Source PVC             : $SOURCE_PVC"
echo "  Target PVC             : $TARGET_PVC"
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

echo "1,cold-node,$SOURCE_NODE,$TARGET_NODE,$REPLACEMENT_NODE,$NODE_CHANGED,$SOURCE_PVC,$TARGET_PVC,$SOURCE_ARTIFACT_PRESENT,$SOURCE_MODEL_RESIDENT,$TARGET_ARTIFACT_PRESENT,$TARGET_MODEL_RESIDENT,$T0,$T1,$T2,$T3,$T4,$POD_RECOVERY,$RUNTIME_RECOVERY,$READY_TO_RUNTIME,$FUNCTIONAL_RECOVERY,$READY_TO_INFERENCE,$REQUEST_WALL,$HTTP_CODE,$TOTAL_MS,$LOAD_MS,$PROMPT_MS,$EVAL_MS,$MEMORY_CURRENT" \
  >> "$OUT"

echo
echo "Result written to:"
echo "$OUT"

echo
echo "Post-experiment state:"
echo "The Deployment intentionally remains on the target PVC/node role."
echo "The source node will be uncordoned by cleanup."
echo "Do not rerun this as another first-use cold-node trial without resetting the target condition."

