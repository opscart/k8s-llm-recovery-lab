#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON="${PYTHON_BIN:-python3}"

command -v "$PYTHON" >/dev/null 2>&1 || {
  echo "ERROR: Python not found: $PYTHON" >&2
  exit 1
}

export PYTHONPATH="$REPO_ROOT/rag/src${PYTHONPATH:+:$PYTHONPATH}"

exec "$PYTHON" -m unittest discover \
  -s "$REPO_ROOT/rag/tests" \
  -p 'test_*.py' \
  -v
