#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="llm-recovery-lab"
DEPLOYMENT="vllm-qwen3-14b-awq"
SERVICE="vllm-qwen3-14b-awq"
MODEL="qwen3-14b-awq"

RUNS="${1:-3}"
OUT_ROOT="results/runtime-recovery/vllm-qwen3-14b/pilot"

mkdir -p "${OUT_ROOT}"

ts_ns() {
  date +%s%N
}

ns_to_sec() {
  awk -v ns="$1" 'BEGIN { printf "%.3f", ns / 1000000000 }'
}

wait_for_new_pod() {
  local old_uid="$1"

  while true; do
    POD_JSON="$(
      kubectl get pods \
        -n "${NAMESPACE}" \
        -l app="${DEPLOYMENT}" \
        -o json
    )"

    POD_COUNT="$(echo "${POD_JSON}" | jq '.items | length')"

    if [[ "${POD_COUNT}" -ge 1 ]]; then
      POD_NAME="$(echo "${POD_JSON}" | jq -r '.items[0].metadata.name')"
      POD_UID="$(echo "${POD_JSON}" | jq -r '.items[0].metadata.uid')"

      if [[ "${POD_UID}" != "${old_uid}" ]]; then
        echo "${POD_NAME}|${POD_UID}"
        return
      fi
    fi

    sleep 0.2
  done
}

wait_for_ready() {
  local pod="$1"

  while true; do
    READY="$(
      kubectl get pod "${pod}" \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null || true
    )"

    if [[ "${READY}" == "True" ]]; then
      return
    fi

    sleep 0.2
  done
}

wait_for_health() {
  local pod="$1"

  while true; do
    if kubectl exec -i \
      -n "${NAMESPACE}" \
      "${pod}" \
      -- python3 - <<'PY' >/dev/null 2>&1
import urllib.request
urllib.request.urlopen("http://127.0.0.1:8000/health", timeout=1)
PY
    then
      return
    fi

    sleep 0.2
  done
}

run_inference() {
  local pod="$1"
  local response_file="$2"

  kubectl exec -i \
    -n "${NAMESPACE}" \
    "${pod}" \
    -- python3 - <<'PY' > "${response_file}"
import json
import urllib.request

payload = {
    "model": "qwen3-14b-awq",
    "temperature": 0,
    "max_tokens": 16,
    "chat_template_kwargs": {
        "enable_thinking": False
    },
    "messages": [
        {
            "role": "user",
            "content": "Reply with exactly: RECOVERY_OK"
        }
    ]
}

req = urllib.request.Request(
    "http://127.0.0.1:8000/v1/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
    method="POST"
)

with urllib.request.urlopen(req, timeout=120) as r:
    print(r.read().decode())
PY
}

echo "run,t0_ns,t1_ready_ns,t2_health_ns,t3_request_ns,t4_success_ns,k8s_recovery_s,runtime_recovery_s,functional_recovery_s,ready_to_inference_s,request_wall_s,pod,pod_uid" \
  > "${OUT_ROOT}/summary.csv"

