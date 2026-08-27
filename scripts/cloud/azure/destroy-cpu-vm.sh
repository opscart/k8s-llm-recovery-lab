#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-k8s-llm-recovery}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"

echo "============================================================"
echo "Azure LLM recovery environment cleanup"
echo "============================================================"
echo "Resource group: $RESOURCE_GROUP"
echo

if [[ "$(az group exists --name "$RESOURCE_GROUP")" != "true" ]]; then
  echo "Resource group '$RESOURCE_GROUP' does not exist."
  exit 0
fi

echo "Resources that will be deleted:"
az resource list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[].{name:name,type:type,location:location}" \
  --output table

echo

if [[ "$AUTO_APPROVE" != "true" ]]; then
  read -r -p "Delete '$RESOURCE_GROUP' and ALL resources inside it? [y/N]: " ANSWER

  case "$ANSWER" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Cleanup cancelled."
      exit 0
      ;;
  esac
fi

echo
echo "Deleting resource group..."

az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --no-wait

echo
echo "Delete request submitted."
echo
echo "Check completion with:"
echo "  az group exists --name $RESOURCE_GROUP"
echo
echo "It should eventually return:"
echo "  false"