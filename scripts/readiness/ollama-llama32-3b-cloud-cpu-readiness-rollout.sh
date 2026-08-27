#!/usr/bin/env bash

set -u

NAMESPACE="llm-recovery-lab"
DEPLOYMENT="ollama"
SERVICE="ollama"
LABEL="app=ollama"
RUNS=10
POLL_INTERVAL="0.5"
COOLDOWN=15

RAW_OUT="results/cloud-cpu/ollama/llama3.2-3b/readiness/inference-readiness-endpoints.csv"
SUMMARY_OUT="results/cloud-cpu/ollama/llama3.2-3b/readiness/inference-readiness-summary.csv"

now_ms() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null ||
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Raw EndpointSlice observations
echo "run,timestamp_ms,timestamp_utc,ip,role,ready,serving,terminating" \
  > "$RAW_OUT"

# One summarized row per rollout
echo "run,rollout_start_ms,old_pod,old_ip,new_pod,new_ip,new_pod_first_seen_ms,new_pod_running_ms,new_endpoint_first_seen_ms,new_endpoint_ready_ms,old_endpoint_not_ready_ms,old_endpoint_removed_ms,new_endpoint_nonserving_ms,traffic_gap_count" \
  > "$SUMMARY_OUT"

echo "======================================================"
echo "3B inference-aware readiness rollout experiment"
echo "Runs: $RUNS"
echo "Raw output:     $RAW_OUT"
echo "Summary output: $SUMMARY_OUT"
echo "======================================================"

