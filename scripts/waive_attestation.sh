#!/usr/bin/env bash
#
# Waive (override) a non-compliant attestation, with a reason that is recorded forever.
#
# This is the scripted equivalent of clicking "Override" on the attestation in the Kosli UI:
# it POSTs to the trail's override endpoint, Kosli recalculates compliance for the trail and
# the artifact, and the override - who, when, why - stays attached to the trail as evidence.
#
# Usage:
#   scripts/waive_attestation.sh \
#     --trail  <trail-name (the git sha)> \
#     --fingerprint <artifact sha256> \
#     --reason "Mutation score signed off by QA, ticket ORD-482, fix planned for next sprint" \
#     [--attestation mutation-tests] \
#     [--artifact orders-api] \
#     [--type custom:mutation-testing] \
#     [--compliant true]
#
# Requires: KOSLI_PUBLIC_API_TOKEN, KOSLI_ORG, KOSLI_FLOW (or --flow), curl.
#
# NOTE: the attestation name here is the name from the flow template (e.g. mutation-tests),
# not the dotted CLI form (orders-api.mutation-tests) - the artifact is identified separately.
set -euo pipefail

KOSLI_HOST="${KOSLI_HOST:-https://app.kosli.com}"
FLOW="${KOSLI_FLOW:-}"
TRAIL=""
FINGERPRINT=""
REASON=""
ATTESTATION="mutation-tests"
ARTIFACT="orders-api"
TYPE="custom:mutation-testing"
COMPLIANT="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow) FLOW="$2"; shift 2 ;;
    --trail) TRAIL="$2"; shift 2 ;;
    --fingerprint) FINGERPRINT="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --attestation) ATTESTATION="$2"; shift 2 ;;
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --type) TYPE="$2"; shift 2 ;;
    --compliant) COMPLIANT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

: "${KOSLI_PUBLIC_API_TOKEN:?set KOSLI_PUBLIC_API_TOKEN}"
: "${KOSLI_ORG:?set KOSLI_ORG}"
: "${FLOW:?set KOSLI_FLOW or pass --flow}"
: "${TRAIL:?pass --trail}"
: "${FINGERPRINT:?pass --fingerprint}"
: "${REASON:?pass --reason - a waiver without a reason is not a waiver}"

payload="$(jq -n \
  --arg name "$ATTESTATION" \
  --arg artifact "$ARTIFACT" \
  --arg fingerprint "$FINGERPRINT" \
  --arg type "$TYPE" \
  --arg reason "$REASON" \
  --arg waived_by "${WAIVED_BY:-$(whoami)}" \
  --argjson compliant "$COMPLIANT" \
  '{
     attestation_name: $name,
     target_artifacts: [$artifact],
     artifact_fingerprint: $fingerprint,
     original_attestation_type: $type,
     reason: $reason,
     new_compliance_status: $compliant,
     user_data: { waived_by: $waived_by }
   }')"

url="${KOSLI_HOST}/api/v2/attestations/${KOSLI_ORG}/${FLOW}/trail/${TRAIL}/override"

echo "POST $url"
echo "$payload" | jq .

http_code="$(curl -sS -o /tmp/kosli-waiver-response.txt -w '%{http_code}' \
  -X POST "$url" \
  -H "Authorization: Bearer ${KOSLI_PUBLIC_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$payload")"

echo "HTTP $http_code"
cat /tmp/kosli-waiver-response.txt
echo

if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
  echo "waiver failed" >&2
  exit 1
fi

echo
echo "Waiver recorded. Re-run the publish gate to see the component pass:"
echo "  kosli assert artifact --fingerprint ${FINGERPRINT} --policy publish-gate --flow ${FLOW}"
