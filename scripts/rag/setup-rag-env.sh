#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="${RAG_VENV_DIR:-${VENV_DIR:-$REPO_ROOT/.venv-rag}}"
REQUIREMENTS="$REPO_ROOT/rag/requirements.txt"
TORCH_VERSION="${TORCH_VERSION:-2.14.0}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

choose_python() {
  if [[ -n "${PYTHON_BIN:-}" ]]; then
    command -v "$PYTHON_BIN" >/dev/null 2>&1 || fail "PYTHON_BIN not found: $PYTHON_BIN"
    echo "$PYTHON_BIN"
    return
  fi

  for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done

  fail "Python 3.10 through 3.13 is required"
}

PYTHON="$(choose_python)"

"$PYTHON" - <<'PY'
import sys

if not ((3, 10) <= sys.version_info[:2] <= (3, 13)):
    raise SystemExit(
        "ERROR: use Python 3.10 through 3.13 for the pinned RAG dependencies"
    )
print(f"Python: {sys.version.split()[0]}")
PY

[[ -r "$REQUIREMENTS" ]] || fail "missing requirements file: $REQUIREMENTS"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$PYTHON" -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip

case "$(uname -s)" in
  Linux)
    "$VENV_DIR/bin/python" -m pip install \
      --index-url https://download.pytorch.org/whl/cpu \
      "torch==${TORCH_VERSION}+cpu"
    ;;
  Darwin)
    "$VENV_DIR/bin/python" -m pip install "torch==${TORCH_VERSION}"
    ;;
  *)
    fail "unsupported operating system for the CPU-only RAG environment: $(uname -s)"
    ;;
esac

"$VENV_DIR/bin/python" -m pip install --requirement "$REQUIREMENTS"

"$VENV_DIR/bin/python" - <<'PY'
import sqlite3

import numpy
import sentence_transformers
import torch

if torch.version.cuda is not None:
    raise SystemExit(
        "ERROR: the RAG environment installed a CUDA-enabled PyTorch build; "
        "remove this virtual environment and rerun setup"
    )

connection = sqlite3.connect(":memory:")
connection.execute("CREATE VIRTUAL TABLE probe USING fts5(content)")
connection.close()

print(f"NumPy: {numpy.__version__}")
print(f"PyTorch: {torch.__version__} (CPU only)")
print(f"Sentence Transformers: {sentence_transformers.__version__}")
print("SQLite FTS5: available")
PY

echo
echo "RAG environment is ready: $VENV_DIR"
echo "Next: copy rag/config/repos.example.json to rag/config/repos.local.json and review it."
