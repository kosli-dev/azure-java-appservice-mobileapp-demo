# orders-api — Kosli demo: Java backend on Azure App Service

A working demo of Kosli governing a Java component: a Spring Boot service, built and
deployed to Azure App Service by GitHub Actions, where **every control the component has to
pass is attested to Kosli, and the decision to publish is made by a Kosli policy** — not by
a green pipeline.

This covers point 1 of the customer's demo scenario:

| Capability asked for | How it works here | Where to look |
| --- | --- | --- |
| Evaluate the pull request for a peer review | `pull_request` attestation for the raw evidence, plus a `peer-review` custom attestation whose jq rules require two distinct approvers **or** one approver who wrote none of the code | [`scripts/peer_review_attestation.py`](scripts/peer_review_attestation.py), [`scripts/bootstrap_kosli.sh`](scripts/bootstrap_kosli.sh) |
| Import and evaluate a passing SonarQube report | The quality-gate report is imported and attested as a `sonarqube-quality-gate` custom attestation; Kosli's jq rules decide whether the gate passed | [`sonar/`](sonar), [`scripts/sonar_attestation.py`](scripts/sonar_attestation.py) |
| Create a waiver for mutation testing | PIT results are attested with the threshold they are judged against. The score is below threshold on purpose, so the gate blocks — then the failure is waived with a recorded reason | [`scripts/waive_attestation.sh`](scripts/waive_attestation.sh), [`.github/workflows/waive-attestation.yml`](.github/workflows/waive-attestation.yml) |
| Check if this component may be published, and show how the policy is created | `kosli assert artifact --policy publish-gate` in its own pipeline job, against a policy created from a YAML file in this repo | [`kosli/policies/publish-gate.yml`](kosli/policies/publish-gate.yml), [`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml) |

The pipeline also builds and deploys the service to Azure App Service, with the
infrastructure defined as Bicep in [`infra/`](infra).

## The moving parts

```
kosli/flow-template.yml            the component's definition of "done"
kosli/attestation-types/*.json     JSON Schemas for the three custom attestation types
kosli/policies/publish-gate.yml    "may this component be published?"
kosli/policies/prod-deploy-gate.yml  groundwork for the deployment gate (point 4)

src/                               Spring Boot service (a pricing endpoint)
pom.xml                            Java 21, JUnit 5, JaCoCo, PIT mutation testing
sonar/quality-gate-{pass,fail}.json  SonarQube quality-gate reports to import
infra/main.bicep                   Linux App Service plan + Java SE web app

scripts/bootstrap_kosli.sh         creates the attestation types and the policy
scripts/peer_review_attestation.py collects pull-request review facts
scripts/sonar_attestation.py       imports a SonarQube quality-gate report
scripts/mutation_attestation.py    turns the PIT XML report into attestation data
scripts/waive_attestation.sh       records a waiver (override) with a reason

.github/workflows/ci-cd.yml        build → attest → publish gate → deploy
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

Those rules live on the attestation types (see `scripts/bootstrap_kosli.sh`), so they apply
to every component that uses the type — change the rule once, every pipeline is judged by
the new one. The flow template says which controls this component needs; the publish-gate
policy says what it takes to be published.

## Setup

### 1. Kosli

Repository secret:

| Secret | Value |
| --- | --- |
| `KOSLI_API_TOKEN` | An API token for the `kosli-public` org |

Then run the **Bootstrap Kosli** workflow from the Actions tab (or `./scripts/bootstrap_kosli.sh`
locally with `KOSLI_ORG` and `KOSLI_API_TOKEN` set). It creates the three custom attestation
types and the `publish-gate` policy.

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

A GitHub environment named `production` gates the deploy job, and one named `waivers` gates
the waiver workflow — add required reviewers to either if you want to show four-eyes approval.

## Running the demo

The story is: a change arrives with a proper review and a clean Sonar report, but its tests
are weak — and the component cannot be published until somebody takes responsibility for
that in writing.

**1. Open a pull request, have someone approve it, merge it.**
The merge triggers `CI/CD`. The `pull_request` and `peer-review` attestations are about that
merge commit, so a real (approved) pull request is what makes the peer-review control pass.

**2. Watch the build-and-attest job.**
It creates/updates the flow from `kosli/flow-template.yml`, begins the trail for the commit,
builds the JAR, fingerprints the deployable, and attests: pull request, peer review, unit
tests, SonarQube quality gate, mutation testing. The PIT HTML report and the Sonar report go
to the Kosli Evidence Vault as attachments.

Open the trail in Kosli — `app.kosli.com/kosli-public/flows/orders-api-ci/trails/<sha>` — and
walk the controls: four green, mutation testing red at ~76% against an 85% threshold, with
the surviving mutants listed in the attestation.

**3. The publish gate blocks.**

```
kosli assert artifact --fingerprint <sha256> --policy publish-gate
```

fails, the deploy job never starts, and the job log prints how to unblock. This is the
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
Re-run the failed jobs on the CI/CD run. The gate passes, the deploy job runs, and the JAR
lands on App Service. `https://<webapp>.azurewebsites.net/api/health` answers, and
`/api/version` reports the commit the artifact came from.

To show the failing-Sonar variant instead, run the CI/CD workflow manually with
`sonar_result: fail`.

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

- **Point 2 (mobile component):** a second flow, `mobile-app-ci`, with an Oversecured report
  imported as a custom attestation type — same pattern as the Sonar import here.
- **Point 3 (integration tests):** a third flow whose trail references both artifacts by
  fingerprint, attesting the combined integration test run as `junit`.
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
