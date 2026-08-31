#!/usr/bin/env bash
set -euo pipefail

LOCATION="${LOCATION:-southcentralus}"
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-k8s-llm-gpu-recovery}"
VM_NAME="${VM_NAME:-k8s-llm-gpu-01}"
VM_SIZE="${VM_SIZE:-Standard_NC8as_T4_v3}"
ADMIN_USER="${ADMIN_USER:-opscart}"
IMAGE_URN="${IMAGE_URN:-}"
OS_DISK_SIZE_GB="${OS_DISK_SIZE_GB:-64}"
DATA_DISK_SIZE_GB="${DATA_DISK_SIZE_GB:-128}"
DATA_DISK_NAME="${DATA_DISK_NAME:-${VM_NAME}-models}"
EXECUTE="${EXECUTE:-0}"

fail() { echo "ERROR: $*" >&2; exit 1; }

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$EXECUTE" == "1" ]]; then
    "$@"
  fi
}

command -v az >/dev/null 2>&1 || fail "Azure CLI (az) is required"
az account show >/dev/null 2>&1 || fail "Azure CLI is not logged in"
[[ -n "$IMAGE_URN" ]] || fail "set IMAGE_URN to a reviewed, exact Ubuntu image URN"

echo "GPU VM provisioning plan"
echo "Location       : $LOCATION"
echo "Resource group : $RESOURCE_GROUP"
echo "VM             : $VM_NAME"
echo "Size           : $VM_SIZE"
echo "Image          : $IMAGE_URN"
echo "OS disk        : ${OS_DISK_SIZE_GB} GiB"
echo "Model disk     : ${DATA_DISK_SIZE_GB} GiB"
echo "Execute        : $EXECUTE"

LIMIT="$(az vm list-usage --location "$LOCATION" --query "[?contains(name.localizedValue, 'NCASv3_T4')].limit | [0]" -o tsv 2>/dev/null || true)"
CURRENT="$(az vm list-usage --location "$LOCATION" --query "[?contains(name.localizedValue, 'NCASv3_T4')].currentValue | [0]" -o tsv 2>/dev/null || true)"
echo "NCASv3_T4 quota: ${CURRENT:-unknown}/${LIMIT:-unknown}"
if [[ -n "$LIMIT" && "$LIMIT" -lt 8 ]]; then
  fail "insufficient NCASv3_T4 quota in $LOCATION"
fi

RESTRICTIONS="$(az vm list-skus --location "$LOCATION" --size "$VM_SIZE" --all --query "[0].restrictions" -o json)"
echo "SKU restrictions: $RESTRICTIONS"
[[ "$RESTRICTIONS" == "[]" ]] || fail "$VM_SIZE has restrictions in $LOCATION"

az vm image show --urn "$IMAGE_URN" -o none

if [[ "$EXECUTE" != "1" ]]; then
  echo "Preflight only. No resources will be created."
fi

run az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

run az vm create   --resource-group "$RESOURCE_GROUP"   --name "$VM_NAME"   --location "$LOCATION"   --size "$VM_SIZE"   --image "$IMAGE_URN"   --admin-username "$ADMIN_USER"   --generate-ssh-keys   --os-disk-size-gb "$OS_DISK_SIZE_GB"   --storage-sku StandardSSD_LRS   --security-type Standard   --public-ip-sku Standard

run az disk create   --resource-group "$RESOURCE_GROUP"   --name "$DATA_DISK_NAME"   --location "$LOCATION"   --size-gb "$DATA_DISK_SIZE_GB"   --sku Premium_LRS

run az vm disk attach   --resource-group "$RESOURCE_GROUP"   --vm-name "$VM_NAME"   --name "$DATA_DISK_NAME"

run az vm extension set   --resource-group "$RESOURCE_GROUP"   --vm-name "$VM_NAME"   --name NvidiaGpuDriverLinux   --publisher Microsoft.HpcCompute   --version 1.6

echo "Provisioning flow completed."

