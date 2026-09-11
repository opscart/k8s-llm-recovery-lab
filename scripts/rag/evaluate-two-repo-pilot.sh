#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="${RAG_VENV_DIR:-$REPO_ROOT/.venv-rag}"
PYTHON="$VENV_DIR/bin/python"
INDEX_DIR="${RAG_INDEX_DIR:-$REPO_ROOT/artifacts/rag/index-two-repo}"
QUESTIONS="${RAG_QUESTIONS:-$REPO_ROOT/rag/evaluation/questions.two-repo.example.jsonl}"
REPORT="${RAG_REPORT:-$REPO_ROOT/results/rag/two-repo-evaluation.json}"

[[ -x "$PYTHON" ]] || {
  echo "ERROR: run scripts/rag/setup-rag-env.sh first" >&2
  exit 1
}
[[ -r "$INDEX_DIR/manifest.json" ]] || {
  echo "ERROR: two-repository index not found: $INDEX_DIR" >&2
  echo "Build it using the reviewed two-repository local config first." >&2
  exit 1
}
[[ -r "$QUESTIONS" ]] || {
  echo "ERROR: evaluation questions not found: $QUESTIONS" >&2
  exit 1
}

export HF_HOME="${HF_HOME:-$REPO_ROOT/artifacts/rag/huggingface}"
export HF_HUB_OFFLINE=1
export TOKENIZERS_PARALLELISM=false
export PYTHONPATH="$REPO_ROOT/rag/src${PYTHONPATH:+:$PYTHONPATH}"

exec "$PYTHON" -m raglab.evaluate \
  --index "$INDEX_DIR" \
  --questions "$QUESTIONS" \
  --minimum-hit-rate 0.85 \
  --minimum-repository-hit-rate 0.80 \
  --minimum-negative-pass-rate 1.0 \
  --minimum-positive-answerability-rate 1.0 \
  --maximum-cross-repository-top1-rate 0.20 \
  --minimum-answerable-score 0.68 \
  --output "$REPORT" \
  "$@"
