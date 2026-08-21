#!/usr/bin/env bash
#
# Give the GitHub Actions workflow permission to deploy to the demo web app, using OIDC
# (federated credentials) so no Azure password or publish profile is stored in GitHub.
#
# Usage:
#   GITHUB_REPO=kosli-dev/azure-java-appservice-demo ./infra/setup-github-oidc.sh
#
# Requires: az CLI (logged in, with permission to create app registrations), gh CLI
# (optional - used to set the repository secrets for you).
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-kosli-dev/azure-java-appservice-demo}"
APP_NAME="${APP_NAME:-kosli-orders-api-demo-gha}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-kosli-orders-api-demo}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

echo "==> app registration ${APP_NAME}"
CLIENT_ID="$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
if [[ -z "$CLIENT_ID" ]]; then
  CLIENT_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
fi
echo "clientId: $CLIENT_ID"

echo "==> service principal"
az ad sp show --id "$CLIENT_ID" -o none 2>/dev/null || az ad sp create --id "$CLIENT_ID" -o none

echo "==> contributor on the resource group"
az role assignment create \
  --role Contributor \
  --assignee "$CLIENT_ID" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}" \
  -o none 2>/dev/null || echo "(role assignment already exists)"

echo "==> federated credentials for ${GITHUB_REPO}"
for subject in "repo:${GITHUB_REPO}:ref:refs/heads/main" "repo:${GITHUB_REPO}:environment:production"; do
  name="gha-$(echo "$subject" | tr ':/' '--' | tr -cd '[:alnum:]-' | cut -c1-110)"
  az ad app federated-credential create --id "$CLIENT_ID" --parameters "{
    \"name\": \"${name}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${subject}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none 2>/dev/null || echo "(credential ${name} already exists)"
done

cat <<EOF

Done. Set these GitHub repository secrets:

  AZURE_CLIENT_ID       = ${CLIENT_ID}
  AZURE_TENANT_ID       = ${TENANT_ID}
  AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}

With gh CLI:
  gh secret set AZURE_CLIENT_ID       --repo ${GITHUB_REPO} --body "${CLIENT_ID}"
  gh secret set AZURE_TENANT_ID       --repo ${GITHUB_REPO} --body "${TENANT_ID}"
  gh secret set AZURE_SUBSCRIPTION_ID --repo ${GITHUB_REPO} --body "${SUBSCRIPTION_ID}"
EOF
