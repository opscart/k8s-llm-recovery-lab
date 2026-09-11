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

az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --show-details \
  --query '{Name:name,Size:hardwareProfile.vmSize,PowerState:powerState,PublicIP:publicIps,PrivateIP:privateIps}' \
  --output table
