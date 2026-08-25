#!/usr/bin/env bash
#
# Give the GitHub Actions workflow permission to deploy to the demo web app, using OIDC
# (federated credentials) so no Azure password or publish profile is stored in GitHub.
#
# Usage:
#   GITHUB_REPO=kosli-dev/azure-java-appservice-demo ./infra/setup-github-oidc.sh
#
# Grants Contributor on every environment's resource group, so run infra/deploy.sh for both
# environments first - a role assignment on a resource group that does not exist yet fails.
#
# Requires: az CLI (logged in, with permission to create app registrations) and gh CLI
# (authenticated - used to read the numeric org and repo IDs, and to set the secrets for you).
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-kosli-dev/azure-java-appservice-mobileapp-demo}"
APP_NAME="${APP_NAME:-kosli-orders-api-demo-gha}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-kosli-orders-api-demo}"
RESOURCE_GROUP_STAGING="${AZURE_RESOURCE_GROUP_STAGING:-rg-kosli-orders-api-demo-staging}"

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

for group in "$RESOURCE_GROUP" "$RESOURCE_GROUP_STAGING"; do
  echo "==> contributor on ${group}"
  az role assignment create \
    --role Contributor \
    --assignee "$CLIENT_ID" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${group}" \
    -o none 2>/dev/null || echo "(role assignment already exists)"
done

echo "==> federated credentials for ${GITHUB_REPO}"
# GitHub can send either subject format, decided by the org's "immutable identifiers"
# setting, so create both for every claim - Entra matches the subject string exactly, and the
# wrong format fails azure/login with AADSTS700213 naming the subject it presented.
#
# The immutable format embeds the numeric org and repo IDs *alongside* the names
# (repo:org@1234/repo@5678:...), so it is not rename-proof either: both formats have to be
# recreated after a repository or organisation rename.
OWNER="${GITHUB_REPO%%/*}"
REPO="${GITHUB_REPO##*/}"
OWNER_ID="${GITHUB_OWNER_ID:-$(gh api "/repos/${GITHUB_REPO}" --jq .owner.id)}"
REPO_ID="${GITHUB_REPO_ID:-$(gh api "/repos/${GITHUB_REPO}" --jq .id)}"
echo "org ${OWNER}@${OWNER_ID}, repo ${REPO}@${REPO_ID}"

# One claim per environment a job deploys from: a job with `environment:` gets an
# environment-scoped subject, not the branch one, so a missing entry fails azure/login.
for claim in "ref:refs/heads/main" "environment:production" "environment:staging"; do
  for subject in \
    "repo:${GITHUB_REPO}:${claim}" \
    "repo:${OWNER}@${OWNER_ID}/${REPO}@${REPO_ID}:${claim}"; do
    name="gha-$(echo "$subject" | tr ':/' '--' | tr -cd '[:alnum:]-' | cut -c1-110)"
    az ad app federated-credential create --id "$CLIENT_ID" --parameters "{
      \"name\": \"${name}\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"${subject}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" -o none 2>/dev/null || echo "(credential ${name} already exists)"
  done
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
