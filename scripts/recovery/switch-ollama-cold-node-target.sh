#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-recovery-lab}"
DEPLOYMENT="${DEPLOYMENT:-ollama}"

MODE="${1:-}"

SOURCE_ROLE="${SOURCE_ROLE:-source}"
TARGET_ROLE="${TARGET_ROLE:-target}"

SOURCE_PVC="${SOURCE_PVC:-ollama-models-source}"
TARGET_PVC="${TARGET_PVC:-ollama-models-target}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $0 source
  $0 target

Environment:
  NAMESPACE   default: $NAMESPACE
  DEPLOYMENT  default: $DEPLOYMENT
  SOURCE_PVC  default: $SOURCE_PVC
  TARGET_PVC  default: $TARGET_PVC
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_cmd kubectl

case "$MODE" in
  source)
    ROLE="$SOURCE_ROLE"
    PVC="$SOURCE_PVC"
    ;;
  target)
    ROLE="$TARGET_ROLE"
    PVC="$TARGET_PVC"
    ;;
  *)
    usage
    exit 2
    ;;
esac

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || fail "namespace not found: $NAMESPACE"

kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" >/dev/null 2>&1 \
  || fail "deployment not found: $NAMESPACE/$DEPLOYMENT"

kubectl get pvc -n "$NAMESPACE" "$PVC" >/dev/null 2>&1 \
  || fail "PVC not found: $NAMESPACE/$PVC"

PVC_PHASE=$(kubectl get pvc -n "$NAMESPACE" "$PVC" \
  -o jsonpath='{.status.phase}')

[[ "$PVC_PHASE" == "Bound" ]] \
  || fail "PVC is not Bound: $NAMESPACE/$PVC (phase=$PVC_PHASE)"

CURRENT_ROLE=$(kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.nodeSelector.llm-recovery-role}' 2>/dev/null || true)

CURRENT_PVC=$(kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="models")].persistentVolumeClaim.claimName}' \
  2>/dev/null || true)

echo "Cold-node workload switch"
echo "Deployment   : $NAMESPACE/$DEPLOYMENT"
echo "Current role : ${CURRENT_ROLE:-<unset>}"
echo "Current PVC  : ${CURRENT_PVC:-<unset>}"
echo "Requested    : role=$ROLE pvc=$PVC"

if [[ "$CURRENT_ROLE" == "$ROLE" && "$CURRENT_PVC" == "$PVC" ]]; then
  echo "Deployment already matches requested state."
  exit 0
fi

PATCH=$(cat <<EOF
[
  {
    "op": "add",
    "path": "/spec/template/spec/nodeSelector",
    "value": {
      "llm-recovery-role": "$ROLE"
    }
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/volumes/0/persistentVolumeClaim/claimName",
    "value": "$PVC"
  }
]
EOF
)

kubectl patch deployment -n "$NAMESPACE" "$DEPLOYMENT" \
  --type=json \
  -p "$PATCH" >/dev/null

echo
echo "Patched deployment."
echo "Expected node role : $ROLE"
echo "Expected PVC       : $PVC"

kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT" \
  -o jsonpath='nodeSelector={.spec.template.spec.nodeSelector.llm-recovery-role}{"\n"}pvc={.spec.template.spec.volumes[?(@.name=="models")].persistentVolumeClaim.claimName}{"\n"}'
