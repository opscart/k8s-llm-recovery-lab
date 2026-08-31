
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-recovery-lab}"
CLIENT_POD="${CLIENT_POD:-ollama-client}"
MODEL="${MODEL:-llama3.2:3b}"
THINK="${THINK:-}"
RUNS="${RUNS:-10}"
OUT="${OUT:-results/cloud-gpu/ollama/llama3.2-3b/recovery/gpu-recovery.csv}"

mkdir -p "$(dirname "$OUT")"

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

gpu_used_mib() {
  nvidia-smi --query-compute-apps=used_memory --format=csv,noheader,nounits 2>/dev/null \
    | awk '{sum += $1} END {print sum+0}'
}

echo "run,gpu_used_mib_before,t0_delete_ms,t1_k8s_ready_ms,t2_runtime_ms,t3_inference_start_ms,t4_inference_done_ms,pod_recovery_ms,runtime_recovery_ms,ready_to_runtime_ms,functional_recovery_ms,ready_to_inference_ms,request_wall_ms,http_code,total_duration_ms,load_duration_ms,prompt_eval_duration_ms,eval_duration_ms,memory_current_bytes,gpu_used_mib_after" > "$OUT"

for run in $(seq 1 "$RUNS"); do
  echo
  echo "========== RUN $run / $RUNS =========="

  OLD_POD="$(kubectl get pod -n "$NAMESPACE" \
    -l app=ollama,experiment=gpu-recovery \
    -o jsonpath='{.items[0].metadata.name}')"

  GPU_BEFORE="$(gpu_used_mib)"
  echo "Old pod: $OLD_POD"
  echo "GPU compute-process memory before delete: ${GPU_BEFORE} MiB"

  T0="$(now_ms)"
  kubectl delete pod -n "$NAMESPACE" "$OLD_POD" --wait=false >/dev/null

  NEW_POD=""
  while true; do
    NEW_POD="$(kubectl get pod -n "$NAMESPACE" \
      -l app=ollama,experiment=gpu-recovery \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

    if [[ -n "$NEW_POD" && "$NEW_POD" != "$OLD_POD" ]]; then
      READY="$(kubectl get pod -n "$NAMESPACE" "$NEW_POD" \
        -o jsonpath='{.status.containerStatuses[?(@.name=="ollama")].ready}' \
        2>/dev/null || true)"
      if [[ "$READY" == "true" ]]; then
        break
      fi
    fi
    sleep 0.1
  done
  T1="$(now_ms)"

  while true; do
    HTTP="$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
      curl --connect-timeout 1 --max-time 2 \
      -s -o /dev/null -w "%{http_code}" \
      http://ollama:11434/api/tags 2>/dev/null || true)"
    [[ "$HTTP" == "200" ]] && break
    sleep 0.1
  done
  T2="$(now_ms)"

  T3="$(now_ms)"
  set +e
  BODY="$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
    curl --max-time 180 -s \
    http://ollama:11434/api/generate \
    -H "Content-Type: application/json" \
    -d "$(if [[ "$THINK" == "false" ]]; then
      printf '{"model":"%s","prompt":"Reply with exactly: READY","stream":false,"think":false}' "$MODEL"
    else
      printf '{"model":"%s","prompt":"Reply with exactly: READY","stream":false}' "$MODEL"
    fi)")"
  CURL_RC=$?
  set -e
  T4="$(now_ms)"

  if [[ "$CURL_RC" -eq 0 ]] && echo "$BODY" | grep -q '"done":true'; then
    HTTP_CODE="200"
  else
    HTTP_CODE="FAIL"
  fi

  TOTAL_NS="$(echo "$BODY" | sed -n 's/.*"total_duration":\([0-9]*\).*/\1/p')"
  LOAD_NS="$(echo "$BODY" | sed -n 's/.*"load_duration":\([0-9]*\).*/\1/p')"
  PROMPT_NS="$(echo "$BODY" | sed -n 's/.*"prompt_eval_duration":\([0-9]*\).*/\1/p')"
  EVAL_NS="$(echo "$BODY" | sed -n 's/.*"eval_duration":\([0-9]*\).*/\1/p')"

  TOTAL_MS=$(( ${TOTAL_NS:-0} / 1000000 ))
  LOAD_MS=$(( ${LOAD_NS:-0} / 1000000 ))
  PROMPT_MS=$(( ${PROMPT_NS:-0} / 1000000 ))
  EVAL_MS=$(( ${EVAL_NS:-0} / 1000000 ))

  POD_RECOVERY=$((T1-T0))
  RUNTIME_RECOVERY=$((T2-T0))
  READY_TO_RUNTIME=$((T2-T1))
  FUNCTIONAL_RECOVERY=$((T4-T0))
  READY_TO_INFERENCE=$((T4-T1))
  REQUEST_WALL=$((T4-T3))

  MEMORY_CURRENT="$(kubectl exec -n "$NAMESPACE" "$NEW_POD" -c ollama -- \
    cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)"

  GPU_AFTER="$(gpu_used_mib)"

  echo "Run $run"
  echo "  Kubernetes Ready       : ${POD_RECOVERY} ms"
  echo "  Runtime reachable      : ${RUNTIME_RECOVERY} ms"
  echo "  Functional recovery    : ${FUNCTIONAL_RECOVERY} ms"
  echo "  Ready -> Inference     : ${READY_TO_INFERENCE} ms"
  echo "  Request wall time      : ${REQUEST_WALL} ms"
  echo "  Ollama load            : ${LOAD_MS} ms"
  echo "  Ollama total           : ${TOTAL_MS} ms"
  echo "  GPU memory after       : ${GPU_AFTER} MiB"

  echo "$run,$GPU_BEFORE,$T0,$T1,$T2,$T3,$T4,$POD_RECOVERY,$RUNTIME_RECOVERY,$READY_TO_RUNTIME,$FUNCTIONAL_RECOVERY,$READY_TO_INFERENCE,$REQUEST_WALL,$HTTP_CODE,$TOTAL_MS,$LOAD_MS,$PROMPT_MS,$EVAL_MS,$MEMORY_CURRENT,$GPU_AFTER" >> "$OUT"

  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "ERROR: inference failed on run $run; stopping to preserve evidence"
    exit 1
  fi

  if [[ "$run" -lt "$RUNS" ]]; then
    sleep 15
  fi
done

echo
echo "Completed $RUNS GPU recovery runs"
echo "Results: $OUT"

