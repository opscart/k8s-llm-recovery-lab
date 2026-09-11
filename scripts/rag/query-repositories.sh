#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="${RAG_VENV_DIR:-$REPO_ROOT/.venv-rag}"
PYTHON="$VENV_DIR/bin/python"
INDEX_DIR="${RAG_INDEX_DIR:-$REPO_ROOT/artifacts/rag/index}"

[[ -x "$PYTHON" ]] || {
  echo "ERROR: run scripts/rag/setup-rag-env.sh first" >&2
  exit 1
}
[[ -r "$INDEX_DIR/manifest.json" ]] || {
  echo "ERROR: RAG index not found: $INDEX_DIR" >&2
  exit 1
}

export HF_HOME="${HF_HOME:-$REPO_ROOT/artifacts/rag/huggingface}"
export HF_HUB_OFFLINE=1
export TOKENIZERS_PARALLELISM=false
export PYTHONPATH="$REPO_ROOT/rag/src${PYTHONPATH:+:$PYTHONPATH}"

cd "$REPO_ROOT"
exec "$PYTHON" -m raglab.query --index "$INDEX_DIR" "$@"
