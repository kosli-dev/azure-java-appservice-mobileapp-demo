#!/usr/bin/env bash
#
# Create (or update) the Azure infrastructure for one environment of the demo: a Linux App
# Service plan and a Java SE web app, in that environment's own resource group. Run once per
# environment before the first pipeline run.
#
# One resource group per environment on purpose: `kosli snapshot azure` snapshots a whole
# resource group, so sharing one would report staging and prod into the same Kosli
# environment and make them impossible to gate apart.
#
# Usage:
#   ./infra/deploy.sh            # prod (default)
#   ./infra/deploy.sh staging
#
# Names are derived from the environment; AZURE_WEBAPP_NAME, AZURE_RESOURCE_GROUP,
# AZURE_LOCATION and AZURE_SKU still override them.
#
# Requires: az CLI, logged in (`az login`), and a selected subscription
# (`az account set -s <subscription>`).
set -euo pipefail

ENVIRONMENT="${1:-prod}"
case "$ENVIRONMENT" in
  prod)    suffix="" ;;
  staging) suffix="-staging" ;;
  *)
    echo "usage: $0 [prod|staging]" >&2
    exit 2
    ;;
esac

WEBAPP_NAME="${AZURE_WEBAPP_NAME:-kosli-orders-api-demo${suffix}}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-kosli-orders-api-demo${suffix}}"
LOCATION="${AZURE_LOCATION:-westeurope}"
SKU="${AZURE_SKU:-B1}"

echo "==> subscription"
az account show --query "{name:name, id:id}" -o tsv

echo "==> resource group ${RESOURCE_GROUP} (${LOCATION})"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

echo "==> deploying infra/main.bicep for ${ENVIRONMENT}"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$(dirname "$0")/main.bicep" \
  --parameters webAppName="$WEBAPP_NAME" sku="$SKU" environment="$ENVIRONMENT" \
  --query "properties.outputs" \
  -o json

if [[ "$ENVIRONMENT" == "prod" ]]; then
  webapp_var="AZURE_WEBAPP_NAME"
  group_var="AZURE_RESOURCE_GROUP"
else
  webapp_var="AZURE_WEBAPP_NAME_STAGING"
  group_var="AZURE_RESOURCE_GROUP_STAGING"
fi

cat <<EOF

Done (${ENVIRONMENT}).

Set these as GitHub repository variables:
  ${webapp_var} = ${WEBAPP_NAME}
  ${group_var} = ${RESOURCE_GROUP}

Run this script again with the other environment if you have not already, then run
infra/setup-github-oidc.sh to let GitHub Actions deploy without a stored password.
EOF
