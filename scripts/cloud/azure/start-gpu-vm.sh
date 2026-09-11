#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-k8s-llm-gpu-recovery}"
VM_NAME="${VM_NAME:-k8s-llm-gpu-01}"
ADMIN_USER="${ADMIN_USER:-opscart}"

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

if [[ "$POWER_STATE" == "VM running" ]]; then
  echo "VM is already running."
else
  echo "Starting the VM. Compute billing resumes when the VM is allocated."
  az vm start \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --output none
fi

PUBLIC_IP="$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --show-details \
  --query publicIps \
  --output tsv)"

[[ -n "$PUBLIC_IP" ]] || fail "VM is running but no public IP was returned"

echo "VM running."
echo "Public IP: $PUBLIC_IP"
echo "SSH: ssh ${ADMIN_USER}@${PUBLIC_IP}"
echo "When finished, run: scripts/cloud/azure/deallocate-gpu-vm.sh"
