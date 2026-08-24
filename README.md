# Kosli demo — a Java backend and a mobile app

A working demo of Kosli governing an application built from two components, where **every
control the software has to pass is attested to Kosli, and the decision to publish is made by
a Kosli policy** — not by a green pipeline.

One pipeline, [`ci-build.yml`](.github/workflows/ci-build.yml), runs on every push to `main`
and carries the whole system to production:

```
build and attest → publish gate → [integration test report] → approval → release gate → deploy
```

Everything lands on one Kosli flow, `order-system-ci`, whose trail is the commit:

| Artifact | What it is | Its controls |
| --- | --- | --- |
| `orders-api` | a Spring Boot service, deployed to Azure App Service | peer review, unit tests, SonarQube quality gate, mutation testing |
| `mobileorders-android` | the Mobile Orders Android app, scanned from source | mobsfscan SAST |
| `mobileorders-ios` | the Mobile Orders iOS app, scanned from source | mobsfscan SAST |

plus two controls on the trail itself, because they are about the release rather than one
binary: the integration test run across the components, and the human approval.

Between them they cover points 1, 2 and 3 of the customer's demo scenario.

## Point 1 — orders-api (Java on Azure App Service)

| Capability asked for | How it works here | Where to look |
| --- | --- | --- |
| Evaluate the pull request for a peer review | `pull_request` attestation for the raw evidence, plus a `peer-review` custom attestation whose jq rules require two distinct approvers **or** one approver who wrote none of the code | [`scripts/peer_review_attestation.py`](scripts/peer_review_attestation.py), [`scripts/bootstrap_kosli.sh`](scripts/bootstrap_kosli.sh) |
| Evaluate a SonarQube quality gate | A real SonarCloud scan runs in CI; SonarCloud attests the quality-gate result straight to the trail via Kosli's built-in `sonar` attestation type, over the webhook configured on the Sonar project | [`sonar-project.properties`](sonar-project.properties), [`.github/workflows/ci-build.yml`](.github/workflows/ci-build.yml) |
| Create a waiver for mutation testing | PIT results are attested with the threshold they are judged against. The score is below threshold on purpose, so the gate blocks — then the failure is waived with a recorded reason | [`scripts/waive_attestation.sh`](scripts/waive_attestation.sh), [`.github/workflows/waive-attestation.yml`](.github/workflows/waive-attestation.yml) |
| Check if this component may be published, and show how the policy is created | `kosli assert artifact --policy publish-gate` in its own pipeline job, against a policy created from a YAML file in this repo | [`kosli/policies/publish-gate.yml`](kosli/policies/publish-gate.yml), [`.github/workflows/ci-build.yml`](.github/workflows/ci-build.yml) |

