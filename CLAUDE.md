# Working notes for this repo

Context for anyone (human or agent) picking this up. The README is the demo run-book; this
file is the reasoning behind it, plus what is and is not verified.

## What this is

A Kosli demo built for a customer evaluation. It covers **points 1 and 2** of their scenario:

- **Point 1** — a Java component deployed to Azure App Service whose peer review, SonarQube
  quality gate, unit tests and mutation testing are all attested to Kosli, and whose right to
  be published is decided by a Kosli policy rather than by a green pipeline.
- **Point 2** — the Mobile Orders mobile component (Android + iOS), scanned from source with
  mobsfscan, the SARIF report attested as a custom type whose jq rules are the gate. Merged in
  from the `mobile-app-example` repo; it was developed there and its git history lives there.

Kosli org: `kosli-public` for both.

| Component | Flow | Artifacts | Template |
| --- | --- | --- | --- |
| Java backend | `orders-api-ci` | `orders-api` | `kosli/flow-templates/orders-api-ci.yml` |
| Mobile app | `mobileorders` | `mobileorders-android`, `mobileorders-ios` | `kosli/flow-templates/mobileorders.yml` |

## State

Pushed and verified as landed. **Not yet run live** — that needs the `KOSLI_PUBLIC_API_TOKEN` secret
and the Azure setup. Nothing in here has talked to app.kosli.com yet.

Verified before pushing:

- `mvn verify` green; PIT scores **76.5%** (13/17 mutants killed) against the default 85%
  threshold, so the mutation control fails by design.
- Every Kosli command dry-run against CLI **v2.38.0**.
- `kosli/policies/*.yml` validated against `https://docs.kosli.com/schemas/policy/v1.json`.
- `kosli/flow-templates/orders-api-ci.yml` validated against the `Template` model in Kosli's
  OpenAPI spec.
- `actionlint` (with shellcheck), `shellcheck`, and `bicep build` all clean.

For the mobile half, verified in the `mobile-app-example` repo before the merge: mobsfscan
runs clean on both platforms (Android tuned to no error-level findings, iOS all `note`), and
the flow, type and gate ran green in Actions. What the merge itself changed — the flow-template
paths, the folded-in `mobile-sast` bootstrap, the `create flow` step moving into
`mobileorders.yml`, the CLI pin — has not been run.

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

**One mobile flow, two artifacts, not two flows.** `mobileorders-android` and `mobileorders-ios`
are artifacts of the same flow, so a trail is compliant only once both have been attested. Two
path-filtered per-platform workflows would leave trails permanently missing an artifact. Hence
one workflow with a platform matrix, and `begin trail` in its own job so the legs cannot race
creating the trail.

**`mobile-sast`'s severity rule reads the effective SARIF level, not `.level`.** A result's
`level` is optional; when absent the level comes from the rule's `defaultConfiguration`, then
the spec default of `warning`. mobsfscan omits it often, so `.level == "error"` alone silently
ignores those findings. The rule in `scripts/bootstrap_kosli.sh` walks the fallback chain.

**`mobileorders` is gated by `kosli assert artifact` with no `--policy`.** The `publish-gate`
policy spells out the orders-api controls (`peer-review`, `unit-tests`, …), so applying it to a
mobile artifact would demand attestations that component never makes. Flow-template compliance
is the gate there. A shared policy would mean either a mobile-specific policy or dropping
`attestations:` from `publish-gate` in favour of `trail-compliance` alone.

**`mobile-sast` has jq rules but no JSON Schema**, unlike the three orders-api types. Nothing
principled — SARIF's schema is large and the jq rules already pin `version` and the tool name.

**The Makefile owns building/scanning; the workflows own everything that talks to Kosli.**
So `make scan` and `make package` need no API token and run locally in Docker, and the gate
only ever runs in Actions. Keep that line: it is why the mobile half needs no toolchain
installed.

## Gotchas

- **The Kosli CLI only reads the token from an env var literally named `KOSLI_API_TOKEN`**
  (it derives the name from the `--api-token` flag). The GitHub secret is named
  `KOSLI_PUBLIC_API_TOKEN` for clarity about which org it's for, so every workflow that shells
  out to `kosli` maps it in the job `env:` as `KOSLI_API_TOKEN: ${{ secrets.KOSLI_PUBLIC_API_TOKEN }}`.
  Renaming that env var key (not just the secret) breaks the CLI with
  `--api-token is not set`, which is what happened the first time this was tried.
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
- **Neither mobile app compiles, and nothing checks that they do.** No Gradle build, no Xcode
  project; `androidx.appcompat` is an unresolved import. mobsfscan is pattern-based and does
  not care. The artifacts are zips of the source, so the fingerprint-and-gate half is real.
- **`minSdkVersion=30` and `<uses-sdk>` in the Android manifest are scanner-driven**, not app
  requirements — mobsfscan raises error-level findings without them. Same for the empty
  `NSAppTransportSecurity` dict: ATS defaults are secure, `NSAllowsArbitraryLoads` is what
  trips the scanner.
- **The mobile gate has no failing case.** Both platforms scan clean, so it always passes.
  Showing it block needs a commit that introduces a weakness.
- **Nothing validates the jq rules automatically.** All three `mobile-sast` rules were run
  with `jq` against real `make scan` output at merge time and returned `true`; there is no
  check that keeps them honest, so a later edit's breakage is first seen in a workflow run.

## Setup

Secret `KOSLI_PUBLIC_API_TOKEN` (the workflows map it onto `KOSLI_API_TOKEN` in the job env,
since that's the only env var name the Kosli CLI itself recognizes for `--api-token`); then
run the **Bootstrap Kosli** workflow. Azure:
`infra/deploy.sh` then `infra/setup-github-oidc.sh`, which prints the three `AZURE_*` secrets;
set vars `AZURE_WEBAPP_NAME` and `AZURE_RESOURCE_GROUP`. Optional vars `MUTATION_THRESHOLD`,
`SONAR_RESULT`, `KOSLI_DRY_RUN`, `REPORT_AZURE_ENV` tune the demo without code changes —
`MUTATION_THRESHOLD=70` gives a clean run with no waiver needed.

## Still to build (points 3-4 of the customer scenario)

- **Real mobile builds** — `make apk` in a container replacing the Android zip, then
  `make ipa` on a macOS runner. Xcode cannot be containerised, so unlike `scan` and `apk` it
  will not run on Linux.
- **Point 3** — integration tests: a third flow whose trail references the Java and mobile
  artifacts by fingerprint, attesting the combined run as `junit` and failing on purpose.
- **Point 4** — deployment gate: `kosli/policies/prod-deploy-gate.yml` exists but is not
  attached. Enable `REPORT_AZURE_ENV`, run the bootstrap with *create environment* checked,
  and the policy starts judging what is actually running in App Service. Note `kosli snapshot
  azure` needs a service-principal **client secret**, not the OIDC login the deploy job uses.
