# Working notes for this repo

Context for anyone (human or agent) picking this up. The README is the demo run-book; this
file is the reasoning behind it, plus what is and is not verified.

## What this is

A Kosli demo built for a customer evaluation. It covers **points 1, 2 and 3** of their scenario:

- **Point 1** — a Java component deployed to Azure App Service whose peer review, SonarQube
  quality gate, unit tests and mutation testing are all attested to Kosli, and whose right to
  be published is decided by a Kosli policy rather than by a green pipeline.
- **Point 2** — the Mobile Orders mobile component (Android + iOS), scanned by Oversecured,
  the report attested as a custom type whose jq rules are the gate. Merged in from the
  `mobile-app-example` repo; it was developed there and its git history lives there, where it
  used mobsfscan.
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
| `orders-api` | `peer-review-decision`, `unit-tests`, `sonar-quality-gate`, `mutation-tests` |
| `mobileorders-android` | `oversecured` |
| `mobileorders-ios` | `oversecured` |
| (trail level) | `pull-request`, `integration-tests`, `release-approval` |

`orders-api.peer-review` is gone (customer's call, 2026-08-25): it had already been reduced to
evidence only, with no compliance-deciding jq rules, once the judgment moved to a control —
and evidence nobody reads back from Kosli doesn't need to be attested. The facts are still
gathered by `scripts/peer_review_attestation.py` into `peer-review.json`, but that file is now
only ever read locally, by `kosli evaluate input --policy kosli/policies/peer-review.rego` in
the same job. The verdict is recorded as `orders-api.peer-review-decision`, a `decision`-type
attestation against the `peer-review` control. It *is* in the flow template — it's produced in
the same job as the evidence it judges, so nothing stops it being there, and being there means
publish-gate blocks on a bad peer review, same as before.

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
- `kosli/policies/peer-review.rego` passes `opa check` and `opa fmt --diff` (no diff), and
  `kosli evaluate input` against it returns the expected verdict for all four cases: two
  approvers, one independent approver, one dependent approver, no pull request.

For the mobile half, verified locally after the switch to Oversecured: all three
`oversecured` rules return true against the slim data the script emits from
`oversecured/report-pass.json`, and the second and third return false against
`oversecured/report-fail.json`. `make package` still produces
both zips, and `kosli attest custom` dry-runs with each zip's own fingerprint.

For the release half (point 3), verified locally: the new flow template and
`kosli/policies/release-gate.yml` validate against the published schemas; every new Kosli
command dry-runs clean on **v2.38.0** (including `bootstrap_kosli.sh` end to end);
`make package` produces both mobile zips; the three `integration-test` jq rules were run with
`jq` against both canned reports and return the expected verdicts (pass: all true, fail:
`.failed == 0` and `.errors == 0` false). Nothing about it has run in Actions.

Not verified, and the first live run is the test of it:

- **`kosli list controls --org kosli-public` returns "Controls is not enabled for this
  organization".** `kosli create control` and `kosli attest decision` are both BETA and both
  hit org-gated endpoints (`create control` got "Access denied" even before that, which is
  consistent with an invalid token rather than the same enablement check — but `list controls`
  needs no write auth and named the real reason). Kosli has to turn the beta on for
  `kosli-public` before `bootstrap_kosli.sh`'s `peer-review` control and `ci-build.yml`'s
  "Evaluate and record the peer review control decision" step will do anything but fail. This
  does *not* affect `kosli evaluate input`, which is local-only (no API call, no org, no
  beta gate) — only `evaluate trail`/`evaluate trails` hit the org, which is why peer review
  is evaluated from the JSON file directly rather than by re-fetching the trail.
- Whether the `artifacts.attestations[].name` entries in a policy match on the short template
  name (`peer-review`) rather than the dotted CLI form (`orders-api.peer-review`). Evidence
  says short — `kosli attest junit --help` documents
  `--name yourTemplateArtifactName.yourAttestationName`, i.e. the dotted form is addressing,
  not the stored name. It matters for `release-gate.yml`'s three named attestations, which are
  matched with plain names against the artifact's fingerprint. Confirmed the stored name is
  short either way `attest decision` addresses the artifact: a dotted dry run (`--name
  orders-api.peer-review-decision`, no `--fingerprint`) split into `attestation_name:
  "peer-review-decision"` plus `target_artifacts: ["orders-api"]`; a plain dry run (`--name
  peer-review-decision --fingerprint "$KOSLI_FINGERPRINT"`) produced the identical
  `attestation_name` with `artifact_fingerprint` set directly and no `target_artifacts`. Since
  the fingerprint is already known at that point in the `backend` job, `ci-build.yml` uses the
  plain form: prefer `--fingerprint` over the dotted address-by-template-name form whenever
  the fingerprint is already in hand, and reserve the dotted form for attestations made before
  the artifact itself has been reported.
- Whether the custom attestation type names collide with existing types in `kosli-public`.
  Run `kosli list attestation-types` before the first bootstrap — re-running it would version
  an existing type rather than create a new one.
- Whether `kosli assert artifact --policy release-gate` really fails when `integration-tests`
  is missing or non-compliant. Both release controls are now artifact-bound and named in the
  policy, which should make it a straightforward match — but a gate that passes when it should
  block is the one failure mode invisible in the demo. Check the first blocked release blocks.
- `kosli get artifact <flow>:<sha> --output json` returns an array, latest first, one entry
  per build of that commit; the artifact's template name is in `template_reference_name`, not
  `name` (`filename` is the path that was fingerprinted, e.g. `deploy`). The integration test
  workflow filters on it. Verified against the live API - `kosli-public` is a public org, so
  read-only CLI calls against it work with any token value.
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

**The native `pull_request` attestation is not enough on its own for peer review.** It is
compliant as soon as a PR exists — it records approvers but cannot require them. So the
pipeline attests `pull-request` (trail level) for the raw evidence, and separately gathers the
pull-request facts (who approved, whether they wrote the code) that decide whether it counts
as a peer review — see below for how those facts are judged and what happens to them.

**Peer review's judgment moved off an attestation type and onto a control (customer's call,
2026-08-25), and the type itself was dropped shortly after (customer's call, same day).**
`orders-api.peer-review` used to be a custom attestation type carrying the compliance-deciding
jq rule `(.distinct_approvers >= 2) or (.independent_approval == true)` directly, the same as
every other custom type here. That judgment moved to `kosli/policies/peer-review.rego`, run
with `kosli evaluate input --input-file peer-review.json --policy
kosli/policies/peer-review.rego` against the exact same JSON the type used to judge, with the
verdict recorded as a `decision`-type attestation against the `peer-review` control (`kosli
create control peer-review`), via `kosli attest decision --control peer-review
--compliant=<verdict>`, named `peer-review-decision` in
`kosli/flow-templates/order-system-ci.yml`. Once the type carried no jq rules of its own —
evidence nobody read back from Kosli — attesting it stopped earning its keep, so the `kosli
attest custom --type peer-review` call and the `kosli create attestation-type peer-review`
call were both removed; `scripts/peer_review_attestation.py` still writes `peer-review.json`
in the `backend` job, but now purely as local input to the `evaluate input` call in the same
step, and it still travels as an `--attachments` file on the `peer-review-decision`
attestation, so the raw evidence is not lost, just no longer double-attested. Unlike
`integration-tests`/`release-approval`, `peer-review-decision` is produced in the same job as
the evidence it judges, so being in the flow template (and so gating publish-gate, via
`trail-compliance`) is correct, not a timing hazard. This does **not** reopen the earlier
decision to use `kosli assert artifact --policy` over `kosli evaluate trail` for the release
gate itself — that risk (`evaluate` needing per-org beta enablement) is exactly why peer
review is judged with `evaluate input` against a local JSON file rather than `evaluate trail`
against the org's copy of it. `kosli create control` and `kosli attest decision` are
themselves beta and do hit the org, though, and `kosli-public` does not have Controls enabled
yet — see State, above. Mirrors the "never alone" control in
https://github.com/kosli-dev/control-actions, same as before. `publish-gate.yml` and
`prod-deploy-gate.yml` were updated to name `peer-review-decision`/`decision` instead of
`peer-review`/`custom:peer-review`, matching what `release-gate.yml` already did; the now-unused
`kosli/attestation-types/peer-review.schema.json` was deleted.

**The gate is `kosli assert artifact --policy`, not `kosli evaluate trail` with rego.**
`kosli evaluate` is a beta feature that has to be enabled per org — not something to bet a
customer demo on. `--policy` takes an `env`-type policy and asserts an artifact against it
directly, with no environment involved. The README explains the rego route for rules the
policy YAML can't express. (The peer-review control is a narrower, deliberate exception: it
uses `evaluate input`, not `evaluate trail`, specifically to avoid this risk — see above.)

