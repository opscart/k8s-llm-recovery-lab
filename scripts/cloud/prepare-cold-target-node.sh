#!/usr/bin/env bash

set -euo pipefail

MODEL="${MODEL:-llama3.2:3b}"
OLLAMA_DIR="${OLLAMA_DIR:-/var/lib/llm-recovery/ollama}"
EVIDENCE_DIR="${EVIDENCE_DIR:-/tmp/cold-node-target-evidence}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "run this script with sudo"
  fi
}

require_root

[[ -d "$OLLAMA_DIR" ]] || fail "artifact directory not found: $OLLAMA_DIR"
[[ -f "$OLLAMA_DIR/artifact-sha256.txt" ]] \
  || fail "artifact manifest missing: $OLLAMA_DIR/artifact-sha256.txt"

mkdir -p "$EVIDENCE_DIR"

echo "Preparing cold target node"
echo "Model         : $MODEL"
echo "Artifact dir  : $OLLAMA_DIR"
echo "Evidence dir  : $EVIDENCE_DIR"

echo
echo "Verifying artifact checksums..."
(
  cd /
  sha256sum -c "$OLLAMA_DIR/artifact-sha256.txt"
) >"$EVIDENCE_DIR/artifact-verify.txt"

echo
echo "Checking for existing Ollama/model-serving processes..."

ps -eo pid,comm,args \
  | grep -E '[o]llama|[l]lama-server' \
  >"$EVIDENCE_DIR/runtime-processes-before.txt" || true

if grep -Eq 'ollama serve|llama-server' "$EVIDENCE_DIR/runtime-processes-before.txt"; then
  cat "$EVIDENCE_DIR/runtime-processes-before.txt"
  fail "model-serving process is already running on target node"
fi

grep '^Cached:' /proc/meminfo \
  >"$EVIDENCE_DIR/meminfo-cached-before.txt"

echo
echo "Dropping node-level Linux filesystem/page caches..."
sync
echo 3 > /proc/sys/vm/drop_caches

grep '^Cached:' /proc/meminfo \
  >"$EVIDENCE_DIR/meminfo-cached-after.txt"

BEFORE=$(awk '{print $2}' "$EVIDENCE_DIR/meminfo-cached-before.txt")
AFTER=$(awk '{print $2}' "$EVIDENCE_DIR/meminfo-cached-after.txt")

if [[ -z "$BEFORE" || -z "$AFTER" ]]; then
  fail "could not read Cached values from /proc/meminfo"
fi

if (( AFTER >= BEFORE )); then
  echo "WARNING: Cached did not decrease after drop_caches"
fi

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname)"
  echo "kernel=$(uname -r)"
  echo "model=$MODEL"
  echo "artifact_dir=$OLLAMA_DIR"
  echo "cached_kb_before=$BEFORE"
  echo "cached_kb_after=$AFTER"
  echo "model_serving_process_present=false"
  echo "drop_caches_success=true"
} >"$EVIDENCE_DIR/target-precondition.txt"

echo
echo "Cold target precondition established:"
cat "$EVIDENCE_DIR/target-precondition.txt"

echo
echo "Important:"
echo "Do not run Ollama inference on this node before the measured relocation."
