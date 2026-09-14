#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_SCRIPT="$SCRIPT_DIR/query-repositories.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/rag/diagnose-opscart-incident.sh INCIDENT.json [query options]

Examples:
  RAG_INDEX_DIR=artifacts/rag/index-two-repo \
    scripts/rag/diagnose-opscart-incident.sh \
    rag/fixtures/incidents/checkout-api-probe-failure.json \
    --retrieve-only

  RAG_INDEX_DIR=artifacts/rag/index-two-repo \
    scripts/rag/diagnose-opscart-incident.sh incident.json

The incident is live observation only. Repository retrieval remains the source of
truth for configuration and remediation citations. Version 2 adds an exact source
repository and path; incidents without that identity cannot authorize an LLM
call. The contract does not accept container logs or Kubernetes credentials.
EOF
}

[[ $# -ge 1 ]] || {
  usage >&2
  exit 2
}

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

INCIDENT_FILE="$1"
shift

[[ -r "$INCIDENT_FILE" ]] || {
  echo "ERROR: incident file is not readable: $INCIDENT_FILE" >&2
  exit 1
}
[[ -x "$QUERY_SCRIPT" ]] || {
  echo "ERROR: query script is missing or not executable: $QUERY_SCRIPT" >&2
  exit 1
}

has_question=0
for argument in "$@"; do
  case "$argument" in
    --question|--question=*|--question-file|--question-file=*)
      has_question=1
      ;;
  esac
done

query_args=(--incident-file "$INCIDENT_FILE")
if [[ "$has_question" -eq 0 ]]; then
  query_args+=(
    --question
    "Diagnose this incident from repository evidence. Explain the likely cause, cite the exact configuration, and propose the smallest safe change. Do not claim to have applied the change."
  )
fi

exec "$QUERY_SCRIPT" "${query_args[@]}" "$@"
