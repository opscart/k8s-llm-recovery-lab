#!/usr/bin/env bash

set -euo pipefail

MODEL="${MODEL:-llama3.2:3b}"
OLLAMA_DIR="${OLLAMA_DIR:-/var/lib/llm-recovery/ollama}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-ollama/ollama@sha256:020e4134285e2ef4d8fd801234176de3b4faadc992a3eb06c8e66a2f9d4c4ba2}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "run this script with sudo"
  fi
}

require_root
require_cmd ctr
require_cmd sha256sum

mkdir -p "$OLLAMA_DIR"

echo "Staging Ollama model artifact"
echo "Model      : $MODEL"
echo "Directory  : $OLLAMA_DIR"
echo "Image      : $CONTAINER_IMAGE"

echo
echo "Ensuring runtime image is available to containerd..."
ctr -n k8s.io images pull "docker.io/${CONTAINER_IMAGE}" >/dev/null

echo
echo "Pulling model into node-local artifact directory..."

TEMP_NAME="ollama-stage-$(date +%s)"

cleanup() {
  ctr -n k8s.io tasks kill -s SIGKILL "$TEMP_NAME" >/dev/null 2>&1 || true
  ctr -n k8s.io tasks delete "$TEMP_NAME" >/dev/null 2>&1 || true
  ctr -n k8s.io containers delete "$TEMP_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ctr -n k8s.io run \
  --rm \
  --mount type=bind,src="$OLLAMA_DIR",dst=/root/.ollama,options=rbind:rw \
  "docker.io/${CONTAINER_IMAGE}" \
  "$TEMP_NAME" \
  ollama serve >/tmp/ollama-stage.log 2>&1 &

OLLAMA_PID=$!

for _ in $(seq 1 60); do
  if ctr -n k8s.io tasks exec \
    --exec-id check-"$RANDOM" \
    "$TEMP_NAME" \
    ollama list >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! kill -0 "$OLLAMA_PID" >/dev/null 2>&1; then
  cat /tmp/ollama-stage.log >&2 || true
  fail "temporary Ollama runtime exited before staging completed"
fi

ctr -n k8s.io tasks exec \
  --exec-id pull-"$RANDOM" \
  "$TEMP_NAME" \
  ollama pull "$MODEL"

ctr -n k8s.io tasks exec \
  --exec-id list-"$RANDOM" \
  "$TEMP_NAME" \
  ollama list

echo
echo "Stopping temporary staging runtime..."
kill "$OLLAMA_PID" >/dev/null 2>&1 || true
wait "$OLLAMA_PID" 2>/dev/null || true
cleanup
trap - EXIT

echo
echo "Recording artifact evidence..."

find "$OLLAMA_DIR" -type f -print0 \
  | sort -z \
  | xargs -0 sha256sum \
  > "$OLLAMA_DIR/artifact-sha256.txt"

du -sh "$OLLAMA_DIR"

echo
echo "Artifact manifest:"
cat "$OLLAMA_DIR/artifact-sha256.txt"

echo
echo "Model artifact staging completed."
echo "No inference request was executed during staging."