**Scripts report facts; Kosli decides compliance.** None of the Python scripts return a
pass/fail. They emit JSON, and either the jq rules on the attestation type or (for peer
review) a Rego policy evaluated by Kosli's CLI does the judging — never the script itself.
Keep it that way — it is the whole point of the demo, and it means the rule changes in one
place for every component that uses the type or control.

**Mutation testing does not fail the Maven build** (`failWhenNoMutations=false`, no score
threshold in the POM). The threshold lives in the attestation data and is enforced by Kosli.
A threshold in a build file is one a developer can quietly edit.

**The artifact is fingerprinted as a directory, not a file.** `kosli attest artifact deploy
--artifact-type dir` where `deploy/` holds `app.jar`. Reason: `kosli snapshot azure`
fingerprints zip-deployed web apps as the *extracted wwwroot contents* — the equivalent of
`kosli fingerprint -t dir` — so fingerprinting the directory is what will let the environment
snapshot match the built artifact when point 4 gets built. This is also why
`WEBSITE_RUN_FROM_PACKAGE` is pinned to `0` in `infra/main.bicep`.

**`deploy/.kosli_ignore` excludes `logs/`, `*.log` and `*.html`.** Azure/Kudu writes its own
files into wwwroot alongside whatever was deployed (application logs, a default
`hostingstart.html`-style landing page) that were never part of what CI built. Since
`kosli snapshot azure` fingerprints the *unzipped* package the same way `kosli fingerprint -t
dir` does, and that digest function (`DirSha256` in the CLI) reads a `.kosli_ignore` at the
directory root for exactly this — see `kosli-dev/server#2270`, shipped in kosli-cli v2.10.16 —
those extra files would otherwise make the environment snapshot's fingerprint never match the
one CI attested, even though the actual deployed jar is identical. The file has to be tracked
in git (`.gitignore` has `!deploy/.kosli_ignore` alongside `!deploy/.gitkeep`) so it survives
`mkdir -p deploy` and ships inside the zip `azure/webapps-deploy@v3` uploads — it is not
generated by the workflow.

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
released with one platform missing.

