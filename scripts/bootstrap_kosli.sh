#!/usr/bin/env bash
#
# One-time (idempotent) setup of the org-level Kosli objects this demo needs:
#   * six custom attestation types, each carrying the jq rules that DECIDE compliance
#   * the publish-gate policy that `kosli assert artifact` enforces in CI
#   * the release-gate policy the release workflow enforces after the manual approval
#
# Re-running it creates a new version of anything whose content changed, so it is safe to
# run again after editing a schema, a rule or the policy.
#
# Requires: kosli CLI, KOSLI_API_TOKEN, KOSLI_ORG.
set -euo pipefail

: "${KOSLI_ORG:?set KOSLI_ORG}"
: "${KOSLI_API_TOKEN:?set KOSLI_API_TOKEN}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> peer-review attestation type"
# The control: a change is peer reviewed if two different people approved it, OR if at least
# one approver contributed no commits to the branch (Kosli's "never alone" review control).
kosli create attestation-type peer-review \
  --description "Peer review of the pull request behind a commit: two distinct approvers, or one approver who did not write the code." \
  --schema kosli/attestation-types/peer-review.schema.json \
  --jq '.pull_request_url != null' \
  --jq '(.distinct_approvers >= 2) or (.independent_approval == true)' \
  --summary "Pull request=.pull_request_url" \
  --summary "Author=.author" \
  --summary "Approvers=.distinct_approvers" \
  --summary "Independent approval=.independent_approval"

echo "==> sonarqube-quality-gate attestation type"
kosli create attestation-type sonarqube-quality-gate \
  --description "SonarQube quality gate result for a component: the gate must pass with no failing conditions." \
  --schema kosli/attestation-types/sonarqube-quality-gate.schema.json \
  --jq '.projectStatus.status == "OK"' \
  --jq '[.projectStatus.conditions[] | select(.status != "OK")] | length == 0' \
  --summary "Quality gate=.projectStatus.status" \
  --summary "Coverage=.measures.coverage" \
  --summary "Bugs=.measures.bugs" \
  --summary "Vulnerabilities=.measures.vulnerabilities" \
  --summary "Project=.project.key"

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

echo "==> mobile-sast attestation type"
# A SARIF result's `level` is optional; when absent the effective level is the rule's
# defaultConfiguration, then the spec default of "warning". mobsfscan omits it often, so
# testing `.level == "error"` alone silently ignores those findings.
# shellcheck disable=SC2016  # $rules is jq's, not the shell's; it must not expand.
NO_ERROR_FINDINGS='[.runs[] | .tool.driver.rules as $rules | .results[] | (.level // $rules[.ruleIndex].defaultConfiguration.level // "warning")] | any(. == "error") | not'
kosli create attestation-type mobile-sast \
  --description "Mobile SAST scan in SARIF 2.1.0 format. Compliant when the scan reports no error-level findings." \
  --jq "${NO_ERROR_FINDINGS}" \
  --jq '.version == "2.1.0"' \
  --jq '.runs[0].tool.driver.name == "mobsfscan"'

echo "==> integration-test attestation type"
# The control: the integration run across the components has to have executed and to have
# come out clean. `errors` counts harness failures - a run that fell over tells you nothing
# about the release, so it is not a pass either.
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
# Who pressed "Approve" on a job waiting on a protected environment, read back from the
# run's approvals API. github.actor is the person who triggered the run - for a tagged
# release, whoever pushed the tag - so the approver has to come from the API.
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

echo "==> publish-gate policy"
kosli create policy publish-gate kosli/policies/publish-gate.yml \
  --type env \
  --description "Controls a component must satisfy before it may be published" \
  --comment "bootstrap from $(git rev-parse --short HEAD 2>/dev/null || echo local)"

echo "==> release-gate policy"
kosli create policy release-gate kosli/policies/release-gate.yml \
  --type env \
  --description "Controls a release of the order system must satisfy before it goes out" \
  --comment "bootstrap from $(git rev-parse --short HEAD 2>/dev/null || echo local)"

echo
echo "Done. Verify with:"
echo "  kosli list attestation-types"
echo "  kosli get policy publish-gate"
echo "  kosli get policy release-gate"
