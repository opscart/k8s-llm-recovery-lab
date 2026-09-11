#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON="$REPO_ROOT/.venv-rag/bin/python"
INDEX_DIR="${RAG_INDEX_DIR:-$REPO_ROOT/artifacts/rag/index}"
QUESTIONS="${RAG_QUESTIONS:-$REPO_ROOT/rag/evaluation/questions.example.jsonl}"
REPORT="${RAG_REPORT:-$REPO_ROOT/results/rag/retrieval-evaluation.json}"

[[ -x "$PYTHON" ]] || {
  echo "ERROR: run scripts/rag/setup-rag-env.sh first" >&2
  exit 1
}
[[ -r "$INDEX_DIR/manifest.json" ]] || {
  echo "ERROR: RAG index not found: $INDEX_DIR" >&2
  exit 1
}
[[ -r "$QUESTIONS" ]] || {
  echo "ERROR: evaluation questions not found: $QUESTIONS" >&2
  exit 1
}

export HF_HOME="${HF_HOME:-$REPO_ROOT/artifacts/rag/huggingface}"
export TOKENIZERS_PARALLELISM=false
export PYTHONPATH="$REPO_ROOT/rag/src${PYTHONPATH:+:$PYTHONPATH}"

exec "$PYTHON" -m raglab.evaluate \
  --index "$INDEX_DIR" \
  --questions "$QUESTIONS" \
  --output "$REPORT" \
  "$@"
