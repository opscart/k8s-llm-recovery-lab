#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="${RAG_VENV_DIR:-$REPO_ROOT/.venv-rag}"
PYTHON="$VENV_DIR/bin/python"
CONFIG="${RAG_REPOS_CONFIG:-$REPO_ROOT/rag/config/repos.local.json}"
INDEX_DIR="${RAG_INDEX_DIR:-$REPO_ROOT/artifacts/rag/index}"

[[ -x "$PYTHON" ]] || {
  echo "ERROR: run scripts/rag/setup-rag-env.sh first" >&2
  exit 1
}
[[ -r "$CONFIG" ]] || {
  echo "ERROR: create and review $CONFIG first" >&2
  exit 1
}

export HF_HOME="${HF_HOME:-$REPO_ROOT/artifacts/rag/huggingface}"
export TOKENIZERS_PARALLELISM=false
export PYTHONPATH="$REPO_ROOT/rag/src${PYTHONPATH:+:$PYTHONPATH}"

exec "$PYTHON" -m raglab.indexer \
  --config "$CONFIG" \
  --output "$INDEX_DIR" \
  --base-dir "$REPO_ROOT" \
  "$@"
