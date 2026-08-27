#!/usr/bin/env bash

set -u

NAMESPACE="ollama-recovery-lab"
DEPLOYMENT="ollama"
CLIENT_POD="ollama-client"
MODEL="llama3.2:1b"
RUNS=10
OUT="ollama-pvc-recovery.csv"

echo "run,failure_epoch,pod_running_epoch,first_inference_epoch,pod_recovery_s,functional_recovery_s,recovery_gap_s,http_code,total_duration_ns,load_duration_ns" > "$OUT"

for run in $(seq 1 "$RUNS"); do
  echo
  echo "========== RUN $run / $RUNS =========="

  OLD_POD=$(kubectl get pod -n "$NAMESPACE" -l app=ollama \
    -o jsonpath='{.items[0].metadata.name}')

  echo "Old pod: $OLD_POD"

  T0=$(date +%s)
  echo "Deleting pod at epoch $T0"

  kubectl delete pod -n "$NAMESPACE" "$OLD_POD" --wait=false >/dev/null

  echo "Waiting for replacement pod..."

  while true; do
    NEW_POD=$(kubectl get pod -n "$NAMESPACE" -l app=ollama \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [[ -n "$NEW_POD" && "$NEW_POD" != "$OLD_POD" ]]; then
      PHASE=$(kubectl get pod -n "$NAMESPACE" "$NEW_POD" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)

      READY=$(kubectl get pod -n "$NAMESPACE" "$NEW_POD" \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)

      if [[ "$PHASE" == "Running" && "$READY" == "true" ]]; then
        break
      fi
    fi

    sleep 0.2
  done

  T1=$(date +%s)
  echo "New pod ready: $NEW_POD"
  echo "Kubernetes recovery: $((T1-T0)) sec"

  echo "Waiting for first successful inference..."

  HTTP_CODE=""
  RESPONSE=""

  while true; do
    RESPONSE=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
      curl --max-time 30 -s \
      -o /tmp/ollama-response.json \
      -w "%{http_code}" \
      http://ollama:11434/api/generate \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with exactly: READY\",\"stream\":false}" \
      2>/dev/null || true)

    HTTP_CODE="$RESPONSE"

    if [[ "$HTTP_CODE" == "200" ]]; then
      BODY=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
        cat /tmp/ollama-response.json 2>/dev/null || true)

      if echo "$BODY" | grep -q '"done":true'; then
        break
      fi
    fi

    sleep 0.2
  done

  T2=$(date +%s)

  BODY=$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- \
    cat /tmp/ollama-response.json)

  TOTAL_NS=$(echo "$BODY" | sed -n 's/.*"total_duration":\([0-9]*\).*/\1/p')
  LOAD_NS=$(echo "$BODY" | sed -n 's/.*"load_duration":\([0-9]*\).*/\1/p')

  POD_RECOVERY=$((T1-T0))
  FUNCTIONAL_RECOVERY=$((T2-T0))
  RECOVERY_GAP=$((T2-T1))

  echo
  echo "Run $run result:"
  echo "  Pod recovery        : ${POD_RECOVERY}s"
  echo "  Functional recovery : ${FUNCTIONAL_RECOVERY}s"
  echo "  Recovery gap        : ${RECOVERY_GAP}s"
  echo "  HTTP                : $HTTP_CODE"
  echo "  load_duration       : $LOAD_NS ns"
  echo "  total_duration      : $TOTAL_NS ns"

  echo "$run,$T0,$T1,$T2,$POD_RECOVERY,$FUNCTIONAL_RECOVERY,$RECOVERY_GAP,$HTTP_CODE,$TOTAL_NS,$LOAD_NS" \
    >> "$OUT"

  if [[ "$run" -lt "$RUNS" ]]; then
    echo "Waiting 15 seconds before next run..."
    sleep 15
  fi
done

echo
echo "======================================"
echo "Completed $RUNS runs"
echo "Results: $OUT"
echo "======================================"
