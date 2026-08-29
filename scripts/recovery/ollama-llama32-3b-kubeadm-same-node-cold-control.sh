#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-recovery-lab}"
DEPLOYMENT="${DEPLOYMENT:-ollama}"
CLIENT_POD="${CLIENT_POD:-ollama-client}"
MODEL="${MODEL:-llama3.2:3b}"
TARGET_NODE="${TARGET_NODE:-k8s-llm-cpu-02}"
TARGET_ROLE="${TARGET_ROLE:-target}"
TARGET_PVC="${TARGET_PVC:-ollama-models-target}"
POD_SELECTOR="${POD_SELECTOR:-app=ollama,experiment=cold-node-recovery}"

OUT="${OUT:-results/cloud-cpu/ollama/llama3.2-3b/cold-node/same-topology-cold-control.csv}"

POD_READY_TIMEOUT_SECONDS="${POD_READY_TIMEOUT_SECONDS:-300}"
RUNTIME_TIMEOUT_SECONDS="${RUNTIME_TIMEOUT_SECONDS:-180}"
INFERENCE_TIMEOUT_SECONDS="${INFERENCE_TIMEOUT_SECONDS:-180}"

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

wait_for_zero_pods() {
  local deadline=$((SECONDS + POD_READY_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    local count
    count=$(kubectl get pods -n "$NAMESPACE" -l "$POD_SELECTOR" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$count" == "0" ]]; then
      return 0
    fi

    sleep 0.2
  done

  return 1
}

wait_for_ready_target_pod() {
  local deadline=$((SECONDS + POD_READY_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    while IFS= read -r pod; do
      [[ -n "$pod" ]] || continue

      local phase ready node

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

require_cmd kubectl
require_cmd python3
require_cmd grep
require_cmd sed

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || fail "namespace not found: $NAMESPACE"

kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" >/dev/null 2>&1 \
  || fail "deployment not found: $NAMESPACE/$DEPLOYMENT"

kubectl get pod -n "$NAMESPACE" "$CLIENT_POD" >/dev/null 2>&1 \
  || fail "client pod not found: $NAMESPACE/$CLIENT_POD"

kubectl get node "$TARGET_NODE" >/dev/null 2>&1 \
  || fail "target node not found: $TARGET_NODE"

TARGET_READY=$(kubectl get node "$TARGET_NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

[[ "$TARGET_READY" == "True" ]] \
  || fail "target node is not Ready: $TARGET_NODE"

CURRENT_ROLE=$(kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.nodeSelector.llm-recovery-role}' \
  2>/dev/null || true)

CURRENT_PVC=$(kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="models")].persistentVolumeClaim.claimName}' \
  2>/dev/null || true)

[[ "$CURRENT_ROLE" == "$TARGET_ROLE" ]] || fail \
  "deployment must be in target state before this control: role=$CURRENT_ROLE expected=$TARGET_ROLE"

[[ "$CURRENT_PVC" == "$TARGET_PVC" ]] || fail \
  "deployment must use target PVC before this control: pvc=$CURRENT_PVC expected=$TARGET_PVC"

CLIENT_NODE=$(kubectl get pod -n "$NAMESPACE" "$CLIENT_POD" \
  -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)

[[ "$CLIENT_NODE" != "$TARGET_NODE" ]] || fail \
  "measurement client is running on target node; keep the client on the source node"

echo "Same-topology cold control"
echo "Namespace   : $NAMESPACE"
echo "Deployment  : $DEPLOYMENT"
echo "Model       : $MODEL"
echo "Target node : $TARGET_NODE"
echo "Target PVC  : $TARGET_PVC"
echo
echo "This control measures a cold same-node start on the kubeadm/containerd topology."
echo "The Deployment will be scaled to zero before the target cache is cleared."

kubectl scale deployment -n "$NAMESPACE" "$DEPLOYMENT" --replicas=0 >/dev/null

echo
echo "Waiting for Ollama pod to terminate..."

if ! wait_for_zero_pods; then
  fail "Ollama pod did not terminate after scale-down"
fi

echo
echo "Ollama pod is stopped."
echo
echo "On ${TARGET_NODE}, run:"
echo
echo "  cd ~/k8s-llm-recovery-lab"
echo "  sudo bash scripts/cloud/prepare-cold-target-node.sh"
echo
echo "Confirm that it reports:"
echo "  model_serving_process_present=false"
echo "  drop_caches_success=true"
echo
read -r -p "Press Enter only after the target precondition succeeds: "

echo
echo "Starting measured same-node cold start..."

T0=$(now_ms)

kubectl scale deployment -n "$NAMESPACE" "$DEPLOYMENT" --replicas=1 >/dev/null

if ! NEW_POD=$(wait_for_ready_target_pod); then
  kubectl get pods -n "$NAMESPACE" -o wide || true
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp | tail -n 40 || true
  fail "target pod did not become Ready"
fi

T1=$(now_ms)

REPLACEMENT_NODE=$(kubectl get pod -n "$NAMESPACE" "$NEW_POD" \
  -o jsonpath='{.spec.nodeName}')

[[ "$REPLACEMENT_NODE" == "$TARGET_NODE" ]] || fail \
  "pod landed on $REPLACEMENT_NODE, expected $TARGET_NODE"

NEW_POD_PVC=$(kubectl get pod -n "$NAMESPACE" "$NEW_POD" \
  -o jsonpath='{.spec.volumes[?(@.name=="models")].persistentVolumeClaim.claimName}')

[[ "$NEW_POD_PVC" == "$TARGET_PVC" ]] || fail \
  "pod is using PVC $NEW_POD_PVC, expected $TARGET_PVC"

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

[[ "$TARGET_ARTIFACT_PRESENT" == "true" ]] || fail \
  "model artifact missing before inference"

[[ "$TARGET_MODEL_RESIDENT" == "false" ]] || fail \
  "model already resident before inference; cold control invalid"

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

TOTAL_NS=$(echo "$BODY" | sed -n 's/.*"total_duration":\([0-9]*\).*/\1/p')
LOAD_NS=$(echo "$BODY" | sed -n 's/.*"load_duration":\([0-9]*\).*/\1/p')
PROMPT_NS=$(echo "$BODY" | sed -n 's/.*"prompt_eval_duration":\([0-9]*\).*/\1/p')
EVAL_NS=$(echo "$BODY" | sed -n 's/.*"eval_duration":\([0-9]*\).*/\1/p')

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

mkdir -p "$(dirname "$OUT")"

if [[ ! -f "$OUT" ]]; then
  echo "run,control_condition,target_node,target_pvc,target_artifact_present_before_inference,target_model_resident_before_inference,t0_scaleup_ms,t1_k8s_ready_ms,t2_runtime_ms,t3_inference_start_ms,t4_inference_done_ms,pod_recovery_ms,runtime_recovery_ms,ready_to_runtime_ms,functional_recovery_ms,ready_to_inference_ms,request_wall_ms,http_code,total_duration_ms,load_duration_ms,prompt_eval_duration_ms,eval_duration_ms,memory_current_bytes" \
    > "$OUT"
fi

RUN_ID=$(( $(tail -n +2 "$OUT" 2>/dev/null | wc -l) + 1 ))

echo "$RUN_ID,same-node-cold-kubeadm-containerd,$TARGET_NODE,$TARGET_PVC,$TARGET_ARTIFACT_PRESENT,$TARGET_MODEL_RESIDENT,$T0,$T1,$T2,$T3,$T4,$POD_RECOVERY,$RUNTIME_RECOVERY,$READY_TO_RUNTIME,$FUNCTIONAL_RECOVERY,$READY_TO_INFERENCE,$REQUEST_WALL,$HTTP_CODE,$TOTAL_MS,$LOAD_MS,$PROMPT_MS,$EVAL_MS,$MEMORY_CURRENT" \
  >> "$OUT"

echo
echo "Same-topology cold-control result"
echo "  Run                    : $RUN_ID"
echo "  Target node            : $TARGET_NODE"
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
echo
echo "Result appended to:"
echo "$OUT"
echo
echo "For another cold-control run, rerun this script."
echo "It will scale the Deployment to zero and pause for a fresh target cache reset."

