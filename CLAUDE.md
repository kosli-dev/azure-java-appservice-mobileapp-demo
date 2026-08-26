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
- **Point 3** — a release process. Clearing the publish gate deploys the build to a staging
  App Service; an integration test run is then reported to the trail by a separate manual
  workflow (pass or fail, from canned JSON), and a protected GitHub environment halts the
  pipeline until someone approves — after which Kosli, not the approver, decides. Only once
  the release gate opens is the same build deployed to the production App Service.

Kosli org: `kosli-public`.

**One pipeline, one flow** (customer's call, 2026-08-24). `ci-cd.yml` and `mobileorders.yml`
are gone and `release.yml` became `ci-build.yml`, triggered by a push to `main` rather than a
tag. Everything the three workflows attested now lands on one flow, `order-system-ci`, whose
trail is the commit:

| Artifact | Attestations |
| --- | --- |
| `orders-api` | `unit-tests`, `sonar-quality-gate`, `mutation-tests`, `sbom` |
| `mobileorders-android` | `oversecured`, `sbom` |
| `mobileorders-ios` | `oversecured`, `sbom` |
| (trail level) | `pull-request`, `peer-review-decision`, `integration-tests`, `release-approval` |

`orders-api.peer-review` is gone (customer's call, 2026-08-25): it had already been reduced to
evidence only, with no compliance-deciding jq rules, once the judgment moved to a control —
and evidence nobody reads back from Kosli doesn't need to be attested. The facts now come from
the trail's own `pull-request` attestation, fetched back with `kosli get attestation` and fed
straight into `kosli evaluate input --policy kosli/policies/peer-review.rego`. The verdict is
recorded as `peer-review-decision`, a `decision`-type attestation against the `peer-review`
control — **trail-level, not bound to `orders-api`, and judged in its own `peer-review` job**
(customer's call, 2026-08-26; previously it was `orders-api.peer-review-decision`, attested
with `--fingerprint` in the `backend` job — see the design decision below for why that
changed). It *is* in the flow template — being there means publish-gate blocks on a bad peer
review, same as before.

Template: `kosli/flow-templates/order-system-ci.yml`. The `orders-api-ci`, `mobileorders` and
`order-system-release` flows still exist in `kosli-public` with their history; nothing writes
to them any more.

## State

Pushed and landed. **Has now run live once** (2026-08-25, `ci-build.yml` run 32834236540, on
the `orders-api.peer-review` → `get attestation` change): `backend` failed at "Evaluate and
record the peer review control decision" with `[kosli evaluate input flow=order-system-ci]
failed to parse input: EOF`. Root cause was one step earlier - `kosli get attestation
pull-request --flow ... --trail ...` failed with `only one of --trail, --fingerprint is
allowed when using ATTESTATION-NAME`, so `pull-request.json` came out empty and `evaluate
input` choked on the empty file. `KOSLI_FINGERPRINT` (a job-level env var set by the earlier
"Attest the backend" step, for later attestations on that artifact) is auto-bound by the CLI
to any command's `--fingerprint` flag purely from the env, whether or not that command's
invocation passes it - so `get attestation`, which never mentions `--fingerprint`, still got
one from the environment and collided with `--trail`. Fixed by clearing
`KOSLI_FINGERPRINT: ""` in that one step's `env:` (confirmed empty-string clears it, tested
against `kosli-public` directly - unset and empty-string behave the same; a real, non-empty
value is what triggers the conflict). See the matching Gotcha below. Not yet re-run to confirm
the fix goes green; that is the next live run to check.

For the staging environment, verified live against Azure (2026-08-25): the staging resource
group, plan and web app were created for real by `infra/deploy.sh staging` in subscription
`96cdee58-1fa8-419d-a65a-7233b3465632` ("Steve Test"), where production already existed;
`az role assignment list` shows Contributor on both resource groups, and
`az ad app federated-credential list` shows the current repo name's subjects. `actionlint` and
`shellcheck` are clean on the workflow and script changes (both run in Docker - neither binary,
nor `az`, nor `bicep` is installed in the agent's sandbox, so `bicep build` was **not** re-run
against the edited `main.bicep`; `az deployment group create` accepting it is the evidence
there). The pipeline half has not run: no `deploy-staging` job has ever executed, so the
composite action, the OIDC login from a `staging`-environment job and the staging smoke test
are all unproven.

The next push (`8029407`, "make mutation tests fail (#33)") ran live too (2026-08-26,
`ci-build.yml` run 32942476644): `backend` and both `mobile` legs passed, `publish-gate`
failed as expected on `mutation-tests` (76.5% against the `MUTATION_THRESHOLD` repo var, which
was raised from 70 to **80** the same day, 07:22 UTC, specifically to make this push fail).
The original `waive-attestation.yml` (deleted the same day, see below) was then dispatched by
hand against that trail/fingerprint and also failed (run 32942853972): its "Re-check the
publish gate" step asserted `--policy publish-gate`, which is the orphaned `publish-gate`
policy object left attached to nothing (see the publish-gate design decision below) — not the
same check `publish-gate` (the job) actually runs, which asserts `--flow order-system-ci` with
no `--policy`. That stale, disconnected policy is why the step failed with `mutation-tests` is
non-compliant even while the printed attestation table showed it `compliant: true` (the
waiver itself had already landed). This prompted dropping the waiver mechanism altogether
(customer's call, 2026-08-26) in favour of `rerun-mutation-tests.yml`, which re-ran PIT with a
lower threshold and re-attested for real, then re-checked the gate the correct way (`--flow`,
no `--policy`). The customer then asked for the waiver back (same day) — see the "waiver
mechanism is back" design decision below — so the file was restored under its original name,
`.github/workflows/waive-attestation.yml`, POSTing an override instead of re-running PIT, and
re-checking staging's actual attached policy (`--environment`) rather than either the flow
template or a standalone policy object. Not yet run live in this form.

The `sbom` attestations (added 2026-08-26) took two live rounds to land. **Round one**
(all three legs): SBOM generation itself failed - `anchore/sbom-action@v0`'s `path` input
always scans as `dir:<path>`, which only tries directory-shaped source providers (`oci-dir`,
`local-directory`), so pointed at a single file (`deploy/app.jar`, or a mobile zip) every leg
failed with "could not determine source ... not a directory". Fixed by installing syft with
`anchore/sbom-action/download-syft@v0` and calling `syft <path> -o cyclonedx-json=<file>`
directly instead of the all-in-one action - a bare path with no scheme prefix lets syft's own
source auto-detection reach the `file` provider that `dir:` skips. **Round two**: generation
passed for all three, but the attestation step then failed for both mobile legs (not the
backend) with `Input payload validation failed: map[:'components' is a required property]`.
Cause: `kosli/attestation-types/cyclonedx-sbom.schema.json` listed `components` as required,
but syft omits the `components` key entirely (not `[]`) when a scan finds zero packages - and
it always finds zero for the mobile zips, which have no Gradle/CocoaPods manifest (see the
mobile gotchas). The backend jar always has *some* Spring Boot dependency, so it never hit
this path, which is why only the mobile legs failed. Fixed by dropping `components` from
`required` in the schema (kept in `properties`, so it's still documented and still validated
when present) - confirmed against syft's actual empty-scan output, not just the schema text.
Not yet re-run live to confirm this second fix goes green.

Verified before pushing:

- `mvn verify` green; PIT scores **76.5%** (13/17 mutants killed) against the default 85%
  threshold, so the mutation control fails by design.
- Every Kosli command dry-run against CLI **v2.38.0**.
- `kosli/policies/*.yml` validated against `https://docs.kosli.com/schemas/policy/v1.json`.
- `kosli/flow-templates/*.yml` validated against the `Template` model in Kosli's OpenAPI spec.
- `actionlint` (with shellcheck), `shellcheck`, and `bicep build` all clean.
- `kosli/policies/peer-review.rego` passes `opa check` and `opa fmt --diff` (no diff), and
  `kosli evaluate input` against it returns the expected verdict for all four cases: two
  approvers, one independent approver, one dependent approver, no pull request. Unlike almost
  everything else in this file, this one *has* talked to a live API: the shape asserted in the
  rego (`pull_requests[].{url,merged_at,approvers[].username,commits[].author_username}`) was
  read back from an actual `pull_request`-type attestation in `kosli-public` (flow
  `actions-integration`) with `kosli get attestation`, and cross-checked against a `--dry-run
  --debug` run of `kosli attest pullrequest github` against real merge commits in this repo's
  own history (two distinct approvers, one independent approver, and zero pull requests all
  observed for real commits) — not just guessed from the CLI's `--help` text.

For the mobile half, verified locally after the switch to Oversecured: all three
`oversecured` rules return true against the slim data the script emits from
`oversecured/report-pass.json`, and the second and third return false against
`oversecured/report-fail.json`. `make package` still produces
both zips, and `kosli attest custom` dry-runs with each zip's own fingerprint.

For the release half (point 3), verified locally: the flow template and the environment
policies validate against the published schemas; every new Kosli
command dry-runs clean on **v2.38.0** (including `bootstrap_kosli.sh` end to end);
`make package` produces both mobile zips; the three `integration-test` jq rules were run with
`jq` against both canned reports and return the expected verdicts (pass: all true, fail:
`.failed == 0` and `.errors == 0` false). Nothing about it has run in Actions.

Not verified, and the first live run is the test of it:

- The `sbom` attestations' current fix (dropping `components` from the schema's `required`
  list, see State above). Not yet re-run live - the two prior rounds each surfaced a failure
  the other didn't, so a third clean run is the actual bar, not just a plausible-looking dry
  run.
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
  not the stored name. It matters for the named attestations in `production-readiness.yml`
  and `secure-development.yml`, which are matched with plain names against the artifact's
  fingerprint. Confirmed the stored name is
  short either way `attest decision` addresses the artifact: a dotted dry run (`--name
  orders-api.peer-review-decision`, no `--fingerprint`) split into `attestation_name:
  "peer-review-decision"` plus `target_artifacts: ["orders-api"]`; a plain dry run (`--name
  peer-review-decision --fingerprint "$KOSLI_FINGERPRINT"`) produced the identical
  `attestation_name` with `artifact_fingerprint` set directly and no `target_artifacts`. This
  finding is what `release-approval` still relies on — prefer `--fingerprint` over the dotted
  address-by-template-name form whenever the fingerprint is already in hand (as it is by
  `release-gate`), and reserve the dotted form for attestations made before the artifact
  itself has been reported. `peer-review-decision` no longer uses either form of
  artifact-addressing (see the 2026-08-26 design decision above): it is trail-level now, with
  no `--fingerprint` and no dotted name.
- Whether the custom attestation type names collide with existing types in `kosli-public`.
  Run `kosli list attestation-types` before the first bootstrap — re-running it would version
  an existing type rather than create a new one.
- Whether `kosli assert artifact --environment azure-appservice-prod` really fails when
  `integration-tests` is missing or non-compliant. Both release controls are artifact-bound
  and named in `production-readiness.yml`, which should make it a straightforward match — but
  a gate that passes when it should block is the one failure mode invisible in the demo. Check
  the first blocked release blocks. One vacuous-pass route is already closed and does not need
  re-checking: an environment with *no* policies attached makes that command print COMPLIANT
  and exit 0 (verified against `azure-appservice-staging`, which had none), so the job refuses
  to run unless `kosli get environment` reports at least one attached policy.
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
pipeline attests `pull-request` (trail level) for the raw evidence, and separately judges the
same pull-request facts (who approved, whether they wrote the code) to decide whether it counts
as a peer review — see below for how those facts are judged and what happens to them.

**Peer review is judged from the `pull-request` attestation's own data, fetched back with
`kosli get attestation`, not from a second GitHub API call.** `scripts/peer_review_attestation.py`
used to re-fetch the same PR/reviews/commits facts from the GitHub API directly into
`peer-review.json` — duplicate work, since `kosli attest pullrequest github` (the `trail` job,
above) had already fetched exactly that. Removed (customer's call, 2026-08-25, prompted by
noticing the duplication): the `peer-review` job instead runs `kosli get attestation
pull-request --flow order-system-ci --trail "$KOSLI_TRAIL" --output json | jq '.[0]' >
pull-request.json` and feeds that straight to `kosli evaluate input --policy
kosli/policies/peer-review.rego`. The shape is the CLI's own — `pull_requests: [{url,
merged_at, approvers: [{username}], commits: [{author_username}], ...}]` — confirmed by
reading it back from a real attestation in `kosli-public` and by `--dry-run --debug` runs of
`attest pullrequest github` against this repo's own history (see State, above); the rego picks
the merged PR if there is one (falling back to the first) and compares `approvers` against
`commits[].author_username` for the same two-distinct-or-one-independent rule as before. This
is a **read-after-write** dependency on the `trail` job's `pull-request` attestation that the
old script never had, so it inherits a new failure mode: in `KOSLI_DRY_RUN` mode the `trail`
job's `attest pullrequest github` call never actually writes anything, so this `get
attestation` call finds nothing for that trail and the step fails — see Gotchas.

**A non-compliant peer-review decision carries its `violations` as annotations, not just in
the step log.** `kosli evaluate input`'s JSON output has a `violations` array (empty when
compliant); `ci-build.yml` reads it with `jq '.violations[]?'` and adds one `--annotate
violation_N=<text>` per entry to the `kosli attest decision` call, so the reason a peer review
failed is visible on the attestation itself, not only in the CI log. Numbered keys
(`violation_1`, `violation_2`, ...) rather than the violation text itself, because
`--annotate`'s keys are restricted to `[A-Za-z0-9_]` — the peer-review.rego violation strings
have spaces and commas, so they can only be values, never keys. In practice this rego only
ever produces zero or one violation at a time (`no pull request found` and `requires two
distinct approvers...` are mutually exclusive by construction), but the loop handles any
count so it keeps working if the policy grows more violation branches later.

**Peer review's judgment moved off an attestation type and onto a control (customer's call,
2026-08-25), and the type itself was dropped shortly after (customer's call, same day).**
`orders-api.peer-review` used to be a custom attestation type carrying the compliance-deciding
jq rule `(.distinct_approvers >= 2) or (.independent_approval == true)` directly, the same as
every other custom type here. That judgment moved to `kosli/policies/peer-review.rego`, run
with `kosli evaluate input --policy kosli/policies/peer-review.rego` against the pull-request
attestation data described above, with the verdict recorded as a `decision`-type attestation
against the `peer-review` control (`kosli create control peer-review`), via `kosli attest
decision --control peer-review --compliant=<verdict>`, named `peer-review-decision` in
`kosli/flow-templates/order-system-ci.yml`. Once the type carried no jq rules of its own —
evidence nobody read back from Kosli — attesting it stopped earning its keep, so the `kosli
attest custom --type peer-review` call and the `kosli create attestation-type peer-review`
call were both removed; `pull-request.json` still travels as an `--attachments` file on the
`peer-review-decision` attestation, so the raw evidence is not lost, just no longer
double-attested. Unlike
`integration-tests`/`release-approval`, `peer-review-decision` is produced in the same job as
the evidence it judges, so being in the flow template (and so gating publish-gate, via
`trail-compliance`) is correct, not a timing hazard. This does **not** reopen the earlier
decision to use `kosli assert artifact --policy` over `kosli evaluate trail` for the release
gate itself — that risk (`evaluate` needing per-org beta enablement) is exactly why peer
review is judged with `evaluate input` against a local JSON file rather than `evaluate trail`
against the org's copy of it. `kosli create control` and `kosli attest decision` are
themselves beta and do hit the org, though, and `kosli-public` does not have Controls enabled
yet — see State, above. Mirrors the "never alone" control in
https://github.com/kosli-dev/control-actions, same as before. The environment policies were
updated to name `peer-review-decision`/`decision` instead of
`peer-review`/`custom:peer-review`; the now-unused
`kosli/attestation-types/peer-review.schema.json` was deleted.

**Peer review moved into its own job, and the decision attestation moved from artifact-bound
to trail-level (customer's call, 2026-08-26).** Previously the fetch-evaluate-attest sequence
ran inside `backend`, and `kosli attest decision` bound it to the `orders-api` fingerprint
(`--fingerprint "$KOSLI_FINGERPRINT"`, addressed as `orders-api.peer-review-decision`). Now
the `peer-review` job (`needs: trail` only) does the fetch, evaluate and attest, and the
`attest decision` call carries no `--fingerprint` at all — it binds to the trail via the job
env's `KOSLI_FLOW`/`KOSLI_TRAIL`, exactly like the trail job's own `pull-request` attestation.
Both changes together mean `peer-review-decision` moved from `artifacts.orders-api.attestations`
to `trail.attestations` in `kosli/flow-templates/order-system-ci.yml`, and its entry was
dropped from `kosli/policies/secure-development.yml`'s `attestations:` list — a policy's
`attestations:` rule only matches attestations bound to the artifact being asserted (confirmed
against the published policy schema: there is no way to name a trail-level attestation
requirement in an env-type policy), so a trail-level `peer-review-decision` can only be
enforced the way `pull-request` already was — implicitly, through `trail-compliance: required:
true`, which requires every attestation the flow template demands, trail-level or not. This is
not a bet on undocumented behaviour: `pull-request` has worked exactly this way (trail-level,
required only via `trail-compliance`, never named in a policy's `attestations:` list) since
before this change, and publish-gate has always waited on it — this just applies the same
already-proven pattern to `peer-review-decision`. Splitting the job also kills the
`KOSLI_FINGERPRINT: ""` workaround documented in the Gotchas (the exact one that broke the
2026-08-25 live run, see State) — the `peer-review` job never sets `KOSLI_FINGERPRINT` in the
first place, so `kosli get attestation pull-request --trail ...` has nothing to collide with.
`publish-gate` gained `peer-review` in its `needs:` (alongside `backend`) so it still waits for
the decision before asserting; `release-gate` needed no change, since it already depends on
`publish-gate` transitively. (`publish-gate` went on to gain `mobile` too, for an unrelated
reason — see the "publish gate asserts the staging environment" design decision below.) Not
yet run live.

**The gate is `kosli assert artifact`, not `kosli evaluate trail` with rego.**
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

**The waiver mechanism is back (customer's call, 2026-08-26), restored under its original
name, `.github/workflows/waive-attestation.yml`.** This reverses an earlier decision made the
same day: the rerun-and-reattest approach (re-run PIT with a different threshold, attest a
fresh result, re-check the gate) had briefly replaced waiving altogether, on the reasoning
that mutation testing can always be made to pass for real — PIT's threshold is a CLI flag —
so recording an override next to a result that was never re-checked was a second, weaker path
to "compliant". That reasoning still holds for mutation testing specifically, but the waiver —
an artifact-bound override with a human-readable reason, recorded on the trail forever, for a
control someone has decided is acceptable to ship despite failing — is the more general
mechanism, and the customer wants it available again. `rerun-mutation-tests.yml` was renamed
back rather than living alongside a second, differently-named file: same content rewritten in
place, `git mv`'d to `waive-attestation.yml`, `name:` "Waive an attestation", job `waive`
(previously `rerun`). It POSTs straight to the override endpoint (`POST
/api/v2/attestations/{org}/{flow}/trail/{trail}/override`, with `reason` and
`new_compliance_status` — there is no `kosli waive` command) instead of re-running Maven/PIT.
`scripts/waive_attestation.sh` is **not** restored — the request was to consolidate the logic
into the workflow, and the POST is short enough (one `jq -n`, one `curl`) to live in a `run:`
step, so there is no script to keep in sync with it. Inputs are `trail`, `fingerprint`,
`reason` (all required) plus `artifact` (default `orders-api`), `attestation` (default
`mutation-tests`) and `attestation_type` (default `custom:mutation-testing`) — mutation testing
is the one control that fails via an env var in this demo, hence the defaults, but any
artifact-bound attestation on the trail can be waived by overriding them. `mutation_threshold`
is gone as an input, along with the checkout, `setup-java` and PIT run it existed to drive.

**The old `waive-attestation.yml`'s bug is fixed, not reintroduced, by re-checking the real
staging policy instead of any standalone policy object.** Its original "Re-check the publish
gate" step asserted `--policy publish-gate`, the orphaned policy object left attached to
nothing (see the publish-gate design decision below) — not the check `publish-gate` (the job)
actually runs. That mismatch broke a real dispatch (run 32942853972, see State above): the
step failed with `mutation-tests` non-compliant even though the override had already landed
and the printed table showed `compliant: true`. The intermediate `rerun-mutation-tests.yml`
avoided this by asserting against the flow template directly (`--flow order-system-ci`, no
`--policy`) — the same check `publish-gate` ran *at the time*. The restored workflow's second
job, `recheck`, instead asserts `kosli assert artifact --fingerprint ... --environment
"$KOSLI_ENV_STAGING" --flow order-system-ci` against staging only
(`vars.KOSLI_ENVIRONMENT_STAGING || 'azure-appservice-staging'`, the same fallback pattern
`snapshot-azure-environment.yml` and `publish-gate` use) — the same check `publish-gate`
itself now runs (see the design decision below, 2026-08-26, written after this one). Staging
only, not production, on purpose (customer's call, 2026-08-26, narrowing an initial two-leg
matrix): a waiver's whole point is unblocking the gate that is actually stuck, which is
`publish-gate`, and `release-gate` still does its own real assert against production later,
once the release controls exist — a stale pre-approval re-check against production here would
tell the operator nothing that gate doesn't already check for itself. The job guards against
the same vacuous-pass failure mode `release-gate` and `publish-gate` already guard against -
an environment with no policies attached would otherwise print `COMPLIANT` no matter what -
with the identical `kosli get environment ... | jq '.policies | length'` check before
asserting. Not yet run live in this form - the override POST and the `--policy publish-gate`
fix were each carried over from something that *did* run live at some point, but the
environment re-check is new.

This is still not a precedent for every failing control needing a waiver path: it is one
either way — the override endpoint is generic and any artifact-bound attestation on a trail
can be named. What is control-specific is only the *default* inputs, which point at
mutation-tests because that is the control this demo can fail on demand.

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

**The SBOM is a custom type with no jq rules, not a `generic` attestation.** `orders-api`,
`mobileorders-android` and `mobileorders-ios` each get a `sbom` attestation generated by syft
(installed with `anchore/sbom-action/download-syft@v0`, invoked directly - see the Gotchas
entry on why not the all-in-one `anchore/sbom-action@v0`) against the built jar or zip,
CycloneDX JSON, and reported with `kosli attest custom --type cyclonedx-sbom`, bound with
`--fingerprint` to the
fingerprint already computed earlier in the same job (`KOSLI_FINGERPRINT` for the backend, a
captured `steps.artifact.outputs.fingerprint` for mobile) rather than recalculated. The type
(`kosli/attestation-types/cyclonedx-sbom.schema.json`, created in `bootstrap_kosli.sh`) pins
the CycloneDX top-level shape but carries no `--jq` rules, so it always reports
`compliant: true` (the CLI's own default when a custom type has no rules to fail) — same
"scripts/tools report facts, Kosli decides" split as everywhere else, except here nothing is
asked to decide anything, because there is no compliance question to ask of an SBOM in this
demo: it is evidence for the Evidence Vault (and, via `--attestation-data`, queryable data on
the attestation itself), not a control. A plain `generic` attestation would have done the
"evidence with an attachment" half of this just as well, but a custom type is what lets the
schema document the CycloneDX shape and lets a later jq rule (e.g. a banned-license or
known-CVE check) be added without changing how the SBOM is generated or attested — `generic`
has no schema and no way to grow jq rules later. For the mobile zips this SBOM will be
near-empty: neither app has a real Gradle/CocoaPods manifest for syft to read (see the mobile
gotchas below), so it mostly demonstrates the attestation path rather than surfacing real
dependencies.

**Both mobile apps are artifacts of the system flow, not of a flow of their own.** A trail is
compliant only once both have been packaged, scanned and found clean, so a commit cannot be
released with one platform missing.

**The build is four parallel jobs behind a `trail` job.** `peer-review`, `backend` and the two
`mobile` matrix legs all attest to the same trail, so the trail has to exist before any of
them starts — that is the whole job of `trail`, and it is why they cannot race creating it.
Both gates now need `mobile` as well as `backend`, for the same reason: each asserts
`--environment` (staging for `publish-gate`, production for `release-gate`), and
`secure-development.yml`'s `trail-compliance: required: true` spans the whole trail, both
`oversecured` attestations included, so without that edge either gate could run while a mobile
leg was still going. `publish-gate` also needs `peer-review`: `peer-review-decision` is
trail-level, produced by a job of its own rather than by `backend` — see the 2026-08-26 design
decision above.

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
(customer's call, 2026-08-25). Every policy's `trail-compliance: required: true` ultimately
judges the template — directly for `publish-gate`'s and `release-gate`'s own environments, and
this is still what makes the template the yardstick that matters, even though `publish-gate`
now asserts `--environment azure-appservice-staging` rather than the template file directly
(see the design decision above). `publish-gate` runs minutes before the integration test
result and the approval exist — with them in the template, `trail-compliance` would fail
every run on controls that could not possibly be there yet. So `integration-tests` and
`release-approval` are named in `production-readiness.yml` instead, attached to production
alone, never to staging. Putting them in the template, or in `secure-development.yml` (attached
to both environments), re-breaks the publish gate. `peer-review-decision` is the exception
that proves the rule: it *is* in the template (customer's call, 2026-08-25), because unlike
the other two it is produced by the time `publish-gate` runs — originally because it was
attested inside the `backend` job itself; since 2026-08-26 because the `peer-review` job it
now lives in is a dependency of `publish-gate` in its own right (`needs: [backend,
peer-review, mobile]`). Either way there is no publish-gate-breaking timing problem to design
around, so it belongs in the template like every other build-time control, trail-level or not.

**The publish gate asserts the staging environment (customer's call, 2026-08-26), reversing an
earlier decision to assert no policy at all (customer's call, 2026-08-25).** The original
reasoning still explains why `kosli/policies/publish-gate.yml` is gone: `kosli assert artifact
--environment` judges the artifact against every policy attached to that environment, and
staging carries only `secure-development.yml`, so a standalone policy asserting almost the
same control set would only drift out of sync with it, the same reasoning that got
`release-gate.yml` deleted in favour of `--environment azure-appservice-prod`. What changed is
*which* assert mode: `--flow "$KOSLI_FLOW"` alone (neither `--policy` nor `--environment`)
judges the artifact against its flow template directly - did the build produce everything it
owed - which is artifact-scoped: it does not pull in other artifacts' own required
attestations (see the peer-review-decision trail-level design decision above for why this
matters). `--environment azure-appservice-staging --flow "$KOSLI_FLOW"` asks a different
question - would this artifact be allowed to run in staging - and answering it pulls in every
policy attached there, currently just `secure-development.yml`, whose `trail-compliance:
required: true` spans the *whole trail*, mobile legs included. That is why `publish-gate`
gained `mobile` in its `needs:` alongside `backend` and `peer-review` - without that edge it
could assert while a mobile leg was still going, the same race `release-gate` already guards
against by needing `mobile` itself. The job also gained the same
"environment has policies attached" guard `release-gate` uses, for the same vacuous-pass
reason (see below). The `publish-gate` policy object still exists in `kosli-public`, attached
to nothing; there is no `kosli delete policy`, so removing it needs the UI or the API.

**The release gate asserts the production environment, not a policy of its own**
(customer's call, 2026-08-25). `kosli assert artifact --environment azure-appservice-prod`
judges the artifact against every policy attached to that environment, which is
`secure-development` plus `production-readiness` - between them provenance,
`trail-compliance` ("the build did everything it owed", including both mobile scans and the
peer-review control decision) and the two release controls. So the gate asks exactly "would
this be allowed to *run* in production?", and there is one definition of that, enforced here
before the deploy and continuously afterwards by the snapshots. `kosli/policies/release-gate.yml`
said almost the same thing and was deleted rather than kept in sync; its `create policy` call
is gone from `bootstrap_kosli.sh` too, which now creates only types and the control. The
`release-gate` policy object still exists in `kosli-public` attached to nothing - no
`kosli delete policy` exists. There is no mobile-specific gate.

**The release-gate job refuses to run if the environment has no policies attached.** Verified
against `kosli-public`: `assert artifact --environment azure-appservice-staging`, with nothing
attached to it, printed `COMPLIANT` with an empty policy table and exited 0. Asserting an
environment therefore has a failure mode asserting a named policy does not - detach the
policies (or never attach them, by running the bootstrap with *create environment* unchecked)
and the gate waves everything through. So the job reads `kosli get environment --output json`
and fails on `.policies | length == 0` before asserting. Do not "simplify" that step away.

**`oversecured` has jq rules but no JSON Schema**, unlike the orders-api types. Nothing
principled — the rules already pin the parts of the shape they depend on.

**Deploy is the last job, and the release gate is the only way to reach it.** The deploy job
downloads the artifact the gates approved rather than rebuilding, so the fingerprint that
reaches App Service is the one Kosli judged. Nothing else in the repo deploys.

**Staging sits between the two gates** (customer's call, 2026-08-25). `deploy-staging` needs
`[backend, publish-gate]`, and `release-gate` gained `needs: deploy-staging`, so the order is
publish-gate → staging → approval → release-gate → production. Staging is gated by
publish-gate alone: no second assert after it. Publish-gate itself now asserts the staging
environment directly (see the design decision above) rather than the flow template, but the
question it asks is still the pre-release one — would this be allowed onto staging — not
anything requiring the integration test run or the approval: those live only in
`production-readiness.yml`, attached to production alone, so staging's one attached policy
(`secure-development.yml`) still cannot block on a control that does not exist yet. A policy
that could block staging on the release controls would block the very testing whose result
the release gate then requires — that constraint is why `production-readiness.yml` is
deliberately not attached to staging, not a reason to keep publish-gate off `--environment`
altogether.

**The environment policies are split along the same line as the gates** (customer's call,
2026-08-25). `kosli/policies/secure-development.yml` — provenance, trail-compliance and the
four build-time controls — is attached to *both* Azure environments;
`kosli/policies/production-readiness.yml` keeps only `integration-tests` and
`release-approval` and is attached to production alone. Every policy attached to an
environment has to pass, so production is judged by the union of the two and nothing is
duplicated between them: `production-readiness` deliberately omits `provenance` and
`trail-compliance` (the schema defaults both to `required: false`) because
`secure-development` already requires them everywhere. The reason for the split is the same
timing that keeps `integration-tests` and `release-approval` out of the flow template: a build
lands on staging minutes before either can exist, so the old single policy would have made
staging permanently non-compliant if it were ever attached there. Before this, staging carried
no policy at all, which meant nothing judged what was running on it. When the nginx exception
arrives, it belongs in `secure-development.yml` — the common policy is where "what may run
here at all" lives.

**These two are named after the domain they govern, not the mechanism** (customer's call,
2026-08-25). They were `deploy-gate` and `prod-deploy-gate` for about an hour, which was
wrong twice over: "gate" is what `publish-gate` and `release-gate` do — block a pipeline —
whereas these judge what is *already running*, continuously, and the `prod-` prefix said
nothing about what actually differed between them. `secure-development` is the ISO 27001 A.14
name for this control set (provenance, review, tests, static analysis);
`production-readiness` covers both of its controls, where `production-approval` would have
named only the human half and left the integration test run unaccounted for. Do not rename
them back, and keep gate names for the two things that really are gates.

**Each deploy reports its environment's snapshot before anything else is reported**
(customer's call, 2026-08-25). `snapshot-after-staging` sits between `deploy-staging` and
`report-integration-tests`, and `snapshot-after-production` after `deploy`, so an artifact's
history reads
built → attested → running in staging → tested → approved → running in production. Without
them the only snapshots came from the 15-minute schedule, which could land the "started
running in staging" event *after* the integration test result and the approval - a sequence
that reads backwards for something whose whole point is the order of events.

Both jobs report *both* environments, including the one that cannot have changed: a snapshot
of an unchanged resource group reports the same state again, so there is nothing to gain from
parameterising the call by which deploy it follows - and nothing to get wrong either, since
neither caller passes a resource group. The matrix lives in the reusable workflow.

They are `workflow_call` jobs against `.github/workflows/snapshot-azure-environment.yml`, not
`gh workflow run` dispatches like the integration test report. That is the whole reason the
reusable workflow exists: `needs:` on a called workflow is synchronous, so the pipeline knows
the snapshot landed before it moves on, and a dispatch cannot promise that at all - it returns
as soon as the run is queued. It also keeps `AZURE_CLIENT_SECRET` out of the deploy jobs;
`kosli snapshot azure` calls the Azure management API directly and has no OIDC path, so the
secret has to exist somewhere, but it need not exist in the job that also holds the deploy
credentials. `report-azure-environment.yml` is now just the periodic sweep: it keeps the
matrix and the `REPORT_AZURE_ENV` guard (which is how the *schedule* is turned off) and calls
the same reusable workflow, so the pipeline and the sweep cannot drift. The pipeline's own
snapshot jobs are deliberately **not** guarded on that variable - they are part of the release
story, not the sweep.

**The integration test report auto-triggers after staging deploy, but stays a workflow_dispatch
workflow too** (2026-08-25). `deploy-staging`'s last step calls `gh workflow run
report-integration-test-result.yml -f commit="$KOSLI_TRAIL"` (needs `actions: write` on that
job's token) and deliberately omits `-f result=...`, leaving `result` on a new `default` choice
(alongside `pass`/`fail`). The workflow resolves `default` to the `INTEGRATION_TEST_DEFAULT_RESULT`
repo variable, falling back to `pass` if unset — chosen, not `fail`, so the pipeline reaches a
deployable state with no manual step at all. This changes what the out-of-the-box demo shows:
previously `result`'s own schema default was `fail`, so a release approved with no manual
step was *always* blocked on `integration-tests`, showing the "controls, not a green pipeline"
story for free. Now that first-blocking-for-free behaviour is gone unless
`INTEGRATION_TEST_DEFAULT_RESULT` is set to `fail` — to demo the block, either set that
variable or run `report-integration-test-result.yml` by hand with `result: fail` before
approving `release-gate`; running it again after (any result) adds a second attestation and
Kosli judges the latest, per the existing "reporting again" behaviour. Not run live yet — the
first live run of `ci-build.yml` since this landed is what confirms `gh workflow run`
authenticates correctly with the job's own `GITHUB_TOKEN` and that `--ref` (passed as
`github.ref_name`, i.e. `main`) resolves against a workflow file that only exists on that same
push.

**Each environment gets its own Azure resource group.** `kosli snapshot azure` snapshots a
whole resource group and has no way to filter by app (checked against CLI v2.38.0 — the only
scoping flag is `--azure-resource-group-name`), so two web apps in one group would report into
one Kosli environment and could never be gated apart. Hence `rg-kosli-orders-api-demo` /
`rg-kosli-orders-api-demo-staging`, one `kosli snapshot azure` leg each, and
`main.bicep`'s `environment` param (`prod`|`staging`) which only tags resources —
`infra/deploy.sh <env>` derives both names from it. Deployment *slots* were the other option
and were rejected twice over: they need a Standard-tier plan (B1 does not support them), and
`kosli snapshot azure` documents nothing about enumerating slots, so staging would likely be
invisible to Kosli.

**The two deploy jobs share a composite action, and are two jobs rather than a matrix.**
`.github/actions/deploy-appservice` holds download → OIDC login → deploy → smoke test; the
jobs differ in `needs` and `environment`, neither of which can be driven from a matrix value,
so a matrix would not have worked. A consequence: both deploy jobs now run
`actions/checkout` (a local composite action is unreachable without one), where the production
job previously had none. That is fingerprint-safe — the only tracked file under `deploy/` is
`.kosli_ignore`, and the artifact already carries it byte-identical because the upload sets
`include-hidden-files: true` — but it does mean the deployed content is no longer *only* what
the artifact contains, so anything new tracked under `deploy/` has to stay identical to what
was fingerprinted.

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

**The approval is attested before the policy assert, in the same job.**
`production-readiness.yml` requires `release-approval`, so the order matters. It also means the action fails the job outright if the environment has no required
reviewers: there is no approval entry to read, which is the correct outcome — an unprotected
environment cannot produce evidence of a human decision.

**The release gate runs after the approval, not before it.** The `release-gate` job sits on
the protected `production-release` environment, so approving it only lets the job *start*;
the job then runs `kosli assert artifact --environment`. That ordering is the whole
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

**`deploy/build-time.txt` exists to make each build its own artifact.** The JAR is
byte-reproducible - `project.build.outputTimestamp` is pinned in the POM, and Spring Boot's
parent propagates it into the repackaged jar - so two commits with identical compiled output
fingerprinted the same and collapsed into one artifact in Kosli. Observed: `orders-api` was
`92fbd0c4…` across five different commits. An ISO timestamp written at stage time fixes that.
The cost is that a *re-run* of the same commit now also produces a new fingerprint and a second
artifact on the trail; `git rev-parse HEAD` instead would be per-commit stable, at the price of
no longer distinguishing rebuilds. `.kosli_ignore` does not exclude the file, so it is hashed
on both sides and the environment snapshot still matches.

**The whole `deploy/` directory is uploaded, not a file list.** It is the directory that was
fingerprinted, and the deploy job has no checkout - only the artifact - so anything missing from
the upload is missing from wwwroot and breaks the fingerprint match. A file list needed editing
every time the directory gained a file, which is how `.kosli_ignore` came to be missing once
already.

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
- **`anchore/sbom-action@v0`'s `path` input always scans as `dir:<path>`, so it fails on a
  single file.** Observed on the first live SBOM run (2026-08-26, all three legs): pointed at
  `deploy/app.jar` (or a mobile zip), it errored `could not determine source` after trying
  only `oci-dir` and `local-directory` - both directory-shaped providers, because the action
  had already prefixed the path with `dir:` before handing it to syft, which restricts which
  source providers even get tried. `file` is never one of them. Fixed by installing syft with
  the `anchore/sbom-action/download-syft@v0` sub-action instead and calling `syft <path> -o
  cyclonedx-json=<file>` directly in a `run:` step - a bare path with no scheme prefix lets
  syft's own source auto-detection reach `file`. If a future step ever needs to scan a
  directory (not a single artifact file) with `anchore/sbom-action@v0`, that one already
  works as documented; the failure is specific to pointing `path` at one file.
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
- **`KOSLI_DRY_RUN=true` also breaks the peer review step, not just the gates.** The `trail`
  job's `kosli attest pullrequest github` no-ops in dry-run mode (nothing is written), so the
  `backend` job's later `kosli get attestation pull-request` finds nothing on that trail and
  the step fails outright — this now breaks rehearsing the *build*, where before it didn't:
  the old script hit the GitHub API directly and never touched Kosli until the final
  (harmless, dry-run-safe) `evaluate input`/`attest decision` calls.
- **A `KOSLI_*` env var configures every Kosli command that has the matching flag, not just
  the ones that meant to set it.** `KOSLI_FINGERPRINT`, set as a job-level env var in "Attest
  the backend" so later steps can `--fingerprint "$KOSLI_FINGERPRINT"` the same artifact, got
  picked up by `kosli get attestation` too even though that call never mentions
  `--fingerprint` - `get attestation` treats `--trail` and `--fingerprint` as mutually
  exclusive, so it failed with `only one of --trail, --fingerprint is allowed`. This broke a
  real live run (see State, above). Fixed at the time by clearing it for that one step:
  `env: {KOSLI_FINGERPRINT: ""}`. Moot since 2026-08-26: the `get attestation pull-request`
  call now lives in its own `peer-review` job (see the design decision above), which never
  sets `KOSLI_FINGERPRINT` in the first place, so there is nothing to clear any more - but
  worth remembering the shape of this failure mode for the next `kosli` command added to a job
  that already exports a `KOSLI_*` variable for a different purpose.
- **Re-running the release gate job re-attests the same approver.** The approvals API returns the
  run's approvals, and a re-run does not create a new one, so a blocked release that is
  re-reported and re-run records the original approval again. Fine here; worth knowing before
  anyone reads the trail as "approved twice".
- **The deploy job uses the `production` environment, the release gate uses
  `production-release`.** Two environments on purpose: the halt belongs to the gate, and
  `production` carries the deployment URL that shows up in the Actions UI.
- **`staging` must be left unprotected.** Required reviewers on it would put a second human
  halt before the integration tests, which is not what point 3 is about.
- **A job with `environment:` gets an environment-scoped OIDC subject**, not the branch one,
  so `deploy-staging` needs its own federated credential
  (`repo:<repo>:environment:staging`) or `azure/login` fails. `setup-github-oidc.sh` creates
  all three subjects; re-run it after adding an environment. It also grants Contributor on
  both resource groups, so run `infra/deploy.sh staging` **before** it — a role assignment on
  a resource group that does not exist fails.
- **This org sends the *immutable* OIDC subject format**, and it is not rename-proof.
  Observed on the first `deploy-staging` run (2026-08-25, run 32835421019): GitHub presented
  `repo:kosli-dev@60883186/azure-java-appservice-mobileapp-demo@1341642300:environment:staging`
  and Entra rejected it with `AADSTS700213`, because the credential said
  `repo:kosli-dev/azure-java-appservice-mobileapp-demo:environment:staging`. The immutable
  format embeds the numeric org and repo IDs *alongside* the names, so a rename breaks it
  exactly like the name-based one - the pre-rename `gha-immutable-environment-production`
  credential was dead too, which would have failed the production deploy a few jobs later.
  Which format GitHub sends is an org setting, so `setup-github-oidc.sh` now creates both for
  each of the three claims (six credentials), and needs `gh` authenticated to read the IDs.
  After any repository or organisation rename, re-run it and delete the old-name credentials.
  The tell is `AADSTS700213` quoting a subject with `@<id>` in it.
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
the five custom types, the `peer-review` control, and both policies). **Controls is a beta
feature that Kosli has to enable for `kosli-public`** before `create control` or the
`peer-review` control decision step in `ci-build.yml` will do anything but fail — confirmed
disabled as of 2026-08-25 (`kosli list controls --org kosli-public` → "Controls is not
enabled for this organization"). Enable the Sonar integration in the
Kosli app (org-level) and put its webhook URL/secret on the SonarCloud project; secret
`SONAR_TOKEN` for the scan step, and turn off SonarCloud's Automatic Analysis for the project.
Add required reviewers to the `production-release` GitHub environment, or the release never
halts; leave `staging` unprotected. Azure: `infra/deploy.sh` and `infra/deploy.sh staging`,
then `infra/setup-github-oidc.sh` (with `GITHUB_REPO` set to the current repo name), which
prints the three `AZURE_*` secrets; set vars `AZURE_WEBAPP_NAME`, `AZURE_RESOURCE_GROUP`,
`AZURE_WEBAPP_NAME_STAGING` and `AZURE_RESOURCE_GROUP_STAGING`. Optional vars
`MUTATION_THRESHOLD`, `KOSLI_DRY_RUN`, `REPORT_AZURE_ENV` tune the demo without code changes —
`MUTATION_THRESHOLD=70` gives a clean run.

## Still to build (point 4 of the customer scenario)

- **Real mobile builds** — `make apk` in a container replacing the Android zip, then
  `make ipa` on a macOS runner. Xcode cannot be containerised, so unlike `scan` and `apk` it
  will not run on Linux.
- **A real integration suite** — the pipeline reports one of two canned runs under
  `integration-tests/`. A suite that actually drives the deployed backend from the mobile
  clients replaces one workflow step; the type, the template and the gate stay as they are.
- **Point 4** — deployment gate: mostly live now. Both environments are snapshotted (the
  workflow is matrixed over the two resource groups), `secure-development` is attached to
  both and `production-readiness` to production. What remains is the demo story around it: an
  unrelated app running next to `orders-api` that the policy has to allow explicitly (an
  nginx container is planned, exempted by `matches(artifact.name, ...)` in
  `secure-development.yml`), and asserting a snapshot as a gate rather than only reporting it.
  Note `kosli snapshot azure` needs a service-principal **client secret**, not the OIDC login
  the deploy job uses.
