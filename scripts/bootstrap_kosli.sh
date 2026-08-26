#!/usr/bin/env bash
#
# One-time (idempotent) setup of the org-level Kosli objects this demo needs:
#   * five custom attestation types - four carrying the jq rules that DECIDE compliance
#     directly, and cyclonedx-sbom, which carries none and is evidence only
#   * the peer-review control, judged by a Rego policy against local evidence rather than a type
#
# The environment policies (secure-development, production-readiness) are created and attached
# by the Bootstrap Kosli workflow instead, since they belong with the environments they judge.
# Nothing else creates policies: the release gate asserts the production environment's own.
#
# Re-running it creates a new version of anything whose content changed, so it is safe to
# run again after editing a schema or a rule.
#
# Requires: kosli CLI, KOSLI_API_TOKEN, KOSLI_ORG.
set -euo pipefail

: "${KOSLI_ORG:?set KOSLI_ORG}"
: "${KOSLI_API_TOKEN:?set KOSLI_API_TOKEN}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> peer-review control"
# The judgment that used to live in the peer-review type's jq rules: a change is peer
# reviewed if two different people approved it, OR if at least one approver contributed no
# commits to the branch (Kosli's "never alone" review control). Evaluated by
# kosli/policies/peer-review.rego and recorded with `kosli attest decision --control
# peer-review` in ci-build.yml.
# `kosli create control` errors if the control exists, unlike create attestation-type and
# create policy, which version instead - so re-running this script needs the update path.
CONTROL_DESCRIPTION="The pull request behind a commit was approved by two distinct people, or by one approver who did not write the code."
if kosli get control peer-review >/dev/null 2>&1; then
  kosli update control peer-review \
    --name "Peer review" \
    --description "$CONTROL_DESCRIPTION"
else
  kosli create control peer-review \
    --name "Peer review" \
    --description "$CONTROL_DESCRIPTION"
fi

echo "==> mutation-testing attestation type"
kosli create attestation-type mutation-testing \
  --description "Mutation testing (PIT) results for a component: the mutation score must reach the threshold carried in the report." \
  --schema kosli/attestation-types/mutation-testing.schema.json \
  --jq '.total_mutations > 0' \
  --jq '.mutation_score >= .threshold' \
  --summary "Mutation score=.mutation_score" \
  --summary "Threshold=.threshold" \
  --summary "Killed=.killed" \
  --summary "Survived=.survived" \
  --summary "Not covered=.no_coverage"

echo "==> cyclonedx-sbom attestation type"
# No --jq: an SBOM is evidence, not a control. Nothing here decides compliance, so this type
# always reports compliant - see the design decision in CLAUDE.md.
kosli create attestation-type cyclonedx-sbom \
  --description "CycloneDX SBOM for a built artifact (jar or mobile app package). Evidence only - no evaluation rules." \
  --schema kosli/attestation-types/cyclonedx-sbom.schema.json \
  --summary "Format=.bomFormat" \
  --summary "Spec version=.specVersion" \
  --summary "Components=.components | length"

echo "==> oversecured attestation type"
# The report's severityCounts is what the second rule reads; the third reads the findings the
# script derives from the same report, so a header that disagrees with its own findings cannot
# pass. Oversecured omits a severity from severityCounts when its count is zero, hence // 0.
kosli create attestation-type oversecured \
  --description "Oversecured mobile application security scan. Compliant when the scan completed and found no high or critical severity issues." \
  --jq '.header.scan.status == "completed"' \
  --jq '(.header.severityCounts.critical // 0) == 0 and (.header.severityCounts.high // 0) == 0' \
  --jq '[.findings[] | select(.false_positive == false) | .severity] | any(. == "high" or . == "critical") | not' \
  --summary "App=.header.app.name" \
  --summary "Platform=.header.app.platform" \
  --summary "Findings=.header.scan.vulnerabilityCount" \
  --summary "High=.header.severityCounts.high" \
  --summary "Medium=.header.severityCounts.medium" \
  --summary "Low=.header.severityCounts.low" \
  --summary "Scan=.header.scan.id"

echo "==> integration-test attestation type"
# `errors` counts harness failures - a run that fell over is not a pass either.
kosli create attestation-type integration-test \
  --description "Integration test run across the components of a release: the run must have executed and reported no failures and no errors." \
  --schema kosli/attestation-types/integration-test.schema.json \
  --jq '.total > 0' \
  --jq '.failed == 0' \
  --jq '.errors == 0' \
  --summary "Suite=.suite" \
  --summary "Release=.release" \
  --summary "Total=.total" \
  --summary "Passed=.passed" \
  --summary "Failed=.failed" \
  --summary "Errors=.errors"

echo "==> approval-github-workflow attestation type"
# One entry from a run's approvals API, as .github/actions/get-github-workflow-approver
# writes it.
kosli create attestation-type approval-github-workflow \
  --description "Approval of a GitHub Actions job waiting on a protected environment: who approved it, for which environment." \
  --schema kosli/attestation-types/approval-github-workflow.schema.json \
  --jq '.state == "approved"' \
  --jq '.user.login != ""' \
  --summary "Approver=.user.login" \
  --summary "State=.state" \
  --summary "Environment=.environments[0].name" \
  --summary "Approved at=.environments[0].updated_at" \
  --summary "Comment=.comment"

echo
echo "Done. Verify with:"
echo "  kosli list attestation-types"
echo "  kosli list controls"
