# Kosli demo — a Java backend and a mobile app

A working demo of Kosli governing an application built from two components, where **every
control the software has to pass is attested to Kosli, and the decision to publish is made by
a Kosli policy** — not by a green pipeline.

One pipeline, [`ci-build.yml`](.github/workflows/ci-build.yml), runs on every push to `main`
and carries the whole system to production:

```
                 ┌─ backend ──────────── publish gate ─┐
begin the trail ─┼─ mobile (android) ──────────────────┼─ deploy to staging ─ release gate ─ deploy
                 └─ mobile (ios) ──────────────────────┘
```

with the integration test report and the approval landing between the staging deploy and the
release gate.

Everything lands on one Kosli flow, `order-system-ci`, whose trail is the commit:

| Artifact | What it is | Its controls |
| --- | --- | --- |
| `orders-api` | a Spring Boot service, deployed to Azure App Service | peer review, unit tests, SonarQube quality gate, mutation testing |
| `mobileorders-android` | the Mobile Orders Android app | Oversecured scan |
| `mobileorders-ios` | the Mobile Orders iOS app | Oversecured scan |

plus two controls that arrive after the build — the integration test run across the
components, and the human approval — which the release-gate policy requires rather than the
flow template.

Between them they cover points 1, 2 and 3 of the customer's demo scenario.

## Point 1 — orders-api (Java on Azure App Service)

| Capability asked for | How it works here | Where to look |
| --- | --- | --- |
| Evaluate the pull request for a peer review | `pull_request` attestation for the raw evidence, plus a `peer-review` control judged by a Rego policy against that same attestation's data, fetched back from Kosli: two distinct approvers **or** one approver who wrote none of the code | [`kosli/policies/peer-review.rego`](kosli/policies/peer-review.rego) |
| Evaluate a SonarQube quality gate | A real SonarCloud scan runs in CI; SonarCloud attests the quality-gate result straight to the trail via Kosli's built-in `sonar` attestation type, over the webhook configured on the Sonar project | [`sonar-project.properties`](sonar-project.properties), [`.github/workflows/ci-build.yml`](.github/workflows/ci-build.yml) |
| Create a waiver for mutation testing | PIT results are attested with the threshold they are judged against. The score is below threshold on purpose, so the gate blocks — then the failure is waived with a recorded reason | [`scripts/waive_attestation.sh`](scripts/waive_attestation.sh), [`.github/workflows/waive-attestation.yml`](.github/workflows/waive-attestation.yml) |
| Check if this component may be published, and show how the policy is created | `kosli assert artifact` in its own pipeline job, against the flow template; the release gate then asserts a policy created from a YAML file in this repo | [`kosli/flow-templates/order-system-ci.yml`](kosli/flow-templates/order-system-ci.yml), [`kosli/policies/release-gate.yml`](kosli/policies/release-gate.yml) |