for run in $(seq 1 "$RUNS"); do

  echo
  echo "========== RUN $run / $RUNS =========="

  #
  # Establish stable old replica before rollout
  #
  OLD_POD=$(kubectl get pod \
    -n "$NAMESPACE" \
    -l "$LABEL" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}')

  OLD_IP=$(kubectl get pod \
    -n "$NAMESPACE" \
    "$OLD_POD" \
    -o jsonpath='{.status.podIP}')

  echo "Old pod: $OLD_POD"
  echo "Old IP : $OLD_IP"

  ROLLOUT_START=$(now_ms)

  echo "Triggering rollout..."

  kubectl rollout restart deployment/"$DEPLOYMENT" \
    -n "$NAMESPACE" >/dev/null

  NEW_POD=""
  NEW_IP=""

  NEW_POD_FIRST_SEEN=0
  NEW_POD_RUNNING=0
  NEW_ENDPOINT_FIRST_SEEN=0
  NEW_ENDPOINT_READY=0
  OLD_ENDPOINT_NOT_READY=0
  OLD_ENDPOINT_REMOVED=0

  TRAFFIC_GAP_COUNT=0

  #
  # Continue until:
  #
  #   new endpoint = ready/serving
  #   old endpoint = removed
  #
  while true; do

    TS_MS=$(now_ms)
    TS_UTC=$(now_utc)

    #
    # Find replacement pod
    #
    if [[ -z "$NEW_POD" ]]; then

      POD_DATA=$(kubectl get pods \
        -n "$NAMESPACE" \
        -l "$LABEL" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.podIP}{"|"}{.status.phase}{"\n"}{end}' \
        2>/dev/null || true)

      while IFS='|' read -r POD_NAME POD_IP POD_PHASE; do

        [[ -z "$POD_NAME" ]] && continue

        if [[ "$POD_NAME" != "$OLD_POD" ]]; then

          NEW_POD="$POD_NAME"
          NEW_IP="$POD_IP"

          if [[ "$NEW_POD_FIRST_SEEN" -eq 0 ]]; then
            NEW_POD_FIRST_SEEN=$TS_MS
            echo "New pod detected: $NEW_POD"
          fi

          break
        fi

      done <<< "$POD_DATA"
    fi

    #
    # Get new pod IP once Kubernetes assigns it
    #
    if [[ -n "$NEW_POD" && -z "$NEW_IP" ]]; then

      NEW_IP=$(kubectl get pod \
        -n "$NAMESPACE" \
        "$NEW_POD" \
        -o jsonpath='{.status.podIP}' \
        2>/dev/null || true)
    fi

    #
    # Detect Running state independently of readiness
    #
    if [[ -n "$NEW_POD" && "$NEW_POD_RUNNING" -eq 0 ]]; then

      PHASE=$(kubectl get pod \
        -n "$NAMESPACE" \
        "$NEW_POD" \
        -o jsonpath='{.status.phase}' \
        2>/dev/null || true)

      if [[ "$PHASE" == "Running" ]]; then
        NEW_POD_RUNNING=$TS_MS
        echo "New pod Running: $NEW_POD"
      fi
    fi

    #
    # Read EndpointSlice states
    #
    ENDPOINT_DATA=$(kubectl get endpointslice \
      -n "$NAMESPACE" \
      -l kubernetes.io/service-name="$SERVICE" \
      -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"|"}{.conditions.ready}{"|"}{.conditions.serving}{"|"}{.conditions.terminating}{"\n"}{end}' \
      2>/dev/null || true)

    READY_ENDPOINT_COUNT=0
    OLD_FOUND=false

    while IFS='|' read -r IP READY SERVING TERMINATING; do

      [[ -z "$IP" ]] && continue

      ROLE="unknown"

      if [[ "$IP" == "$OLD_IP" ]]; then
        ROLE="old"
        OLD_FOUND=true
      elif [[ -n "$NEW_IP" && "$IP" == "$NEW_IP" ]]; then
        ROLE="new"
      fi

      #
      # Normalize empty EndpointSlice condition values
      #
      READY=${READY:-false}
      SERVING=${SERVING:-false}
      TERMINATING=${TERMINATING:-false}

      echo "$run,$TS_MS,$TS_UTC,$IP,$ROLE,$READY,$SERVING,$TERMINATING" \
        >> "$RAW_OUT"

      #
      # Is there at least one usable service endpoint?
      #
      if [[ "$READY" == "true" && "$SERVING" == "true" ]]; then
        READY_ENDPOINT_COUNT=$((READY_ENDPOINT_COUNT + 1))
      fi

      #
      # First sighting of new endpoint
      #
      if [[ "$ROLE" == "new" && "$NEW_ENDPOINT_FIRST_SEEN" -eq 0 ]]; then
        NEW_ENDPOINT_FIRST_SEEN=$TS_MS

        echo "New endpoint first seen:"
        echo "  IP=$IP ready=$READY serving=$SERVING"
      fi

      #
      # First point at which new endpoint becomes traffic eligible
      #
      if [[ "$ROLE" == "new" &&
            "$READY" == "true" &&
            "$SERVING" == "true" &&
            "$NEW_ENDPOINT_READY" -eq 0 ]]; then

        NEW_ENDPOINT_READY=$TS_MS

        echo "New endpoint READY/SERVING:"
        echo "  IP=$IP"
      fi

      #
      # Old endpoint loses readiness
      #
      if [[ "$ROLE" == "old" &&
            "$READY" != "true" &&
            "$OLD_ENDPOINT_NOT_READY" -eq 0 ]]; then

        OLD_ENDPOINT_NOT_READY=$TS_MS

        echo "Old endpoint no longer ready:"
        echo "  IP=$IP terminating=$TERMINATING"
      fi

    done <<< "$ENDPOINT_DATA"

    #
    # No ready+serving endpoints means actual Service traffic gap
    #
    if [[ "$READY_ENDPOINT_COUNT" -eq 0 ]]; then
      TRAFFIC_GAP_COUNT=$((TRAFFIC_GAP_COUNT + 1))
    fi

    #
    # Detect complete removal of old endpoint, but only after new endpoint
    # has been observed. This avoids declaring removal during transient
    # API/listing behavior at rollout start.
    #
    if [[ "$NEW_ENDPOINT_FIRST_SEEN" -gt 0 &&
          "$OLD_FOUND" == false &&
          "$OLD_ENDPOINT_REMOVED" -eq 0 ]]; then

      OLD_ENDPOINT_REMOVED=$TS_MS
      echo "Old endpoint removed: $OLD_IP"
    fi

    #
    # Experiment complete
    #
    if [[ "$NEW_ENDPOINT_READY" -gt 0 &&
          "$OLD_ENDPOINT_REMOVED" -gt 0 ]]; then
      break
    fi

    sleep "$POLL_INTERVAL"

  done

  #
  # Duration new replica existed as an endpoint but was not yet serving.
  #
  if [[ "$NEW_ENDPOINT_FIRST_SEEN" -gt 0 &&
        "$NEW_ENDPOINT_READY" -gt 0 ]]; then
    NEW_ENDPOINT_NONSERVING=$((NEW_ENDPOINT_READY - NEW_ENDPOINT_FIRST_SEEN))
  else
    NEW_ENDPOINT_NONSERVING=0
  fi

  echo "$run,$ROLLOUT_START,$OLD_POD,$OLD_IP,$NEW_POD,$NEW_IP,$NEW_POD_FIRST_SEEN,$NEW_POD_RUNNING,$NEW_ENDPOINT_FIRST_SEEN,$NEW_ENDPOINT_READY,$OLD_ENDPOINT_NOT_READY,$OLD_ENDPOINT_REMOVED,$NEW_ENDPOINT_NONSERVING,$TRAFFIC_GAP_COUNT" \
    >> "$SUMMARY_OUT"

  echo
  echo "Run $run completed"
  echo "  Old pod                  : $OLD_POD"
  echo "  New pod                  : $NEW_POD"
  echo "  Old IP                   : $OLD_IP"
  echo "  New IP                   : $NEW_IP"
  echo "  New endpoint non-serving : ${NEW_ENDPOINT_NONSERVING} ms"
  echo "  Traffic gap samples      : $TRAFFIC_GAP_COUNT"

  #
  # Make sure Deployment is stable before next experiment.
  #
  echo "Waiting for rollout to stabilize..."

  kubectl rollout status deployment/"$DEPLOYMENT" \
    -n "$NAMESPACE" \
    --timeout=240s >/dev/null

  if [[ "$run" -lt "$RUNS" ]]; then
    echo "Inter-run cooldown, excluded from measurements: ${COOLDOWN}s"
    sleep "$COOLDOWN"
  fi

done

echo
echo "======================================================"
echo "Completed $RUNS readiness-aware rollouts"
echo
echo "Raw EndpointSlice evidence:"
echo "  $RAW_OUT"
echo
echo "Summary:"
echo "  $SUMMARY_OUT"
echo "======================================================"
