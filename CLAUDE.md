# Working notes for this repo

Context for anyone (human or agent) picking this up. The README is the demo run-book; this
file is the reasoning behind it, plus what is and is not verified.

## What this is

A Kosli demo built for a customer evaluation. It covers **point 1** of their scenario: a Java
component deployed to Azure App Service whose peer review, SonarQube quality gate, unit tests
and mutation testing are all attested to Kosli, and whose right to be published is decided by
a Kosli policy rather than by a green pipeline.

Kosli org: `kosli-public`. Flow: `orders-api-ci`. Artifact name: `orders-api`.

## State

Pushed and verified as landed. **Not yet run live** — that needs the `KOSLI_PUBLIC_API_TOKEN` secret
and the Azure setup. Nothing in here has talked to app.kosli.com yet.

Verified before pushing:

- `mvn verify` green; PIT scores **76.5%** (13/17 mutants killed) against the default 85%
  threshold, so the mutation control fails by design.
- Every Kosli command dry-run against CLI **v2.38.0**.
- `kosli/policies/*.yml` validated against `https://docs.kosli.com/schemas/policy/v1.json`.
- `kosli/flow-template.yml` validated against the `Template` model in Kosli's OpenAPI spec.
- `actionlint` (with shellcheck), `shellcheck`, and `bicep build` all clean.

Not verified, and the first live run is the test of it:

- Whether the `artifacts.attestations[].name` entries in `publish-gate.yml` match on the
  short template name (`peer-review`) rather than the dotted CLI form
  (`orders-api.peer-review`). Evidence says short — `kosli attest junit --help` documents
  `--name yourTemplateArtifactName.yourAttestationName`, i.e. the dotted form is addressing,
  not the stored name. If it mismatches, the gate fails for the wrong reason; the fix is to
  drop the `attestations:` list and lean on `trail-compliance: required: true`, which
  enforces the whole flow template anyway.
- Whether the custom attestation type names collide with existing types in `kosli-public`.
  Run `kosli list attestation-types` before the first bootstrap — re-running it would version
  an existing type rather than create a new one.
- `actions/upload-artifact@v7` + `actions/download-artifact@v7`. Matched majors on purpose;
  upload's latest is v7 while download's is v8, so v7/v7 is the coherent pair.

## Design decisions worth not re-litigating

**Peer review is a custom attestation type, not just `pull_request`.** The native
`pull_request` attestation is compliant as soon as a PR exists — it records approvers but
cannot require them. So the pipeline makes both: `pull-request` (trail level) for the raw
evidence, and `orders-api.peer-review` (custom) carrying the facts, with the rule living on
the type: `(.distinct_approvers >= 2) or (.independent_approval == true)`. That mirrors the
"never alone" control in https://github.com/kosli-dev/control-actions.

**The gate is `kosli assert artifact --policy`, not `kosli evaluate trail` with rego.**
`kosli evaluate` is a beta feature that has to be enabled per org — not something to bet a
customer demo on. `--policy` takes an `env`-type policy and asserts an artifact against it
directly, with no environment involved. The README explains the rego route for rules the
policy YAML can't express.

**Scripts report facts; Kosli decides compliance.** None of the Python scripts return a
pass/fail. They emit JSON, and the jq rules on the attestation types do the judging. Keep it
that way — it is the whole point of the demo, and it means the rule changes in one place for
every component that uses the type.

**Mutation testing does not fail the Maven build** (`failWhenNoMutations=false`, no score
threshold in the POM). The threshold lives in the attestation data and is enforced by Kosli.
A threshold in a build file is one a developer can quietly edit.

**The artifact is fingerprinted as a directory, not a file.** `kosli attest artifact deploy
--artifact-type dir` where `deploy/` holds `app.jar`. Reason: `kosli snapshot azure`
fingerprints zip-deployed web apps as the *extracted wwwroot contents* — the equivalent of
`kosli fingerprint -t dir` — so fingerprinting the directory is what will let the environment
snapshot match the built artifact when point 4 gets built. This is also why
`WEBSITE_RUN_FROM_PACKAGE` is pinned to `0` in `infra/main.bicep`.

**Flow template: `artifacts` is nested under `trail`.** The docs page shows it at top level;
Kosli's own API model (`TemplateTrailDefinition.artifacts`, `additionalProperties: false`)
says otherwise, and `kosli-dev/demo-app` does it the nested way. Validated against the model.

**A waiver is the override endpoint.** `POST /api/v2/attestations/{org}/{flow}/trail/{trail}/override`
with `reason` and `new_compliance_status` — there is no `kosli waive` command. Note the
`attestation_name` field rejects dots (`^[a-zA-Z0-9\-_,]+$`), so the artifact is identified
separately via `target_artifacts` + `artifact_fingerprint`. See `scripts/waive_attestation.sh`.

**The Sonar report is canned**, at the customer's request, in the shape of SonarQube's
`api/qualitygates/project_status` response. `kosli attest sonar` needs a live Sonar server —
switching to it later means changing the flow template and policy from
`custom:sonarqube-quality-gate` to the built-in `sonar` type, and swapping one pipeline step.

## Gotchas

- **The first real run needs an approved PR.** Peer review reads the PR behind the merge
  commit, so a direct push to `main` blocks on two controls instead of the one the demo story
  is about.
- `kosli attest artifact` requires `--build-url` and `--commit-url`. They are defaulted from
  CI env vars inside GitHub Actions, so this only bites when running the command locally.
- `scripts/*` must be mode `100755` (`git ls-files -s scripts/`). The repo was landed via a
  tarball, so if the exec bit was lost, `./scripts/bootstrap_kosli.sh` fails in the bootstrap
  workflow. `git update-index --chmod=+x` fixes it.
- Attestation types and policies are **org-level** objects in `kosli-public`, created by the
  `Bootstrap Kosli` workflow. They are not scoped to this repo.

## Setup

Secret `KOSLI_PUBLIC_API_TOKEN`; then run the **Bootstrap Kosli** workflow. Azure:
`infra/deploy.sh` then `infra/setup-github-oidc.sh`, which prints the three `AZURE_*` secrets;
set vars `AZURE_WEBAPP_NAME` and `AZURE_RESOURCE_GROUP`. Optional vars `MUTATION_THRESHOLD`,
`SONAR_RESULT`, `KOSLI_DRY_RUN`, `REPORT_AZURE_ENV` tune the demo without code changes —
`MUTATION_THRESHOLD=70` gives a clean run with no waiver needed.

## Still to build (points 2-4 of the customer scenario)

- **Point 2** — mobile component: a second flow with an Oversecured report imported as a
  custom attestation type. Same pattern as the Sonar import here.
- **Point 3** — integration tests: a third flow whose trail references both artifacts by
  fingerprint, attesting the combined run as `junit` and failing on purpose.
- **Point 4** — deployment gate: `kosli/policies/prod-deploy-gate.yml` exists but is not
  attached. Enable `REPORT_AZURE_ENV`, run the bootstrap with *create environment* checked,
  and the policy starts judging what is actually running in App Service. Note `kosli snapshot
  azure` needs a service-principal **client secret**, not the OIDC login the deploy job uses.