Clearing the publish gate puts the service on the **staging** App Service, not the production
one: the production deploy happens at the end of the pipeline, after the release gate (see
[Point 3](#point-3--the-release-process)). The infrastructure is defined as Bicep in
[`infra/`](infra), and each environment gets its own resource group — `kosli snapshot azure`
snapshots a whole resource group, so sharing one would report staging and production into the
same Kosli environment.

## The moving parts

```
kosli/flow-templates/order-system-ci.yml  the system's definition of "done"
kosli/attestation-types/*.json     JSON Schemas for the custom attestation types
kosli/policies/publish-gate.yml    the same controls as a policy (unused: the publish gate
                                   asserts the flow template)
kosli/policies/release-gate.yml    "may this release go out?"
kosli/policies/prod-deploy-gate.yml  groundwork for the deployment gate (point 4)

src/                               Spring Boot service (a pricing endpoint)
pom.xml                            Java 21, JUnit 5, JaCoCo, PIT mutation testing
sonar-project.properties          SonarCloud project key, org, sources and JaCoCo report path
integration-tests/result-{pass,fail}.json  integration test runs to report to a trail
infra/main.bicep                   Linux App Service plan + Java SE web app

mobileorders/{android,ios}/        the mobile app source
oversecured/report-{pass,fail}.json  the Oversecured scan reports (only pass is wired up)
Makefile                           scan and package the mobile app (Docker, no toolchain)

scripts/bootstrap_kosli.sh         creates the attestation types and the policy
scripts/mutation_attestation.py    turns the PIT XML report into attestation data
scripts/waive_attestation.sh       records a waiver (override) with a reason

.github/workflows/ci-build.yml     the pipeline: build → attest → gates → deploy
.github/actions/deploy-appservice/ deploy an approved build to one App Service web app
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
| `peer-review` | Rego policy ([`kosli/policies/peer-review.rego`](kosli/policies/peer-review.rego)), evaluated with `kosli evaluate input` against the trail's own `pull-request` attestation data (fetched back with `kosli get attestation`): a pull request exists, and either two distinct approvers or one who wrote none of the code |
| `sonar-quality-gate` | Kosli's built-in `sonar` attestation type: the SonarQube quality gate must pass |
| `mutation-tests` | `.total_mutations > 0` and `.mutation_score >= .threshold` |
| `unit-tests` | built-in `junit` attestation type |
| `oversecured` | the scan completed, and no `high` or `critical` finding — see [the rule](#the-compliance-rule) |
| `integration-tests` | `.total > 0`, `.failed == 0` and `.errors == 0` — a run that fell over is not a pass either |
| `release-approval` | `.state == "approved"` and `.user.login != ""` — a named human approved the release |

Most of those rules live on the attestation types — the custom ones in
`scripts/bootstrap_kosli.sh`, `sonar` built into Kosli — so they apply to every component that
uses the type: change a custom rule once, every pipeline is judged by the new one.
`peer-review` is the exception: it is a control, judged by
[`kosli/policies/peer-review.rego`](kosli/policies/peer-review.rego) rather than a type's jq
rules. The flow template says which controls the system needs; the two policies say what it
takes to be published and to be released.

## Setup

### 1. Kosli

Repository secret:

| Secret | Value |
| --- | --- |
| `KOSLI_PUBLIC_API_TOKEN` | An API token for the `kosli-public` org |

Then run the **Bootstrap Kosli** workflow from the Actions tab (or `./scripts/bootstrap_kosli.sh`
locally with `KOSLI_ORG` and `KOSLI_API_TOKEN` set — the Kosli CLI only recognizes the token
from an env var named `KOSLI_API_TOKEN`, so the workflows map the `KOSLI_PUBLIC_API_TOKEN`
secret onto it). It creates the four custom attestation types, the `peer-review` control, and
the `publish-gate` and `release-gate` policies.

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
./infra/deploy.sh                 # production
./infra/deploy.sh staging
GITHUB_REPO=kosli-dev/azure-java-appservice-mobileapp-demo ./infra/setup-github-oidc.sh
```

The first script creates the resource group, the Linux App Service plan and the Java SE web
app — once per environment, each in its own resource group. Run it for both before the second
script, which creates an app registration with federated credentials so GitHub Actions can
deploy without a stored password, grants it Contributor on both resource groups, and prints
the three secrets to set.

| Secret | From |
| --- | --- |
| `AZURE_CLIENT_ID` | `setup-github-oidc.sh` output |
| `AZURE_TENANT_ID` | `setup-github-oidc.sh` output |
| `AZURE_SUBSCRIPTION_ID` | `setup-github-oidc.sh` output |

| Variable | Value |
| --- | --- |
| `AZURE_WEBAPP_NAME` | e.g. `kosli-orders-api-demo` |
| `AZURE_RESOURCE_GROUP` | e.g. `rg-kosli-orders-api-demo` |
| `AZURE_WEBAPP_NAME_STAGING` | e.g. `kosli-orders-api-demo-staging` |
| `AZURE_RESOURCE_GROUP_STAGING` | e.g. `rg-kosli-orders-api-demo-staging` |

Optional variables that tune the demo without editing code:

| Variable | Default | Effect |
| --- | --- | --- |
| `MUTATION_THRESHOLD` | `85` | Mutation score the component must reach. The service scores ~76%, so the default blocks the publish gate. Set it to `70` for a clean run. |
| `KOSLI_DRY_RUN` | unset | Set to `true` to run the pipeline without sending anything to Kosli. |
| `REPORT_AZURE_ENV` | unset | Set to `true` to enable the scheduled Azure environment reporting (both environments). |
| `INTEGRATION_TEST_DEFAULT_RESULT` | unset (falls back to `pass`) | Which canned report `deploy-staging`'s auto-triggered **Report integration test result** run sends when nobody picks `pass`/`fail` by hand. Set to `fail` to have the release gate block by default. |

GitHub environments gate four jobs: `production-release` the release gate, `production` the
production deploy, `staging` the staging deploy, and `waivers` the waiver workflow. **Add
required reviewers to `production-release`** — without them the pipeline runs straight
through, there is nothing to halt, and the approval the release gate wants to attest never
exists. Leave `staging` unprotected: the halt belongs to production, and a build only reaches
staging once the publish gate has already passed. Add reviewers to the others as well if you
want to show four-eyes approval there.

## Running the orders-api demo

The story is: a change arrives with a proper review and a clean SonarCloud quality gate, but
its tests are weak — and the component cannot be published until somebody takes
responsibility for that in writing.

**1. Open a pull request, have someone approve it, merge it.**
The merge triggers `CI build`. The `pull_request` and `peer-review` attestations are about
that merge commit, so a real (approved) pull request is what makes the peer-review control
pass.

**2. Watch the build jobs.**
`trail` creates/updates the flow from `kosli/flow-templates/order-system-ci.yml`, begins the
trail for the commit and attests the pull request. Three jobs then run in parallel against
that trail: `backend` builds the JAR, fingerprints the deployable and attests peer review,
unit tests and mutation testing, and the two `mobile` legs package, scan and attest their app.
The PIT HTML report and the Oversecured report go to the Kosli Evidence Vault as attachments. The SonarCloud scan runs as its own step and attests the quality gate to the
same trail itself, over the webhook, once analysis completes — there is no `kosli attest`
call for it, so it can land moments after the job finishes rather than during it.

Open the trail in Kosli — `app.kosli.com/kosli-public/flows/order-system-ci/trails/<sha>` —
and walk the controls: everything green except mutation testing, red at ~76% against an 85%
threshold, with the surviving mutants listed in the attestation.

**3. The publish gate blocks.**

```
kosli assert artifact --fingerprint <sha256> --flow order-system-ci
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

**Mobile Orders** is scanned for mobile security issues by
[Oversecured](https://oversecured.com/), the scan report is attested to Kosli, and Kosli
decides whether the app may be published. Android and iOS.
Nothing is built yet — see [Next steps](#next-steps-for-the-rest-of-the-scenario).

Both apps are artifacts of the same trail as the backend, so a commit is releasable only once
both have been packaged, scanned and found clean.

### How the work is split

| Where | Owns |
| --- | --- |
| `Makefile` | anything that turns source into an artifact — zipping now, building later. No kosli, no API token. |
| `.github/workflows/ci-build.yml` | everything that talks to Kosli — the trail, the attestations, the gates. |

So the pipeline only ever runs in GitHub Actions. Locally you can package; you cannot attest
or gate.

### Local use

`make`, `git` and `zip`. **No JDK, Android SDK or kosli CLI** — and Docker only once there is
a real Android build to containerise.

```sh
make                        # list targets
make package                # -> build/mobileorders-android.zip
make package PLATFORM=ios   # -> build/mobileorders-ios.zip
make clean
```

Every target is per-platform; `PLATFORM` defaults to `android`.

### What the pipeline does

| Step | Where | What the audience sees |
| --- | --- | --- |
| Build | `make package` | the app packaged into `build/` |
| Scan | [Oversecured](https://oversecured.com/) | done outside this pipeline; its report is `oversecured/report-pass.json` |
| Report | `scripts/oversecured_attestation.py` | the report's header and one line per finding, as attestation data |
| Attest | `kosli attest artifact` + `attest custom` | the app and its scan land in Kosli as a fingerprinted artifact plus an attestation |
| Evaluate | Kosli | the `oversecured` rules run and mark the attestation compliant or not |
| Gate | `kosli assert artifact --policy release-gate` | exits 0 or non-zero, at the end of the pipeline: may this go out? |

The report is canned, at the customer's request — see
[Deliberate simplifications](#deliberate-simplifications). Only its header is attested; the
full 3.7 MB report is an attachment in the Evidence Vault, since the jq rules read nothing
else.

### The compliance rule

`scripts/bootstrap_kosli.sh` creates a custom attestation type, `oversecured`, with three jq
rules — all must return `true` for a scan to be compliant:

| Rule | Why |
| --- | --- |
| `.header.scan.status == "completed"` | a scan that did not finish says nothing about the app |
| no `critical` or `high` in `.header.severityCounts` | the security bar; `medium` and `low` pass |
| no `critical` or `high` among `.findings` | the header must agree with the findings it summarises |

```jq
(.header.severityCounts.critical // 0) == 0 and (.header.severityCounts.high // 0) == 0
```

The `// 0` matters: Oversecured omits a severity from `severityCounts` entirely when its count
is zero, rather than reporting it as `0`.

The third rule exists because the attestation data is a projection: the script copies `header`
verbatim and derives `findings` from the same report, so a header that disagrees with the
findings it summarises cannot pass.

The flow template requires the attestation on the **artifact** rather than the trail, because
the scan is a property of the app, not of the build.

Both platforms are artifacts of the **same** trail as the backend, so a commit is compliant
only when both have been packaged, scanned and found clean. There is no separate mobile gate:
whether the mobile apps are present and clean is trail compliance, which the release gate
asserts at the end of the pipeline.

### Caveats

- **Neither app compiles, and nothing checks that they do.** There is no Gradle build and no
  Xcode project, so `androidx.appcompat` is an unresolved import and the iOS source is loose
  Swift files rather than a buildable target.
- **The artifacts are zips of the source**, not an APK and an IPA. They exist so the
  fingerprint-and-gate half of the pipeline is real from the start.
- **The report does not describe these zips.** It is a real Oversecured scan of an Android APK
  (`app.platform: "android"`, `scan.fileName: "file1.apk"`), and the same report is attested to
  both mobile artifacts. Nothing scans this repo's mobile source.
- **The failing report is committed but unused.** `report-fail.json` has 2 high-severity
  findings and does fail the rules; nothing selects it yet, so the control always passes.
- **Nothing validates the jq rules automatically.** All three were checked by hand with `jq`
  against the committed report, but a later edit's breakage is first seen in a workflow run.
- **`minSdkVersion=30`, the `<uses-sdk>` element and the empty `NSAppTransportSecurity` dict
  are historical** — they were added to satisfy mobsfscan, which this demo no longer runs. They
  are harmless, and correct for a real app.
- `com.kosli.mobileorders` becomes the Play Store application id if this is ever built for real.

## Point 3 — the release process

Both components are released together as the order system, from the same commit. The trail is
the commit, in the `order-system-ci` flow, and it is compliant only once all three artifacts
have been attested with their controls, an integration test run across them has been reported
and judged clean, and a named human has approved the release.

| Step | What you do | What happens |
| --- | --- | --- |
| 1 | Merge an approved pull request | **CI build** builds and attests everything — backend and both mobile apps in parallel — clears the publish gate, deploys the build to the **staging** App Service, then auto-triggers **Report integration test result** for the commit, and stops at the `release-gate` job, which is waiting on the protected `production-release` environment. |
| 2 *(optional)* | Run **Report integration test result** by hand with the commit SHA and result `pass` or `fail` | Overrides (or precedes) the auto-triggered run. One of the two canned runs under `integration-tests/` is attested to the trail as `integration-tests`. The workflow always succeeds — it reports facts. Kosli evaluates them. |
| 3 | Approve `release-gate` in *Review deployments* | The job records **who approved it**, then runs `kosli assert artifact --policy release-gate`. If the integration test run was never reported, or was reported as failing, the gate fails and nothing is deployed. |
| — | nothing | Once the gate opens, the exact JAR the gate approved — the same one already on staging — is deployed to the production App Service and smoke-tested. |

The point of step 3 is that pressing continue is **not** the decision. The approval only lets
the job start; what the job does is ask Kosli.

The auto-triggered run in step 1 leaves `result` on its "default" choice, which
`report-integration-test-result.yml` resolves from the `INTEGRATION_TEST_DEFAULT_RESULT` repo
variable (falls back to `pass` if the variable is unset) — see
[Setup](#setup). To walk through the demo's failure modes, run the workflow by hand *before*
approving `release-gate`:

```bash
# do nothing (INTEGRATION_TEST_DEFAULT_RESULT unset) -> auto-reported as `pass` -> deployed
# report `fail` by hand, then approve                -> blocked: .failed == 0 and .errors == 0 are false
# set INTEGRATION_TEST_DEFAULT_RESULT=fail            -> auto-reported as `fail` -> blocked
```

Reporting again adds another attestation to the trail rather than replacing it, and Kosli
judges the latest — so after a blocked release you re-report as `pass` (by hand, with
`result: pass`) and re-run the `release-gate` job, with every report left on the trail as
evidence.

The commit SHA is the trail name, so the integration test workflow needs it as input; the
build job's summary prints it, ci-build.yml's auto-trigger step passes it directly, and it is
the run's own commit.

### Who pressed continue

`github.actor` is whoever merged the pull request, not whoever approved the release, so the
approver is read back from the run's approvals API by
[`.github/actions/get-github-workflow-approver`](.github/actions/get-github-workflow-approver)
and attested as `release-approval` against the artifact being released. The release-gate
policy requires it, so nothing reaches App Service without the name of the person who let it
through sitting in Kosli next to the machine controls — and `kosli attest`, not the Actions
log, is where that lives.

The gate job attests the approval *before* asserting the policy, for the obvious reason.

### What is released

```
orders-api            deploy/{app.jar,build-time.txt}, fingerprinted as a directory
mobileorders-android  build/mobileorders-android.zip  + Oversecured scan
mobileorders-ios      build/mobileorders-ios.zip      + Oversecured scan
```

Both deploy jobs download the JAR the gates approved rather than rebuilding, so the
fingerprint that reaches either App Service is the one Kosli judged. They share
[`.github/actions/deploy-appservice`](.github/actions/deploy-appservice) and differ only in
which web app they target and which gate they wait for. Only the backend is deployed anywhere
— the mobile artifacts exist to be gated, until there are real builds and a store to publish
to.

### The two gates

| Gate | Judges | Against | Runs |
| --- | --- | --- | --- |
| publish gate | the backend's own controls: peer review, unit tests, Sonar, mutation testing | the flow template | right after the build, before anything human happens — and it is what lets the build reach staging |
| release gate | the whole trail, plus the integration test run and the approval | `release-gate` policy | after the approval, as the last thing before the production deploy |

**No policy is involved in the publish gate.** `kosli assert artifact` with neither
`--policy` nor `--environment` asserts the artifact against its flow template, and the
template lists exactly what the build itself produces. Policies are the release gate's
business.

That split is what makes the two gates work at different moments. The publish gate runs
minutes before the integration test result and the approval exist, so a template requiring
them would make the component non-compliant every time. `integration-tests` and
`release-approval` therefore live in [`release-gate.yml`](kosli/policies/release-gate.yml),
which is what turns them into a gate, and in
[`prod-deploy-gate.yml`](kosli/policies/prod-deploy-gate.yml), which judges what is actually
running by the same bar.

Both release controls are attested against the `orders-api` fingerprint rather than the trail,
because a policy's `attestations:` rules match attestations on the artifact being asserted.
The release-gate job already has that fingerprint; the integration test workflow looks it up
with `kosli get artifact order-system-ci:<sha>`.

## Deliberate simplifications

**The Oversecured report is canned**, at the customer's request. `oversecured/report-fail.json`
is a real Oversecured scan supplied by them, with two high-severity findings;
`oversecured/report-pass.json` is the same scan with those two removed. The pipeline attests
the passing one; the failing one is committed but not yet wired up. In a real pipeline the scan
would run against the built APK/IPA and its report would be fetched from Oversecured's API —
the attestation type, the rules and the gate would not change.

**Mutation testing does not fail the Maven build.** PIT reports the score and Maven carries
on; the threshold is enforced by Kosli, which is the point — the control and the waiver live
in one place, not in a build file that any developer can edit.

**The release gate is an `env`-type policy asserted against an artifact.** Kosli policies are
asserted against an artifact directly (`--policy release-gate`), or attached to an environment
and asserted against what is running there — which is how `kosli/policies/prod-deploy-gate.yml`
carries the same controls into production.

**Rego is an option, not a requirement.** Rules that the policy YAML cannot express (for
example "the approver must not be the author, unless the change is docs-only") can be written
as a Rego policy and evaluated with `kosli evaluate trail --policy release-gate.rego`. That
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

- **Wire up the failing Oversecured report:** `oversecured/report-fail.json` is in the repo
  already; it needs a workflow input to select it, the way the integration test result is
  chosen. That is what shows the control blocking.
- **Mobile builds:** `make apk` — a real Android build in a container, so the APK replaces
  the zip; then `make ipa` on a macOS runner, since Xcode cannot be containerised and so,
  unlike `apk`, it will not run on Linux.
- **A real integration suite:** the pipeline reports one of two canned runs. Replacing them
  with a suite that actually drives the deployed backend from the mobile clients is a change
  to one workflow step — the attestation type, the flow template and the gate stay as they are.
- **Point 4 (deployment gate):** enable `REPORT_AZURE_ENV`, run the Bootstrap workflow with
  *create environment* checked, and the `prod-deploy-gate` policy starts judging whatever is
  actually running in App Service — including anything that never went through the pipeline.
  Both `azure-appservice-prod` and `azure-appservice-staging` are snapshotted; only production
  carries the policy, since staging is where a build goes to be tested.

## Local development

```bash
mvn verify                                                    # build + unit tests
mvn test-compile org.pitest:pitest-maven:mutationCoverage      # mutation testing
mvn spring-boot:run                                           # http://localhost:8080/api/health

curl -s localhost:8080/api/price -H 'content-type: application/json' \
  -d '{"quantity":12,"tier":"GOLD","expedited":false}'
```

For the mobile component, see [Local use](#local-use) — `make package`.