for run in $(seq 1 "${RUNS}"); do
  printf '\n===== RUN %s/%s =====\n' "${run}" "${RUNS}"

  RUN_DIR="${OUT_ROOT}/run-$(printf '%02d' "${run}")"
  mkdir -p "${RUN_DIR}"

  OLD_UID="$(
    kubectl get pods \
      -n "${NAMESPACE}" \
      -l app="${DEPLOYMENT}" \
      -o jsonpath='{.items[0].metadata.uid}' \
      2>/dev/null || true
  )"

  T0="$(ts_ns)"

  kubectl delete pod \
    -n "${NAMESPACE}" \
    -l app="${DEPLOYMENT}" \
    --wait=false \
    > "${RUN_DIR}/delete.txt"

  POD_INFO="$(wait_for_new_pod "${OLD_UID}")"
  POD="${POD_INFO%%|*}"
  POD_UID="${POD_INFO##*|}"

  echo "New pod: ${POD}"
  echo "UID: ${POD_UID}"

  kubectl get pod "${POD}" \
    -n "${NAMESPACE}" \
    -o yaml \
    > "${RUN_DIR}/pod-initial.yaml"

  wait_for_ready "${POD}"
  T1="$(ts_ns)"
  echo "Kubernetes Ready"

  wait_for_health "${POD}"
  T2="$(ts_ns)"
  echo "vLLM /health reachable"

  T3="$(ts_ns)"
  run_inference "${POD}" "${RUN_DIR}/response.json"
  T4="$(ts_ns)"

  CONTENT="$(
    jq -r '.choices[0].message.content // empty' \
      "${RUN_DIR}/response.json"
  )"

  if [[ "${CONTENT}" != "RECOVERY_OK" ]]; then
    echo "ERROR: expected RECOVERY_OK, got: ${CONTENT}" >&2
    exit 1
  fi

  K8S_NS=$((T1 - T0))
  RUNTIME_NS=$((T2 - T0))
  FUNCTIONAL_NS=$((T4 - T0))
  READY_INF_NS=$((T4 - T1))
  REQUEST_NS=$((T4 - T3))

  K8S_S="$(ns_to_sec "${K8S_NS}")"
  RUNTIME_S="$(ns_to_sec "${RUNTIME_NS}")"
  FUNCTIONAL_S="$(ns_to_sec "${FUNCTIONAL_NS}")"
  READY_INF_S="$(ns_to_sec "${READY_INF_NS}")"
  REQUEST_S="$(ns_to_sec "${REQUEST_NS}")"

  kubectl logs \
    -n "${NAMESPACE}" \
    "${POD}" \
    > "${RUN_DIR}/vllm.log"

  kubectl get pod "${POD}" \
    -n "${NAMESPACE}" \
    -o yaml \
    > "${RUN_DIR}/pod-final.yaml"

  kubectl get events \
    -n "${NAMESPACE}" \
    --sort-by='.lastTimestamp' \
    > "${RUN_DIR}/events.txt"

  nvidia-smi > "${RUN_DIR}/nvidia-smi.txt" || true

  kubectl get deployment "${DEPLOYMENT}" \
    -n "${NAMESPACE}" \
    -o yaml \
    > "${RUN_DIR}/deployment.yaml"

  git rev-parse HEAD > "${RUN_DIR}/git-sha.txt"

  cat > "${RUN_DIR}/timings.json" <<JSON
{
  "run": ${run},
  "t0_ns": ${T0},
  "t1_ready_ns": ${T1},
  "t2_health_ns": ${T2},
  "t3_request_ns": ${T3},
  "t4_success_ns": ${T4},
  "k8s_recovery_s": ${K8S_S},
  "runtime_recovery_s": ${RUNTIME_S},
  "functional_recovery_s": ${FUNCTIONAL_S},
  "ready_to_inference_s": ${READY_INF_S},
  "request_wall_s": ${REQUEST_S},
  "pod": "${POD}",
  "pod_uid": "${POD_UID}"
}
JSON

  echo "${run},${T0},${T1},${T2},${T3},${T4},${K8S_S},${RUNTIME_S},${FUNCTIONAL_S},${READY_INF_S},${REQUEST_S},${POD},${POD_UID}" \
    >> "${OUT_ROOT}/summary.csv"

  echo
  echo "Run ${run} results:"
  echo "  Kubernetes recovery : ${K8S_S}s"
  echo "  Runtime recovery    : ${RUNTIME_S}s"
  echo "  Functional recovery : ${FUNCTIONAL_S}s"
  echo "  Ready -> inference  : ${READY_INF_S}s"
  echo "  Request wall        : ${REQUEST_S}s"

  if [[ "${run}" -lt "${RUNS}" ]]; then
    echo
    echo "Cooling down 15s before next run..."
    sleep 15
  fi
done

echo
echo "===== PILOT COMPLETE ====="
column -s, -t < "${OUT_ROOT}/summary.csv" || cat "${OUT_ROOT}/summary.csv"
