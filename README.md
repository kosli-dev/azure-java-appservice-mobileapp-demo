# Kosli demo — a Java backend and a mobile app

A working demo of Kosli governing two components of the same application, where **every
control a component has to pass is attested to Kosli, and the decision to publish is made by
a Kosli policy** — not by a green pipeline.

| Component | What it is | Flow |
| --- | --- | --- |
| `orders-api` | a Spring Boot service, built for Azure App Service | `orders-api-ci` |
| `mobileorders` | the Mobile Orders app, Android and iOS, scanned from source | `mobileorders` |

Both are then released together, as one order system, through a release process where a
human can start the gate but only Kosli can open it.

| Process | What it is | Flow |
| --- | --- | --- |
| Release | a tag builds the release, an integration test run is reported to it, a policy decides whether it goes out, and only then is it deployed | `order-system-release` |

Between them they cover points 1, 2 and 3 of the customer's demo scenario.

## Point 1 — orders-api (Java on Azure App Service)

| Capability asked for | How it works here | Where to look |
| --- | --- | --- |
| Evaluate the pull request for a peer review | `pull_request` attestation for the raw evidence, plus a `peer-review` custom attestation whose jq rules require two distinct approvers **or** one approver who wrote none of the code | [`scripts/peer_review_attestation.py`](scripts/peer_review_attestation.py), [`scripts/bootstrap_kosli.sh`](scripts/bootstrap_kosli.sh) |
| Import and evaluate a passing SonarQube report | The quality-gate report is imported and attested as a `sonarqube-quality-gate` custom attestation; Kosli's jq rules decide whether the gate passed | [`sonar/`](sonar), [`scripts/sonar_attestation.py`](scripts/sonar_attestation.py) |
| Create a waiver for mutation testing | PIT results are attested with the threshold they are judged against. The score is below threshold on purpose, so the gate blocks — then the failure is waived with a recorded reason | [`scripts/waive_attestation.sh`](scripts/waive_attestation.sh), [`.github/workflows/waive-attestation.yml`](.github/workflows/waive-attestation.yml) |
| Check if this component may be published, and show how the policy is created | `kosli assert artifact --policy publish-gate` in its own pipeline job, against a policy created from a YAML file in this repo | [`kosli/policies/publish-gate.yml`](kosli/policies/publish-gate.yml), [`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml) |

The pipeline builds the service but does not deploy it: the only route to App Service is a
tagged release that cleared the release gate (see [Point 3](#point-3--the-release-process)).
The infrastructure is defined as Bicep in [`infra/`](infra).

## The moving parts

```
kosli/flow-templates/orders-api-ci.yml  orders-api's definition of "done"
kosli/flow-templates/mobileorders.yml   the mobile app's definition of "done"
kosli/flow-templates/order-system-release.yml  a release's definition of "done"
kosli/attestation-types/*.json     JSON Schemas for the custom attestation types
kosli/policies/publish-gate.yml    "may this component be published?"
kosli/policies/release-gate.yml    "may this release go out?"
kosli/policies/prod-deploy-gate.yml  groundwork for the deployment gate (point 4)

src/                               Spring Boot service (a pricing endpoint)
pom.xml                            Java 21, JUnit 5, JaCoCo, PIT mutation testing
sonar/quality-gate-{pass,fail}.json  SonarQube quality-gate reports to import
integration-tests/result-{pass,fail}.json  integration test runs to report to a release
infra/main.bicep                   Linux App Service plan + Java SE web app

mobileorders/{android,ios}/        the mobile app source, scanned by mobsfscan
Makefile                           scan and package the mobile app (Docker, no toolchain)

scripts/bootstrap_kosli.sh         creates the attestation types and the policy
scripts/peer_review_attestation.py collects pull-request review facts
scripts/sonar_attestation.py       imports a SonarQube quality-gate report
scripts/mutation_attestation.py    turns the PIT XML report into attestation data
scripts/waive_attestation.sh       records a waiver (override) with a reason

.github/workflows/ci-cd.yml        orders-api: build → attest → publish gate
.github/workflows/mobileorders.yml  mobileorders: package → scan → attest → publish gate
.github/workflows/release.yml      a tag: build → approval → release gate → publish → deploy
.github/actions/get-github-workflow-approver/  reads back who approved a waiting job
.github/workflows/report-integration-test-result.yml  report a run to a release trail
.github/workflows/pr.yml           fast checks on the pull request
.github/workflows/kosli-bootstrap.yml   run the bootstrap script from the Actions tab
.github/workflows/waive-attestation.yml waive a blocked control from the Actions tab
.github/workflows/report-azure-environment.yml  report what is running in Azure (optional)
```

### Where compliance is decided

Nothing in this repo decides pass or fail. The scripts collect facts; Kosli evaluates them:

| Control | Rule, evaluated by Kosli |
| --- | --- |
| `peer-review` | `.pull_request_url != null` and `(.distinct_approvers >= 2) or (.independent_approval == true)` |
| `sonar-quality-gate` | `.projectStatus.status == "OK"` and no condition with a non-`OK` status |
| `mutation-tests` | `.total_mutations > 0` and `.mutation_score >= .threshold` |
| `unit-tests` | built-in `junit` attestation type |
| `mobile-sast` | no `error`-level SARIF finding, and the report really is SARIF 2.1.0 from mobsfscan — see [the rule](#the-compliance-rule) |
| `integration-tests` | `.total > 0`, `.failed == 0` and `.errors == 0` — a run that fell over is not a pass either |
| `release-approval` | `.state == "approved"` and `.user.login != ""` — a named human approved the release |

Those rules live on the attestation types (see `scripts/bootstrap_kosli.sh`), so they apply
to every component that uses the type — change the rule once, every pipeline is judged by
the new one. The flow template says which controls this component needs; the publish-gate
policy says what it takes to be published.

## Setup

### 1. Kosli

Repository secret:

| Secret | Value |
| --- | --- |
| `KOSLI_PUBLIC_API_TOKEN` | An API token for the `kosli-public` org |

Then run the **Bootstrap Kosli** workflow from the Actions tab (or `./scripts/bootstrap_kosli.sh`
locally with `KOSLI_ORG` and `KOSLI_API_TOKEN` set — the Kosli CLI only recognizes the token
from an env var named `KOSLI_API_TOKEN`, so the workflows map the `KOSLI_PUBLIC_API_TOKEN`
secret onto it). It creates the six custom attestation types and the `publish-gate` and `release-gate`
policies.

> The attestation types are org-level objects. If `kosli-public` already has a type with one
> of these names, run `kosli list attestation-types` first — re-running the bootstrap would
> version that existing type rather than create a new one.

### 2. Azure

```bash
az login
AZURE_WEBAPP_NAME=kosli-orders-api-demo ./infra/deploy.sh
GITHUB_REPO=kosli-dev/azure-java-appservice-demo ./infra/setup-github-oidc.sh
```

The first script creates the resource group, the Linux App Service plan and the Java SE web
app. The second creates an app registration with federated credentials so GitHub Actions can
deploy without a stored password, and prints the three secrets to set.

| Secret | From |
| --- | --- |
| `AZURE_CLIENT_ID` | `setup-github-oidc.sh` output |
| `AZURE_TENANT_ID` | `setup-github-oidc.sh` output |
| `AZURE_SUBSCRIPTION_ID` | `setup-github-oidc.sh` output |

| Variable | Value |
| --- | --- |
| `AZURE_WEBAPP_NAME` | e.g. `kosli-orders-api-demo` |
| `AZURE_RESOURCE_GROUP` | e.g. `rg-kosli-orders-api-demo` |

Optional variables that tune the demo without editing code:

| Variable | Default | Effect |
| --- | --- | --- |
| `MUTATION_THRESHOLD` | `85` | Mutation score the component must reach. The service scores ~76%, so the default blocks the publish gate. Set it to `70` for a clean run. |
| `SONAR_RESULT` | `pass` | Which quality-gate report to import (`pass` or `fail`). |
| `KOSLI_DRY_RUN` | unset | Set to `true` to run the pipeline without sending anything to Kosli. |
| `REPORT_AZURE_ENV` | unset | Set to `true` to enable the scheduled Azure environment reporting. |

GitHub environments gate three jobs: `production-release` the release gate, `production` the
deploy job at the end of the release, and `waivers` the waiver workflow. **Add required reviewers to
`production-release`** — without them the release workflow runs straight through and there is
nothing to halt, which is the whole shape of the release demo. Add them to the other two as
well if you want to show four-eyes approval there.

## Running the orders-api demo

The story is: a change arrives with a proper review and a clean Sonar report, but its tests
are weak — and the component cannot be published until somebody takes responsibility for
that in writing.

**1. Open a pull request, have someone approve it, merge it.**
The merge triggers `CI/CD`. The `pull_request` and `peer-review` attestations are about that
merge commit, so a real (approved) pull request is what makes the peer-review control pass.

**2. Watch the build-and-attest job.**
It creates/updates the flow from `kosli/flow-templates/orders-api-ci.yml`, begins the trail
for the commit, builds the JAR, fingerprints the deployable, and attests: pull request, peer review, unit
tests, SonarQube quality gate, mutation testing. The PIT HTML report and the Sonar report go
to the Kosli Evidence Vault as attachments.

Open the trail in Kosli — `app.kosli.com/kosli-public/flows/orders-api-ci/trails/<sha>` — and
walk the controls: four green, mutation testing red at ~76% against an 85% threshold, with
the surviving mutants listed in the attestation.

**3. The publish gate blocks.**

```
kosli assert artifact --fingerprint <sha256> --policy publish-gate
```

fails, the component may not be published, and the job log prints how to unblock. This is the
answer to "may this component be published?" — and it is the same answer for anyone asking,
whether that is CI, a release manager or an auditor.

**4. Waive it.**
Either in the Kosli UI (open the `mutation-tests` attestation → **Override** → give a
reason), or from the Actions tab with the **Waive an attestation** workflow:

```
trail:       <the commit sha>
fingerprint: <from the build-and-attest job summary>
reason:      Mutation score signed off by QA under ORD-482; tests hardened next sprint
```

Kosli recalculates the trail. The control is now compliant *and* carries the waiver: who
waived it, when, and why. Nothing was deleted or edited — the original failure is still
there, with the waiver attached to it.

**5. Re-run the publish gate.**
Re-run the failed jobs on the CI/CD run. The gate passes, and the component is cleared for
release. Getting it onto App Service is the release process — see
[Point 3](#point-3--the-release-process).

To show the failing-Sonar variant instead, run the CI/CD workflow manually with
`sonar_result: fail`.

## Point 2 — Mobile Orders (Android + iOS)

**Mobile Orders** is scanned for mobile security issues, the scan is attested to Kosli, and
Kosli decides whether the app may be published. Android and iOS, both scanned from source.
Nothing is built yet — see [Next steps](#next-steps-for-the-rest-of-the-scenario).

### How the work is split

| Where | Owns |
| --- | --- |
| `Makefile` | anything that turns source into an artifact — scanning now, building later. No kosli, no API token. |
| `.github/workflows/mobileorders.yml` | everything that talks to Kosli — the trail, the attestations, the gate. |

So the pipeline only ever runs in GitHub Actions. Locally you can scan and package; you
cannot attest or gate.

### Local use

Docker, `make`, `git` and `zip`. **No JDK, Android SDK or kosli CLI** — the scanner runs in a
container, and so will the Android build.

```sh
make                        # list targets
make scan                   # -> build/mobsfscan-android.sarif
make package                # -> build/mobileorders-android.zip
make scan PLATFORM=ios      # -> build/mobsfscan-ios.sarif
make package PLATFORM=ios   # -> build/mobileorders-ios.zip
make clean
```

Every target is per-platform; `PLATFORM` defaults to `android`.

### What the pipeline does

| Step | Where | What the audience sees |
| --- | --- | --- |
| Build | `make package` | the app packaged into `build/` |
| Scan | `make scan` | [mobsfscan](https://github.com/MobSF/mobsfscan) analyses the app and writes SARIF 2.1.0 |
| Attest | `kosli attest artifact` + `attest custom` | the app and its scan land in Kosli as a fingerprinted artifact plus an attestation |
| Evaluate | Kosli | the `mobile-sast` rules run and mark the attestation compliant or not |
| Gate | `kosli assert artifact` | exits 0 or non-zero: may this be published? |

mobsfscan is mobile-specific SAST over Java, Kotlin, Android XML, `Info.plist`, Swift and
Objective-C, with native SARIF output. It needs no account and analyses **source**, which is
why this works before there is any build.

### The compliance rule

`scripts/bootstrap_kosli.sh` creates a custom attestation type, `mobile-sast`, with three jq
rules — all must return `true` for a scan to be compliant:

| Rule | Why |
| --- | --- |
| no `error`-level results | the security bar; `warning` and `note` pass |
| `.version == "2.1.0"` | rejects anything that is not SARIF 2.1.0 |
| `.runs[0].tool.driver.name == "mobsfscan"` | stops an unrelated tool's clean report from satisfying a mobile-SAST requirement |

The severity rule is more careful than it looks:

```jq
[.runs[] | .tool.driver.rules as $rules | .results[]
 | (.level // $rules[.ruleIndex].defaultConfiguration.level // "warning")]
| any(. == "error") | not
```

SARIF's `level` is **optional on a result**: when absent the effective level comes from the
rule's `defaultConfiguration`, and failing that the spec default of `warning`. mobsfscan
omits it on a good number of results, so the obvious `.level == "error"` test silently
ignores them.

The flow template requires the attestation on the **artifact** rather than the trail, because
the scan is a property of the app, not of the build.

Both platforms are in **one** flow with one artifact each, so a trail is compliant only when
both have been attested. That is why they are one workflow with a platform matrix rather than
two workflows — a path-filtered per-platform workflow would leave trails permanently missing
an artifact. `begin trail` gets its own job so the two matrix legs cannot race creating the
same trail.

Each leg asserts its own artifact, which answers "may this platform build be published".
Whether *both* platforms are present is trail compliance, and that is what the deployment gate
will check at point 4. `mobileorders` does not use the `publish-gate` policy: that policy names
the orders-api controls, so `kosli assert artifact` on flow-template compliance is the gate
here.

### Caveats

- **Neither app compiles, and nothing checks that they do.** There is no Gradle build and no
  Xcode project, so `androidx.appcompat` is an unresolved import and the iOS source is loose
  Swift files rather than a buildable target. mobsfscan is pattern-based and does not care.
- **The artifacts are zips of the source**, not an APK and an IPA. They exist so the
  fingerprint-and-gate half of the pipeline is real from the start.
- **`minSdkVersion=30` and the `<uses-sdk>` element are scanner-driven**, not app
  requirements — mobsfscan raises error-level findings without them.
- **There is no failing case yet.** The app is secure, so the gate always passes. Showing it
  block needs a commit or PR that introduces a weakness.
- **Nothing validates the jq rules automatically.** They were checked by hand with `jq`
  against real `make scan` output, but a later edit's breakage is first seen in a workflow run.
- iOS needed no tuning to pass — unlike the Android manifest, its 5 findings are all `note`.
  `NSAppTransportSecurity` is left empty on purpose: ATS defaults are secure, and adding
  `NSAllowsArbitraryLoads` is what would trip the scanner.
- `com.kosli.mobileorders` becomes the Play Store application id if this is ever built for real.

## Point 3 — the release process

Both components are released together as the order system. A release is a Kosli trail named
after the git tag, in the `order-system-release` flow, and it is compliant only once all
three artifacts have been attested to it **and** an integration test run across them has been
reported and judged clean.

| Step | What you do | What happens |
| --- | --- | --- |
| 1 | `git tag v0.0.1 && git push origin v0.0.1` | The **Release** workflow rebuilds the backend and both mobile packages from the tagged commit, attests all three to the release trail, and stops at the `release-gate` job, which is waiting on the protected `production-release` environment. |
| 2 | Run **Report integration test result** with tag `v0.0.1` and result `pass` or `fail` | One of the two canned runs under `integration-tests/` is attested to the trail as `integration-tests`. The workflow always succeeds — it reports facts. Kosli evaluates them. |
| 3 | Approve `release-gate` in *Review deployments* | The job records **who approved it** to the trail, then runs `kosli assert artifact --policy release-gate`. If the integration test run was never reported, or was reported as failing, the gate fails and nothing is published or deployed. |
| — | nothing | Once the gate opens: the GitHub release is published, and then the exact JAR the gate approved is deployed to App Service and smoke-tested. |

The point of step 3 is that pressing continue is **not** the decision. The approval only lets
the job start; what the job does is ask Kosli. So the demo has two distinct failure modes to
show:

```bash
# approve without reporting anything -> blocked: the trail is missing integration-tests
# report `fail`, then approve       -> blocked: .failed == 0 and .errors == 0 are false
# report `pass`, then approve       -> published, deployed, smoke-tested
```

Reporting again adds another attestation to the trail rather than replacing it, and Kosli
judges the latest — so after a blocked release you re-report as `pass` and re-run the
`release-gate` job, with both reports left on the trail as evidence.

### Who pressed continue

`github.actor` is whoever pushed the tag, not whoever approved the release, so the approver
is read back from the run's approvals API by
[`.github/actions/get-github-workflow-approver`](.github/actions/get-github-workflow-approver)
and attested to the trail as `release-approval`. The flow template requires it, so a release
trail carries the name of the person who let it through next to the machine controls — and
`kosli attest`, not the Actions log, is where that lives.

The gate job attests the approval *before* asserting the policy, since the policy requires
the trail to be compliant and the template requires the approval.

### Publish, then deploy

The GitHub release is published *before* the deploy, and the deploy job downloads the same
build the gate approved rather than rebuilding. The published release is the immutable record
of what was approved; deploying is what consumes it, which is what makes re-deploying or
rolling back to `v0.0.1` later a normal operation rather than a re-run of a build.

It also means a failed deploy leaves a published release with production still on the old
version. That is the honest state, and Kosli's environment snapshot — not the GitHub release
— is what says which fingerprint is actually running.

**Nothing else deploys.** `ci-cd.yml` builds, attests and gates the component on every push
to `main`, but a tagged release that cleared the release gate is the only route to the
server.

### What the release contains

```
orders-api            deploy/app.jar, fingerprinted as a directory
mobileorders-android  build/mobileorders-android.zip
mobileorders-ios      build/mobileorders-ios.zip
```

Each is rebuilt from the tagged commit rather than pulled from the CI runs, so the release
trail has provenance of its own for everything it contains. That also means the fingerprints
are those of the release build; they are not guaranteed to equal the ones from the component
pipelines.

### Where the release control lives

`integration-tests` is attested at **trail** level, not on an artifact: it is about the
combination of the components, not any one binary. That is also why
[`kosli/policies/release-gate.yml`](kosli/policies/release-gate.yml) carries no `attestations:`
list the way `publish-gate` does — that list matches attestations on the artifact. The release
gate leans on `trail-compliance: required: true` instead, and the flow template
[`order-system-release.yml`](kosli/flow-templates/order-system-release.yml) is what spells out
the control set.

## Deliberate simplifications

**The SonarQube report is canned.** The reports under `sonar/` have the shape of SonarQube's
`api/qualitygates/project_status` response, and they are imported and evaluated exactly like
a real one — but no Sonar server is contacted, so the demo is fast and deterministic. With a
real SonarQube Cloud or Server project, replace the import step with Kosli's built-in Sonar
attestation, which pulls the quality gate straight from the server:

```bash
kosli attest sonar --name orders-api.sonar-quality-gate \
  --sonar-api-token "$SONAR_TOKEN" --sonar-working-dir .scannerwork
```

That is a one-step change: `kosli attest sonar` is a built-in attestation type, so the flow
template and the policy switch from `custom:sonarqube-quality-gate` to `sonar`.

**Mutation testing does not fail the Maven build.** PIT reports the score and Maven carries
on; the threshold is enforced by Kosli, which is the point — the control and the waiver live
in one place, not in a build file that any developer can edit.

**The publish gate is an `env`-type policy.** Kosli policies are asserted against an
artifact directly (`--policy publish-gate`), an environment, or a flow template. The same
policy file can later be attached to the Azure environment as a deployment gate — see
`kosli/policies/prod-deploy-gate.yml`.

**Rego is an option, not a requirement.** Rules that the policy YAML cannot express (for
example "the approver must not be the author, unless the change is docs-only") can be written
as a Rego policy and evaluated with `kosli evaluate trail --policy publish-gate.rego`. That
command is currently a beta feature, which is why this demo enforces the gate with
`kosli assert artifact` instead.

## Next steps for the rest of the scenario

- **Mobile builds:** `make apk` — a real Android build in a container, so the APK replaces
  the zip; then `make ipa` on a macOS runner, since Xcode cannot be containerised and so,
  unlike `scan` and `apk`, it will not run on Linux.
- **A real integration suite:** the release reports one of two canned runs. Replacing them
  with a suite that actually drives the deployed backend from the mobile clients is a change
  to one workflow step — the attestation type, the flow template and the gate stay as they are.
- **Point 4 (deployment gate):** enable `REPORT_AZURE_ENV`, run the Bootstrap workflow with
  *create environment* checked, and the `prod-deploy-gate` policy starts judging whatever is
  actually running in App Service — including anything that never went through the pipeline.

## Local development

```bash
mvn verify                                                    # build + unit tests
mvn test-compile org.pitest:pitest-maven:mutationCoverage      # mutation testing
mvn spring-boot:run                                           # http://localhost:8080/api/health

curl -s localhost:8080/api/price -H 'content-type: application/json' \
  -d '{"quantity":12,"tier":"GOLD","expedited":false}'
```

For the mobile component, see [Local use](#local-use) — `make scan` and `make package`, both
in Docker.
