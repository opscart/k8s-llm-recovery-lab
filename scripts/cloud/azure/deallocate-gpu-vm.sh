#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-k8s-llm-gpu-recovery}"
VM_NAME="${VM_NAME:-k8s-llm-gpu-01}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v az >/dev/null 2>&1 || fail "Azure CLI (az) is required"
az account show --output none >/dev/null 2>&1 \
  || fail "Azure CLI is not logged in"

az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --output none >/dev/null 2>&1 \
  || fail "VM not found: $RESOURCE_GROUP/$VM_NAME"

POWER_STATE="$(az vm get-instance-view \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" \
  --output tsv)"

echo "GPU VM: $RESOURCE_GROUP/$VM_NAME"
echo "Current state: ${POWER_STATE:-unknown}"

if [[ "$POWER_STATE" == "VM deallocated" ]]; then
  echo "VM is already deallocated."
  exit 0
fi

echo "Deallocating the VM to stop compute billing..."
az vm deallocate \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --output none

POWER_STATE="$(az vm get-instance-view \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" \
  --output tsv)"

[[ "$POWER_STATE" == "VM deallocated" ]] \
  || fail "deallocation returned, but state is '${POWER_STATE:-unknown}'"

echo "VM deallocated. Compute billing is stopped; disks and public IP remain allocated."