Clearing the publish gate is not what puts the service on App Service: the deploy happens at
the end of the pipeline, after the release gate (see
[Point 3](#point-3--the-release-process)). The infrastructure is defined as Bicep in
[`infra/`](infra).

## The moving parts

```
kosli/flow-templates/order-system-ci.yml  the system's definition of "done"
kosli/attestation-types/*.json     JSON Schemas for the custom attestation types
kosli/policies/publish-gate.yml    "may this component be published?"
kosli/policies/release-gate.yml    "may this release go out?"
kosli/policies/prod-deploy-gate.yml  groundwork for the deployment gate (point 4)

src/                               Spring Boot service (a pricing endpoint)
pom.xml                            Java 21, JUnit 5, JaCoCo, PIT mutation testing
sonar-project.properties          SonarCloud project key, org, sources and JaCoCo report path
integration-tests/result-{pass,fail}.json  integration test runs to report to a trail
infra/main.bicep                   Linux App Service plan + Java SE web app

mobileorders/{android,ios}/        the mobile app source, scanned by mobsfscan
Makefile                           scan and package the mobile app (Docker, no toolchain)

scripts/bootstrap_kosli.sh         creates the attestation types and the policy
scripts/peer_review_attestation.py collects pull-request review facts
scripts/mutation_attestation.py    turns the PIT XML report into attestation data
scripts/waive_attestation.sh       records a waiver (override) with a reason

.github/workflows/ci-build.yml     the pipeline: build → attest → gates → deploy
.github/actions/get-github-workflow-approver/  reads back who approved a waiting job
.github/workflows/report-integration-test-result.yml  report a run to a trail
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
| `sonar-quality-gate` | Kosli's built-in `sonar` attestation type: the SonarQube quality gate must pass |
| `mutation-tests` | `.total_mutations > 0` and `.mutation_score >= .threshold` |
| `unit-tests` | built-in `junit` attestation type |
| `mobile-sast` | no `error`-level SARIF finding, and the report really is SARIF 2.1.0 from mobsfscan — see [the rule](#the-compliance-rule) |
| `integration-tests` | `.total > 0`, `.failed == 0` and `.errors == 0` — a run that fell over is not a pass either |
| `release-approval` | `.state == "approved"` and `.user.login != ""` — a named human approved the release |

Those rules live on the attestation types — the custom ones in `scripts/bootstrap_kosli.sh`,
`sonar` built into Kosli — so they apply to every component that uses the type: change a
custom rule once, every pipeline is judged by the new one. The flow template says which
controls the system needs; the two policies say what it takes to be published and to be
released.

## Setup

### 1. Kosli

Repository secret:

| Secret | Value |
| --- | --- |
| `KOSLI_PUBLIC_API_TOKEN` | An API token for the `kosli-public` org |

Then run the **Bootstrap Kosli** workflow from the Actions tab (or `./scripts/bootstrap_kosli.sh`
locally with `KOSLI_ORG` and `KOSLI_API_TOKEN` set — the Kosli CLI only recognizes the token
from an env var named `KOSLI_API_TOKEN`, so the workflows map the `KOSLI_PUBLIC_API_TOKEN`
secret onto it). It creates the five custom attestation types and the `publish-gate` and `release-gate`
policies.

> The attestation types are org-level objects. If `kosli-public` already has a type with one
> of these names, run `kosli list attestation-types` first — re-running the bootstrap would
> version that existing type rather than create a new one.

### 2. SonarCloud

The `sonar-quality-gate` control is Kosli's built-in `sonar` attestation type, fed by a
webhook — not a `kosli attest` call in the pipeline. In the Kosli app, under the org's Sonar
integration, enable it and copy the webhook URL and secret it gives you; add that webhook to
the SonarCloud project (Project Settings > Webhooks), pointing at `kosli-dev_azure-java-appservice-demo`
in the `kosli-dev` organization (edit [`sonar-project.properties`](sonar-project.properties)
if yours differ).

Repository secret:

| Secret | Value |
| --- | --- |
| `SONAR_TOKEN` | A SonarCloud token that can analyze the project |

> Disable SonarCloud's **Automatic Analysis** for this project (Administration > Analysis
> Method). It conflicts with CI-based analysis for the same commit, and it does not carry the
> `sonar.analysis.kosli_*` scanner properties the workflow sets, so the webhook would fire
> without enough context to attest to the right flow/trail/artifact.

### 3. Azure

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
| `KOSLI_DRY_RUN` | unset | Set to `true` to run the pipeline without sending anything to Kosli. |
| `REPORT_AZURE_ENV` | unset | Set to `true` to enable the scheduled Azure environment reporting. |

GitHub environments gate three jobs: `production-release` the release gate, `production` the
deploy job, and `waivers` the waiver workflow. **Add required reviewers to
`production-release`** — without them the pipeline runs straight through, there is nothing to
halt, and the approval the release gate wants to attest never exists. Add them to the other
two as well if you want to show four-eyes approval there.

## Running the orders-api demo

The story is: a change arrives with a proper review and a clean SonarCloud quality gate, but
its tests are weak — and the component cannot be published until somebody takes
responsibility for that in writing.

**1. Open a pull request, have someone approve it, merge it.**
The merge triggers `CI build`. The `pull_request` and `peer-review` attestations are about
that merge commit, so a real (approved) pull request is what makes the peer-review control
pass.

**2. Watch the build-and-attest job.**
It creates/updates the flow from `kosli/flow-templates/order-system-ci.yml`, begins the trail
for the commit, builds the JAR, fingerprints the deployable, and attests: pull request, peer
review, unit tests, mutation testing — then packages and scans both mobile apps and attests
those too. The PIT HTML report and the two SARIF reports go to the Kosli Evidence Vault as
attachments. The SonarCloud scan runs as its own step and attests the quality gate to the
same trail itself, over the webhook, once analysis completes — there is no `kosli attest`
call for it, so it can land moments after the job finishes rather than during it.

Open the trail in Kosli — `app.kosli.com/kosli-public/flows/order-system-ci/trails/<sha>` —
and walk the controls: everything green except mutation testing, red at ~76% against an 85%
threshold, with the surviving mutants listed in the attestation.

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
Re-run the failed job on the CI build run. The gate passes, and the pipeline moves on to the
release gate — see [Point 3](#point-3--the-release-process).

The Sonar quality gate now reflects the real code, not a canned variant. To show it blocking
instead, push a change that trips the SonarCloud quality gate for this project (e.g. a new
bug/vulnerability-level issue, or a coverage drop on new code) — or temporarily tighten the
quality gate's conditions in SonarCloud.

## Point 2 — Mobile Orders (Android + iOS)

**Mobile Orders** is scanned for mobile security issues, the scan is attested to Kosli, and
Kosli decides whether the app may be published. Android and iOS, both scanned from source.
Nothing is built yet — see [Next steps](#next-steps-for-the-rest-of-the-scenario).

Both apps are artifacts of the same trail as the backend, so a commit is releasable only once
both have been packaged, scanned and found clean.

### How the work is split

| Where | Owns |
| --- | --- |
| `Makefile` | anything that turns source into an artifact — scanning now, building later. No kosli, no API token. |
| `.github/workflows/ci-build.yml` | everything that talks to Kosli — the trail, the attestations, the gates. |

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
| Gate | `kosli assert artifact --policy release-gate` | exits 0 or non-zero, at the end of the pipeline: may this go out? |

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

Both platforms are artifacts of the **same** trail as the backend, so a commit is compliant
only when both have been packaged, scanned and found clean. There is no separate mobile gate:
the `publish-gate` policy names the backend's controls, and whether the mobile apps are
present and clean is trail compliance — which is exactly what the release gate asserts at the
end of the pipeline.

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

Both components are released together as the order system, from the same commit. The trail is
the commit, in the `order-system-ci` flow, and it is compliant only once all three artifacts
have been attested with their controls, an integration test run across them has been reported
and judged clean, and a named human has approved the release.

| Step | What you do | What happens |
| --- | --- | --- |
| 1 | Merge an approved pull request | **CI build** builds and attests everything, clears the publish gate, and stops at the `release-gate` job, which is waiting on the protected `production-release` environment. |
| 2 | Run **Report integration test result** with the commit SHA and result `pass` or `fail` | One of the two canned runs under `integration-tests/` is attested to the trail as `integration-tests`. The workflow always succeeds — it reports facts. Kosli evaluates them. |
| 3 | Approve `release-gate` in *Review deployments* | The job records **who approved it** to the trail, then runs `kosli assert artifact --policy release-gate`. If the integration test run was never reported, or was reported as failing, the gate fails and nothing is deployed. |
| — | nothing | Once the gate opens, the exact JAR the gate approved is deployed to App Service and smoke-tested. |

The point of step 3 is that pressing continue is **not** the decision. The approval only lets
the job start; what the job does is ask Kosli. So the demo has two distinct failure modes to
show:

```bash
# approve without reporting anything -> blocked: the trail is missing integration-tests
# report `fail`, then approve       -> blocked: .failed == 0 and .errors == 0 are false
# report `pass`, then approve       -> deployed and smoke-tested
```

Reporting again adds another attestation to the trail rather than replacing it, and Kosli
judges the latest — so after a blocked release you re-report as `pass` and re-run the
`release-gate` job, with both reports left on the trail as evidence.

The commit SHA is the trail name, so the integration test workflow needs it as input; the
build job's summary prints it, and it is the run's own commit.

### Who pressed continue

`github.actor` is whoever merged the pull request, not whoever approved the release, so the
approver is read back from the run's approvals API by
[`.github/actions/get-github-workflow-approver`](.github/actions/get-github-workflow-approver)
and attested to the trail as `release-approval`. The flow template requires it, so a release
trail carries the name of the person who let it through next to the machine controls — and
`kosli attest`, not the Actions log, is where that lives.

The gate job attests the approval *before* asserting the policy, since the policy requires
the trail to be compliant and the template requires the approval.

### What is released

```
orders-api            deploy/app.jar, fingerprinted as a directory
mobileorders-android  build/mobileorders-android.zip  + mobile-sast scan
mobileorders-ios      build/mobileorders-ios.zip      + mobile-sast scan
```

The deploy job downloads the JAR the gates approved rather than rebuilding, so the fingerprint
that reaches App Service is the one Kosli judged. Only the backend is deployed anywhere — the
mobile artifacts exist to be gated, until there are real builds and a store to publish to.

### The two gates

| Gate | Judges | Runs |
| --- | --- | --- |
| `publish-gate` | the backend's own controls: peer review, unit tests, Sonar, mutation testing | right after the build, before anything human happens |
| `release-gate` | the whole trail: both gates' controls, both mobile scans, the integration test run, the approval | after the approval, as the last thing before the deploy |

`publish-gate` deliberately does **not** require `trail-compliance`: it runs before the
integration test and the approval exist, so requiring the whole trail would always block.
`release-gate` is the opposite — it carries no `attestations:` list, because
`trail-compliance: required: true` already requires every control in
[`order-system-ci.yml`](kosli/flow-templates/order-system-ci.yml).

`integration-tests` and `release-approval` sit on the **trail**, not on an artifact: they are
about the release — the combination of the components, and the decision to ship them — rather
than any one binary.

## Deliberate simplifications

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

**`deploy/.kosli_ignore` excludes `logs/`, `*.log` and `*.html`.** `kosli snapshot azure`
fingerprints a zip-deployed web app by unzipping the package and hashing its content exactly
like `kosli fingerprint -t dir` — but Azure/Kudu writes its own files into wwwroot alongside
whatever was deployed (application logs, a default landing page), which would otherwise make
that fingerprint never match the one CI attested for the same jar. `.kosli_ignore` is read by
the same digest code on both sides (shipped in kosli-cli v2.10.16, see
`kosli-dev/server#2270`), so it has to be a real file tracked in `deploy/`, not something the
workflow generates — that's why `.gitignore` uses `deploy/*` plus a `!deploy/.kosli_ignore`
negation rather than ignoring `deploy/` outright.

## Next steps for the rest of the scenario

- **Mobile builds:** `make apk` — a real Android build in a container, so the APK replaces
  the zip; then `make ipa` on a macOS runner, since Xcode cannot be containerised and so,
  unlike `scan` and `apk`, it will not run on Linux.
- **A real integration suite:** the pipeline reports one of two canned runs. Replacing them
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
