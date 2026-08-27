#!/usr/bin/env bash
set -euo pipefail

# Azure CPU VM for Kubernetes LLM recovery experiments.
# Requires: Azure CLI logged in with `az login`.
#
# Defaults target a 16 vCPU / 64 GiB VM. Override any value:
#   LOCATION=eastus2 VM_SIZE=Standard_D16s_v5 ./create-cpu-vm.sh

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-k8s-llm-recovery}"
LOCATION="${LOCATION:-eastus2}"
VM_NAME="${VM_NAME:-k8s-llm-cpu-01}"
VM_SIZE="${VM_SIZE:-Standard_D16s_v5}"
ADMIN_USER="${ADMIN_USER:-opscart}"
OS_DISK_GB="${OS_DISK_GB:-256}"
IMAGE="${IMAGE:-Ubuntu2204}"

echo "== Azure LLM recovery CPU VM =="
echo "Resource group : $RESOURCE_GROUP"
echo "Location       : $LOCATION"
echo "VM name        : $VM_NAME"
echo "VM size        : $VM_SIZE"
echo "Admin user     : $ADMIN_USER"
echo "Image          : $IMAGE"
echo "OS disk        : ${OS_DISK_GB} GiB"
echo

az account show --output table

echo
echo "Checking VM size availability in $LOCATION ..."
if ! az vm list-skus \
  --location "$LOCATION" \
  --size "$VM_SIZE" \
  --all \
  --query "[?name=='$VM_SIZE'] | length(@)" \
  -o tsv | grep -qE '^[1-9][0-9]*$'; then
  echo "ERROR: $VM_SIZE was not returned for $LOCATION."
  echo "Try another region or VM_SIZE."
  exit 1
fi

echo "Creating resource group ..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

echo "Creating VM ..."
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --location "$LOCATION" \
  --image "$IMAGE" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --os-disk-size-gb "$OS_DISK_GB" \
  --storage-sku Premium_LRS \
  --public-ip-sku Standard \
  --output jsonc

PUBLIC_IP="$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --show-details \
  --query publicIps \
  -o tsv)"

echo
echo "VM created."
echo "Public IP: $PUBLIC_IP"
echo
echo "SSH:"
echo "  ssh ${ADMIN_USER}@${PUBLIC_IP}"
echo
echo "After login, copy/run:"
echo "  bootstrap-minikube.sh"
