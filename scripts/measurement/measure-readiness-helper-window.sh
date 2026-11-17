#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ollama-recovery-lab}"
WINDOW_SECONDS="${WINDOW_SECONDS:-300}"
OUT_DIR="${1:-results/measurement-overhead/readiness-helper/probe-on}"

mkdir -p "${OUT_DIR}"

POD="$(
  kubectl get pod \
    -n "${NAMESPACE}" \
    -l app=ollama \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}'
)"

if [[ -z "${POD}" ]]; then
  echo "ERROR: no running Ollama pod found" >&2
  exit 1
fi

read_cpu_usage() {
  local container="$1"

  kubectl exec \
    -n "${NAMESPACE}" \
    "${POD}" \
    -c "${container}" \
    -- sh -c \
    "awk '/^usage_usec / {print \$2}' /sys/fs/cgroup/cpu.stat"
}

read_memory() {
  local container="$1"

  kubectl exec \
    -n "${NAMESPACE}" \
    "${POD}" \
    -c "${container}" \
    -- cat /sys/fs/cgroup/memory.current
}

OLLAMA_CPU_START="$(read_cpu_usage ollama)"
HELPER_CPU_START="$(read_cpu_usage readiness-helper)"

OLLAMA_MEM_START="$(read_memory ollama)"
HELPER_MEM_START="$(read_memory readiness-helper)"

START_EPOCH="$(date +%s)"
START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "pod=${POD}"
echo "start=${START_UTC}"
echo "window_seconds=${WINDOW_SECONDS}"
echo "Waiting ${WINDOW_SECONDS}s..."

sleep "${WINDOW_SECONDS}"

END_EPOCH="$(date +%s)"
END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

OLLAMA_CPU_END="$(read_cpu_usage ollama)"
HELPER_CPU_END="$(read_cpu_usage readiness-helper)"

OLLAMA_MEM_END="$(read_memory ollama)"
HELPER_MEM_END="$(read_memory readiness-helper)"

ACTUAL_SECONDS=$((END_EPOCH - START_EPOCH))

OLLAMA_CPU_DELTA=$((OLLAMA_CPU_END - OLLAMA_CPU_START))
HELPER_CPU_DELTA=$((HELPER_CPU_END - HELPER_CPU_START))

awk \
  -v duration="${ACTUAL_SECONDS}" \
  -v ocpu="${OLLAMA_CPU_DELTA}" \
  -v hcpu="${HELPER_CPU_DELTA}" \
  -v oms="${OLLAMA_MEM_START}" \
  -v ome="${OLLAMA_MEM_END}" \
  -v hms="${HELPER_MEM_START}" \
  -v hme="${HELPER_MEM_END}" \
  'BEGIN {
    printf "duration_seconds=%d\n", duration
    printf "ollama_cpu_usage_delta_usec=%d\n", ocpu
    printf "helper_cpu_usage_delta_usec=%d\n", hcpu

    printf "ollama_mean_cpu_cores=%.6f\n", ocpu / (duration * 1000000)
    printf "helper_mean_cpu_cores=%.6f\n", hcpu / (duration * 1000000)

    printf "ollama_mean_cpu_millicores=%.3f\n", 1000 * ocpu / (duration * 1000000)
    printf "helper_mean_cpu_millicores=%.3f\n", 1000 * hcpu / (duration * 1000000)

    printf "ollama_memory_start_bytes=%.0f\n", oms
    printf "ollama_memory_end_bytes=%.0f\n", ome

    printf "helper_memory_start_bytes=%.0f\n", hms
    printf "helper_memory_end_bytes=%.0f\n", hme
  }' | tee "${OUT_DIR}/resource-summary.txt"

{
  echo "pod=${POD}"
  echo "start_utc=${START_UTC}"
  echo "end_utc=${END_UTC}"
  echo "window_seconds=${ACTUAL_SECONDS}"
} > "${OUT_DIR}/window.txt"

kubectl logs \
  -n "${NAMESPACE}" \
  "${POD}" \
  -c readiness-helper \
  --since="${ACTUAL_SECONDS}s" \
  > "${OUT_DIR}/readiness-helper.log"

kubectl logs \
  -n "${NAMESPACE}" \
  "${POD}" \
  -c ollama \
  --since="${ACTUAL_SECONDS}s" \
  > "${OUT_DIR}/ollama.log"

echo
echo "Results written to ${OUT_DIR}"
