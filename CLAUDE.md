# Working notes for this repo

Context for anyone (human or agent) picking this up. The README is the demo run-book; this
file is the reasoning behind it, plus what is and is not verified.

## What this is

A Kosli demo built for a customer evaluation. It covers **points 1, 2 and 3** of their scenario:

- **Point 1** — a Java component deployed to Azure App Service whose peer review, SonarQube
  quality gate, unit tests and mutation testing are all attested to Kosli, and whose right to
  be published is decided by a Kosli policy rather than by a green pipeline.
- **Point 2** — the Mobile Orders mobile component (Android + iOS), scanned from source with
  mobsfscan, the SARIF report attested as a custom type whose jq rules are the gate. Merged in
  from the `mobile-app-example` repo; it was developed there and its git history lives there.
- **Point 3** — a release process. An integration test run is reported to the trail by a
  separate manual workflow (pass or fail, from canned JSON), and a protected GitHub
  environment halts the pipeline until someone approves — after which Kosli, not the
  approver, decides. Only once the release gate opens is the build deployed to App Service.

Kosli org: `kosli-public`.

**One pipeline, one flow** (customer's call, 2026-08-24). `ci-cd.yml` and `mobileorders.yml`
are gone and `release.yml` became `ci-build.yml`, triggered by a push to `main` rather than a
tag. Everything the three workflows attested now lands on one flow, `order-system-ci`, whose
trail is the commit:

| Artifact | Attestations |
| --- | --- |
| `orders-api` | `peer-review`, `unit-tests`, `sonar-quality-gate`, `mutation-tests` |
| `mobileorders-android` | `mobile-sast` |
| `mobileorders-ios` | `mobile-sast` |
| (trail level) | `pull-request`, `integration-tests`, `release-approval` |

Template: `kosli/flow-templates/order-system-ci.yml`. The `orders-api-ci`, `mobileorders` and
`order-system-release` flows still exist in `kosli-public` with their history; nothing writes
to them any more.

## State

Pushed and verified as landed. **Not yet run live** — that needs the `KOSLI_PUBLIC_API_TOKEN` secret
and the Azure setup. Nothing in here has talked to app.kosli.com yet.

Verified before pushing:

- `mvn verify` green; PIT scores **76.5%** (13/17 mutants killed) against the default 85%
  threshold, so the mutation control fails by design.
- Every Kosli command dry-run against CLI **v2.38.0**.
- `kosli/policies/*.yml` validated against `https://docs.kosli.com/schemas/policy/v1.json`.
- `kosli/flow-templates/*.yml` validated against the `Template` model in Kosli's OpenAPI spec.
- `actionlint` (with shellcheck), `shellcheck`, and `bicep build` all clean.

For the mobile half, verified in the `mobile-app-example` repo before the merge: mobsfscan
runs clean on both platforms (Android tuned to no error-level findings, iOS all `note`), and
the flow, type and gate ran green in Actions. Since the collapse into one pipeline, the mobile
steps live in `ci-build.yml` and `make scan` was re-run locally against both platforms with
all three `mobile-sast` rules returning true.

For the release half (point 3), verified locally: the new flow template and
`kosli/policies/release-gate.yml` validate against the published schemas; every new Kosli
command dry-runs clean on **v2.38.0** (including `bootstrap_kosli.sh` end to end);
`make package` produces both mobile zips; the three `integration-test` jq rules were run with
`jq` against both canned reports and return the expected verdicts (pass: all true, fail:
`.failed == 0` and `.errors == 0` false). Nothing about it has run in Actions.

Not verified, and the first live run is the test of it:

- Whether the `artifacts.attestations[].name` entries in `publish-gate.yml` match on the
  short template name (`peer-review`) rather than the dotted CLI form
  (`orders-api.peer-review`). Evidence says short — `kosli attest junit --help` documents
  `--name yourTemplateArtifactName.yourAttestationName`, i.e. the dotted form is addressing,
  not the stored name. This is now load-bearing: `publish-gate.yml` has no
  `trail-compliance` any more (it runs before the release controls exist), so that list is the
  entire policy. If it mismatches, the publish gate fails for the wrong reason on every run.
- Whether the custom attestation type names collide with existing types in `kosli-public`.
  Run `kosli list attestation-types` before the first bootstrap — re-running it would version
  an existing type rather than create a new one.
- Whether `kosli assert artifact --policy release-gate` really fails when the *trail-level*
  `integration-tests` attestation is missing or non-compliant. The policy leans entirely on
  `trail-compliance: required: true` for that (see the decision below), so if artifact
  compliance turns out not to include trail compliance, the gate passes when it should not —
  which is the one failure mode that would be invisible in the demo. Check the first blocked
  release actually blocks.
- `actions/upload-artifact@v7` + `actions/download-artifact@v7`. Matched majors on purpose;
  upload's latest is v7 while download's is v8, so v7/v7 is the coherent pair.
- The SonarCloud webhook path, end to end: whether `SonarSource/sonarqube-scan-action@v5`
  passes `-Dsonar.analysis.kosli_*` args through to the scanner unmodified, whether the
  webhook actually fires with enough payload for Kosli to resolve `order-system-ci`'s trail and
  the `orders-api` artifact by fingerprint, and whether `sonar-project.properties`'
  `kosli-dev` / `kosli-dev_azure-java-appservice-demo` org/project-key guesses are the real
  ones (fix them there if not — nothing else hardcodes them). Also whether SonarCloud's
  Automatic Analysis is off for the project; left on, it fights the CI-driven analysis for the
  same commit and won't carry the `kosli_*` properties. None of this has been dry-run in any
  way, unlike almost everything else in this file — a webhook can't be dry-run locally.

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

**The Sonar quality gate is attested by SonarCloud itself, via webhook — not by CI calling
`kosli attest`.** Kosli's Sonar integration (org-level, enabled once in the Kosli app) gives a
webhook URL/secret that goes on the SonarCloud project; the scan then attests straight to
Kosli when analysis finishes, using `sonar.analysis.kosli_flow` / `kosli_trail` /
`kosli_attestation` / `kosli_git_commit` / `kosli_artifact_fingerprint` scanner properties set
in `.github/workflows/ci-build.yml` to address the right trail and artifact. The alternative was
`kosli attest sonar --sonar-api-token ... --sonar-working-dir .scannerwork` (CLI polls the
Sonar API after the scan); webhook was chosen because it needed no Sonar API token stored
alongside `KOSLI_API_TOKEN`, and it is the integration path Kosli's own docs lead with. Either
way the flow template and policies use the built-in `sonar` attestation type, not a custom
one — `custom:sonarqube-quality-gate` (and its schema, its bootstrap block, and the canned
`sonar/quality-gate-{pass,fail}.json` fixtures) were removed rather than kept alongside it.

**Both mobile apps are artifacts of the system flow, not of a flow of their own.** A trail is
compliant only once both have been packaged, scanned and found clean, so a commit cannot be
released with one platform missing. They are built and scanned in the same job as the backend,
which is also why there is no matrix and no separate `begin trail` job any more: nothing can
race a single sequential job.

**`mobile-sast`'s severity rule reads the effective SARIF level, not `.level`.** A result's
`level` is optional; when absent the level comes from the rule's `defaultConfiguration`, then
the spec default of `warning`. mobsfscan omits it often, so `.level == "error"` alone silently
ignores those findings. The rule in `scripts/bootstrap_kosli.sh` walks the fallback chain.

**Two gates, and they are deliberately asymmetric.** `publish-gate` judges the backend's own
controls and carries **no** `trail-compliance`, because it runs mid-pipeline, before the
integration test run and the approval exist — requiring the whole trail there would block every
run. `release-gate` is the mirror image: no `attestations:` list, because
`trail-compliance: required: true` already requires every control in `order-system-ci.yml`,
including both mobile scans. There is no mobile-specific gate: the mobile apps are covered by
trail compliance at the release gate. Do not "tidy" either policy into looking like the other.

**`mobile-sast` has jq rules but no JSON Schema**, unlike the three orders-api types. Nothing
principled — SARIF's schema is large and the jq rules already pin `version` and the tool name.

**Deploy is the last job, and the release gate is the only way to reach it.** The deploy job
downloads the artifact the gates approved rather than rebuilding, so the fingerprint that
reaches App Service is the one Kosli judged. Nothing else in the repo deploys.

**There is no GitHub release object** (customer's call, 2026-08-24). `gh release create` needs
a tag and the pipeline is triggered by a push to `main`, so publishing a release would have
meant inventing a tag per build. Kosli holds the record of what was approved; GitHub holds
none. If tags come back, the release job comes with them.

**The approver is read from the approvals API, not from `github.actor`.** `github.actor` is
whoever merged the pull request, which is exactly the person the approval is supposed to be
independent of. `.github/actions/get-github-workflow-approver` calls
`GET /repos/{repo}/actions/runs/{run_id}/approvals` and picks the entry for the
`production-release` environment; the gate job attests it as `release-approval`. Ported from
`kosli-dev/github-release-example`, which does the same thing against a `Production`
environment and attests it against an artifact fingerprint — here it is trail-level, like
`integration-tests`, because the approval is about the release rather than one binary.
The job needs `permissions: actions: read` for that API.

**The approval is attested before the policy assert, in the same job.** The flow template
requires `release-approval`, and the policy requires the trail to be compliant, so the order
matters. It also means the action fails the job outright if the environment has no required
reviewers: there is no approval entry to read, which is the correct outcome — an unprotected
environment cannot produce evidence of a human decision.

**The release gate runs after the approval, not before it.** The `release-gate` job sits on
the protected `production-release` environment, so approving it only lets the job *start*;
the job then runs `kosli assert artifact --policy release-gate`. That ordering is the whole
point of point 3 — a human can start the gate, a human cannot talk it into passing. Putting
the assert in the build job instead would make the approval the decision.

**`integration-tests` and `release-approval` are trail-level attestations.** They are about
the release — the combination of the components, and the decision to ship them — not about any
one binary, so they hang off the trail.

**Everything is built once, in one job.** The backend JAR and both mobile zips come from the
same checkout, are fingerprinted there, and every attestation binds to those fingerprints. No
rebuild happens later, so there is no question of the gated fingerprint differing from the
deployed one. Cost is ~30s of mobsfscan per platform on top of the Maven build.

**The integration test workflow always succeeds, whichever variant you pick.** Same rule as
everywhere else here: scripts report facts, Kosli decides. `fail` is the default input so the
demo's first pass through the gate shows it blocking.

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
- **The `production-release` environment needs required reviewers set in the GitHub UI.**
  Nothing in the repo can do that. Without them the pipeline runs straight through, there is
  no halt, and the release gate fails anyway: `get-github-workflow-approver` finds no approval
  entry to attest.
- **`KOSLI_DRY_RUN=true` makes the release gate pass no matter what** — `kosli assert` exits 0
  in dry-run mode. Same for the publish gate. Fine for rehearsing the pipeline, useless for
  rehearsing the gate.
- **Re-running the release gate job re-attests the same approver.** The approvals API returns the
  run's approvals, and a re-run does not create a new one, so a blocked release that is
  re-reported and re-run records the original approval again. Fine here; worth knowing before
  anyone reads the trail as "approved twice".
- **The deploy job uses the `production` environment, the release gate uses
  `production-release`.** Two environments on purpose: the halt belongs to the gate, and
  `production` carries the deployment URL that shows up in the Actions UI.
- **The trail is the commit SHA**, which the manually-run integration test workflow takes as
  its `commit` input. One trail per push to `main`, so a re-run of a build reuses its trail
  and its attestations.
- **Neither mobile app compiles, and nothing checks that they do.** No Gradle build, no Xcode
  project; `androidx.appcompat` is an unresolved import. mobsfscan is pattern-based and does
  not care. The artifacts are zips of the source, so the fingerprint-and-gate half is real.
- **`minSdkVersion=30` and `<uses-sdk>` in the Android manifest are scanner-driven**, not app
  requirements — mobsfscan raises error-level findings without them. Same for the empty
  `NSAppTransportSecurity` dict: ATS defaults are secure, `NSAllowsArbitraryLoads` is what
  trips the scanner.
- **The mobile scans have no failing case.** Both platforms scan clean, so `mobile-sast` never
  blocks. Showing it block needs a commit that introduces a weakness.
- **Nothing validates the jq rules automatically.** All three `mobile-sast` rules were run
  with `jq` against real `make scan` output at merge time and returned `true`; there is no
  check that keeps them honest, so a later edit's breakage is first seen in a workflow run.

## Setup

Secret `KOSLI_PUBLIC_API_TOKEN` (the workflows map it onto `KOSLI_API_TOKEN` in the job env,
since that's the only env var name the Kosli CLI itself recognizes for `--api-token`); then
run the **Bootstrap Kosli** workflow (re-run it after any change under `kosli/`: it creates
the five custom types and both policies). Enable the Sonar integration in the
Kosli app (org-level) and put its webhook URL/secret on the SonarCloud project; secret
`SONAR_TOKEN` for the scan step, and turn off SonarCloud's Automatic Analysis for the project.
Add required reviewers to the `production-release` GitHub environment, or the release never
halts. Azure: `infra/deploy.sh` then `infra/setup-github-oidc.sh`, which prints the three
`AZURE_*` secrets; set vars `AZURE_WEBAPP_NAME` and `AZURE_RESOURCE_GROUP`. Optional vars
`MUTATION_THRESHOLD`, `KOSLI_DRY_RUN`, `REPORT_AZURE_ENV` tune the demo without code changes —
`MUTATION_THRESHOLD=70` gives a clean run with no waiver needed.

## Still to build (point 4 of the customer scenario)

- **Real mobile builds** — `make apk` in a container replacing the Android zip, then
  `make ipa` on a macOS runner. Xcode cannot be containerised, so unlike `scan` and `apk` it
  will not run on Linux.
- **A real integration suite** — the pipeline reports one of two canned runs under
  `integration-tests/`. A suite that actually drives the deployed backend from the mobile
  clients replaces one workflow step; the type, the template and the gate stay as they are.
- **Point 4** — deployment gate: `kosli/policies/prod-deploy-gate.yml` exists but is not
  attached. Enable `REPORT_AZURE_ENV`, run the bootstrap with *create environment* checked,
  and the policy starts judging what is actually running in App Service. Note `kosli snapshot
  azure` needs a service-principal **client secret**, not the OIDC login the deploy job uses.
