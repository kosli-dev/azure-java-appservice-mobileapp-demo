#!/usr/bin/env bash
#
# One-time (idempotent) setup of the org-level Kosli objects this demo needs:
#   * three custom attestation types, each carrying the jq rules that DECIDE compliance
#   * the publish-gate policy that `kosli assert artifact` enforces in CI
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

echo "==> publish-gate policy"
kosli create policy publish-gate kosli/policies/publish-gate.yml \
  --type env \
  --description "Controls a component must satisfy before it may be published" \
  --comment "bootstrap from $(git rev-parse --short HEAD 2>/dev/null || echo local)"

echo
echo "Done. Verify with:"
echo "  kosli list attestation-types"
echo "  kosli get policy publish-gate"
