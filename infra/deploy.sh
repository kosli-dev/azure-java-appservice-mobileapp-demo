#!/usr/bin/env bash
#
# Create (or update) the Azure infrastructure for the demo: a Linux App Service plan and a
# Java SE web app. Run once before the first pipeline run.
#
# Usage:
#   AZURE_WEBAPP_NAME=kosli-orders-api-demo ./infra/deploy.sh
#
# Requires: az CLI, logged in (`az login`), and a selected subscription
# (`az account set -s <subscription>`).
set -euo pipefail

WEBAPP_NAME="${AZURE_WEBAPP_NAME:-kosli-orders-api-demo}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-kosli-orders-api-demo}"
LOCATION="${AZURE_LOCATION:-westeurope}"
SKU="${AZURE_SKU:-B1}"

echo "==> subscription"
az account show --query "{name:name, id:id}" -o tsv

echo "==> resource group ${RESOURCE_GROUP} (${LOCATION})"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

echo "==> deploying infra/main.bicep"
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$(dirname "$0")/main.bicep" \
  --parameters webAppName="$WEBAPP_NAME" sku="$SKU" \
  --query "properties.outputs" \
  -o json

cat <<EOF

Done.

Set these as GitHub repository variables:
  AZURE_WEBAPP_NAME   = ${WEBAPP_NAME}
  AZURE_RESOURCE_GROUP = ${RESOURCE_GROUP}

Then run infra/setup-github-oidc.sh to let GitHub Actions deploy without a stored password.
EOF
