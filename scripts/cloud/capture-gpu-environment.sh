#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-recovery-lab}"
OUT="${OUT:-results/cloud-gpu/environment/gpu-environment.txt}"

mkdir -p "$(dirname "$OUT")"

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "== host =="
  hostnamectl 2>/dev/null || true
  uname -a
  echo
  lscpu 2>/dev/null || true
  echo
  free -h 2>/dev/null || true

  echo
  echo "== nvidia-smi =="
  nvidia-smi || true

  echo
  echo "== nvidia query =="
  nvidia-smi --query-gpu=name,uuid,driver_version,memory.total,memory.used,memory.free \
    --format=csv,noheader 2>/dev/null || true

  echo
  echo "== kubernetes =="
  kubectl version 2>/dev/null || true
  kubectl get nodes -o wide 2>/dev/null || true

  echo
  echo "== gpu allocatable =="
  kubectl get nodes \
    -o custom-columns='NAME:.metadata.name,GPU_CAPACITY:.status.capacity.nvidia\.com/gpu,GPU_ALLOCATABLE:.status.allocatable.nvidia\.com/gpu' \
    2>/dev/null || true

  echo
  echo "== runtime =="
  crictl info 2>/dev/null | head -n 120 || true
  containerd --version 2>/dev/null || true

  echo
  echo "== ollama pod =="
  kubectl get pod -n "$NAMESPACE" -l app=ollama -o wide 2>/dev/null || true

  POD="$(kubectl get pod -n "$NAMESPACE" -l app=ollama \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -n "$POD" ]]; then
    echo
    echo "== pod gpu resources =="
    kubectl get pod -n "$NAMESPACE" "$POD" \
      -o jsonpath='{.spec.containers[?(@.name=="ollama")].resources}' 2>/dev/null || true
    echo

    echo
    echo "== ollama logs gpu evidence =="
    kubectl logs -n "$NAMESPACE" "$POD" -c ollama --tail=300 2>/dev/null || true

    echo
    echo "== ollama ps =="
    kubectl exec -n "$NAMESPACE" "$POD" -c ollama -- ollama ps 2>/dev/null || true
  fi
} | tee "$OUT"

echo "Wrote: $OUT"