**The build is three parallel jobs behind a `trail` job.** `backend` and the two `mobile`
matrix legs all attest to the same trail, so the trail has to exist before any of them starts
— that is the whole job of `trail`, and it is why the legs cannot race creating it.
`release-gate` needs `mobile` as well as `backend`: it asserts trail compliance, which
includes both `oversecured` attestations, so without that edge it could run while a leg is
still going. `publish-gate` needs only `backend`, since it judges the backend's controls.

**The mobile control is a canned Oversecured report** (customer's call, 2026-08-25),
replacing the mobsfscan SARIF scan, which is gone along with `make scan`.
`oversecured/report-fail.json` is the customer's own scan of an Android APK, with 2
high-severity findings; `oversecured/report-pass.json` is that scan with the two removed. Both
are committed, both were run through the rules, and only the passing one is wired up - nothing
selects between them yet. Both are `jq .`-normalised so they diff against each other.

**Only the report's header is attested; the report itself is an attachment.** The file is
3.7 MB, nearly all of it code snippets and HTML remediation text, and Kosli documents no size
limit for attestation data - not a thing to discover during a customer demo.
`scripts/oversecured_attestation.py` copies `header` verbatim (the rules read
`.header.scan.status` and `.header.severityCounts`) and reduces each finding to one line,
which lands at ~25 KB.

**`oversecured`'s third rule cross-checks the findings against the header.** Because the data
is a projection of the report, a `severityCounts` that disagrees with the findings it
summarises would otherwise pass on the header alone. Note the `// 0` in the second rule:
Oversecured omits a severity from `severityCounts` when its count is zero rather than
reporting `0`.

**The flow template lists only what the build produces; post-build controls live in policies**
(customer's call, 2026-08-25). The template is also the yardstick `kosli assert artifact` uses
at the publish gate, which runs minutes before the integration test result and the approval
exist — with them in the template, the publish gate failed every run on controls that could
not possibly be there yet. So `integration-tests` and `release-approval` are named in
`release-gate.yml` and `prod-deploy-gate.yml` instead. Putting them back in the template
re-breaks the publish gate. `peer-review-decision` is the exception that proves the rule: it
*is* in the template (customer's call, 2026-08-25), because unlike the other two it is
produced in the `backend` job, at the same time as the evidence it judges — there is no
publish-gate-breaking timing problem to design around, so it belongs where every other
build-time control does.

**The publish gate asserts no policy** (customer's call, 2026-08-25). `kosli assert artifact`
with neither `--policy` nor `--environment` judges the artifact against its flow template,
which is the question that gate asks: did the build produce everything it owed? Policies
belong to the release gate. `kosli/policies/publish-gate.yml` is therefore unused - kept, and
still created by the bootstrap, only because it documents the same control set as a policy.

**`release-gate` requires `trail-compliance`** - which is now exactly "the build did
everything it owed", including both mobile scans and the peer-review control decision -
**plus** three attestations by name: `integration-tests`, `release-approval`, and
`peer-review-decision` again (`for_control: peer-review`) even though `trail-compliance`
already covers it, so this policy requires a decision about that control in its own right.
There is no mobile-specific gate.

**`oversecured` has jq rules but no JSON Schema**, unlike the orders-api types. Nothing
principled — the rules already pin the parts of the shape they depend on.

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

**The approval is attested before the policy assert, in the same job.** `release-gate.yml`
requires `release-approval`, so the order matters. It also means the action fails the job outright if the environment has no required
reviewers: there is no approval entry to read, which is the correct outcome — an unprotected
environment cannot produce evidence of a human decision.

**The release gate runs after the approval, not before it.** The `release-gate` job sits on
the protected `production-release` environment, so approving it only lets the job *start*;
the job then runs `kosli assert artifact --policy release-gate`. That ordering is the whole
point of point 3 — a human can start the gate, a human cannot talk it into passing. Putting
the assert in the build job instead would make the approval the decision.

**`integration-tests` and `release-approval` are attested against the `orders-api`
fingerprint, not the trail.** Conceptually they are about the release rather than one binary,
and they were trail-level until the controls moved into the policies. A policy's
`attestations:` rules match attestations on the artifact being asserted, and the docs do not
say whether a trail-level attestation counts — betting on it would fail both gates for a
reason that reads like a missing test. The release-gate job has the fingerprint from
`needs.backend.outputs.orders-api-fingerprint`; the integration test workflow looks it up with
`kosli get artifact order-system-ci:<sha> --output json`.

**Everything is built once, in one job.** The backend JAR and both mobile zips come from the
same checkout, are fingerprinted there, and every attestation binds to those fingerprints. No
rebuild happens later, so there is no question of the gated fingerprint differing from the
deployed one.

**The integration test workflow always succeeds, whichever variant you pick.** Same rule as
everywhere else here: scripts report facts, Kosli decides. `fail` is the default input so the
demo's first pass through the gate shows it blocking.

**The Makefile owns turning source into artifacts; the workflows own everything that talks to
Kosli.** So `make package` needs no API token, and the gate only ever runs in Actions. Keep
that line: it is why the mobile half needs no toolchain installed.

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
  project; `androidx.appcompat` is an unresolved import. The artifacts are zips of the source,
  so the fingerprint-and-gate half is real.
- **Nothing scans this repo's mobile source any more.** The Oversecured report describes an
  Android APK belonging to someone else (`app.name: "xxxx-Android"`, `scan.fileName:
  "file1.apk"`), and the same report is attested to both mobile artifacts - including the iOS
  one, whose `platform` field therefore says `android`.
- **`minSdkVersion=30`, `<uses-sdk>` and the empty `NSAppTransportSecurity` dict are
  historical** - added to satisfy mobsfscan, which is gone. Harmless, and correct for a real
  app, so they stay.
- **The mobile control has no failing case in the pipeline**, though `report-fail.json` is in
  the repo and does fail the rules. Showing it block needs a workflow input that selects it.
- **Nothing validates the jq rules automatically.** All three `oversecured` rules were run with
  `jq` against the committed report and the failing original; there is no check that keeps them
  honest, so a later edit's breakage is first seen in a workflow run.

## Setup

Secret `KOSLI_PUBLIC_API_TOKEN` (the workflows map it onto `KOSLI_API_TOKEN` in the job env,
since that's the only env var name the Kosli CLI itself recognizes for `--api-token`); then
run the **Bootstrap Kosli** workflow (re-run it after any change under `kosli/`: it creates
the four custom types, the `peer-review` control, and both policies). **Controls is a beta
feature that Kosli has to enable for `kosli-public`** before `create control` or the
`peer-review` control decision step in `ci-build.yml` will do anything but fail — confirmed
disabled as of 2026-08-25 (`kosli list controls --org kosli-public` → "Controls is not
enabled for this organization"). Enable the Sonar integration in the
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
