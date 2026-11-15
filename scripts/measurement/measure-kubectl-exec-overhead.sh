#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="llm-recovery-lab"
DEPLOYMENT="vllm-qwen3-14b-awq"

RUNS="${1:-50}"
OUT_ROOT="${2:-results/measurement-overhead/kubectl-exec-vllm}"

mkdir -p "${OUT_ROOT}"

POD="$(
  kubectl get pod \
    -n "${NAMESPACE}" \
    -l app="${DEPLOYMENT}" \
    -o jsonpath='{.items[0].metadata.name}'
)"

if [[ -z "${POD}" ]]; then
  echo "ERROR: vLLM pod not found" >&2
  exit 1
fi

READY="$(
  kubectl get pod "${POD}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
)"

if [[ "${READY}" != "True" ]]; then
  echo "ERROR: pod ${POD} is not Ready" >&2
  exit 1
fi

echo "Using pod: ${POD}"
echo "Runs: ${RUNS}"

ns_to_ms() {
  awk -v ns="$1" 'BEGIN { printf "%.3f", ns / 1000000 }'
}

echo "run,trivial_exec_wall_ms,health_exec_wall_ms,health_internal_ms,estimated_exec_overhead_ms" \
  > "${OUT_ROOT}/summary.csv"

for run in $(seq 1 "${RUNS}"); do
  echo "Run ${run}/${RUNS}"

  #
  # Test A: trivial kubectl exec.
  #
  T0="$(date +%s%N)"

  kubectl exec \
    -n "${NAMESPACE}" \
    "${POD}" \
    -- python3 -c 'pass'

  T1="$(date +%s%N)"

  TRIVIAL_NS=$((T1 - T0))
  TRIVIAL_MS="$(ns_to_ms "${TRIVIAL_NS}")"

  #
  # Test B: localhost /health through kubectl exec.
  #
  # Python measures only the HTTP request inside the container.
  # Client-side wall time measures the entire kubectl exec invocation.
  #
  T2="$(date +%s%N)"

  INTERNAL_MS="$(
    kubectl exec \
      -n "${NAMESPACE}" \
      "${POD}" \
      -- python3 - <<'PY'
import time
import urllib.request

start = time.perf_counter()

with urllib.request.urlopen(
    "http://127.0.0.1:8000/health",
    timeout=5
) as response:
    response.read()

elapsed_ms = (time.perf_counter() - start) * 1000.0
print(f"{elapsed_ms:.3f}")
PY
  )"

  T3="$(date +%s%N)"

  HEALTH_NS=$((T3 - T2))
  HEALTH_WALL_MS="$(ns_to_ms "${HEALTH_NS}")"

  ESTIMATED_OVERHEAD_MS="$(
    awk \
      -v total="${HEALTH_WALL_MS}" \
      -v internal="${INTERNAL_MS}" \
      'BEGIN { printf "%.3f", total - internal }'
  )"

  echo "${run},${TRIVIAL_MS},${HEALTH_WALL_MS},${INTERNAL_MS},${ESTIMATED_OVERHEAD_MS}" \
    >> "${OUT_ROOT}/summary.csv"

  sleep 0.2
done

echo
echo "===== RAW RESULTS ====="
column -s, -t < "${OUT_ROOT}/summary.csv" || \
  cat "${OUT_ROOT}/summary.csv"

echo
echo "===== SUMMARY ====="

awk -F, '
NR > 1 {
  n++

  trivial += $2
  health_wall += $3
  health_internal += $4
  overhead += $5

  trivial_sq += $2 * $2
  health_wall_sq += $3 * $3
  health_internal_sq += $4 * $4
  overhead_sq += $5 * $5

  if (n == 1 || $2 < trivial_min) trivial_min = $2
  if (n == 1 || $2 > trivial_max) trivial_max = $2

  if (n == 1 || $5 < overhead_min) overhead_min = $5
  if (n == 1 || $5 > overhead_max) overhead_max = $5
}
END {
  if (n < 1) exit 1

  trivial_mean = trivial / n
  wall_mean = health_wall / n
  internal_mean = health_internal / n
  overhead_mean = overhead / n

  if (n > 1) {
    trivial_sd = sqrt((trivial_sq - n * trivial_mean * trivial_mean) / (n - 1))
    wall_sd = sqrt((health_wall_sq - n * wall_mean * wall_mean) / (n - 1))
    internal_sd = sqrt((health_internal_sq - n * internal_mean * internal_mean) / (n - 1))
    overhead_sd = sqrt((overhead_sq - n * overhead_mean * overhead_mean) / (n - 1))
  } else {
    trivial_sd = 0
    wall_sd = 0
    internal_sd = 0
    overhead_sd = 0
  }

  printf "n=%d\n", n
  printf "trivial_exec_mean_ms=%.3f\n", trivial_mean
  printf "trivial_exec_sd_ms=%.3f\n", trivial_sd
  printf "trivial_exec_min_ms=%.3f\n", trivial_min
  printf "trivial_exec_max_ms=%.3f\n", trivial_max

  printf "health_exec_wall_mean_ms=%.3f\n", wall_mean
  printf "health_exec_wall_sd_ms=%.3f\n", wall_sd

  printf "health_internal_mean_ms=%.3f\n", internal_mean
  printf "health_internal_sd_ms=%.3f\n", internal_sd

  printf "estimated_exec_overhead_mean_ms=%.3f\n", overhead_mean
  printf "estimated_exec_overhead_sd_ms=%.3f\n", overhead_sd
  printf "estimated_exec_overhead_min_ms=%.3f\n", overhead_min
  printf "estimated_exec_overhead_max_ms=%.3f\n", overhead_max
}
' "${OUT_ROOT}/summary.csv" | tee "${OUT_ROOT}/statistics.txt"
