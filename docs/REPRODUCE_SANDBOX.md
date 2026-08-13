# Reproduce the Packmate OpenShift AI DEV → PROD sandbox

Target: a **new ephemeral sandbox** where participants **fork** the canonical repository,
ClickOps the DEV Data Science Project + Workbench, then run:

```bash
make configure-participant
make verify-demo-fork
make prepare-demo-baseline
make configure-promotion-registry
make preflight
make bootstrap
make verify
```

## Fork-first workshop model

- Canonical upstream `Lindagh1/packmate-agent` / release `lab-v2.0.0` is the immutable source.
- `make configure-participant` sets `GIT_REPO_URL` to the **fork** URL; Argo CD Applications follow that fork.
- Promotion PRs stay in the fork. Do not create a new `lab-v2.x` release per sandbox.

Bootstrap deploys **DEV** (`packmate-lab`) from **prebuilt images** (GHCR/Quay/internal
digests) and **prepares PROD** (`packmate-prod`) — namespace, Secret, image-pull
RBAC, Argo CD AppProject/Application, SSO group — **without deploying any PROD
workload**. It does **not** rebuild four images and does **not** redeploy the Llama
model.

## Two environments

| Environment | Namespace | Created by | Contains |
|-------------|-----------|-------------|----------|
| DEV | `packmate-lab` | `make bootstrap` (workloads) | DSP, Workbench, Playground, AI asset endpoints, Pipeline `packmate-ci`, app workloads |
| PROD | `packmate-prod` | `make bootstrap` → `prepare-prod.sh` (prep only) + Argo CD Sync (workloads) | App workloads only — no Workbench, Pipeline, Playground, custom model endpoint |

PROD workloads only ever change through: **Pipeline (validate, DEV) → pull request
in the fork (promote) → merge in the fork → Argo CD Sync (deploy, PROD)**.

## Architecture split

| Layer | Responsibility |
|-------|----------------|
| Participant ClickOps | DSP, Workbench, clone, make targets, Playground (select assets, DEV), Pipeline Start (DEV), promotion PR review/merge, Argo Sync (PROD) |
| Bootstrap automation | Custom endpoints feature, shared-model discovery, MCP, custom model endpoint, backend/frontend, Secrets, Routes, MCP registration, Tekton manifests (DEV) + PROD prep (namespace, Secret, RBAC, Argo manifests, SSO group) |
| Promotion automation | `make promote PIPELINERUN=<name>` (candidate digest → PR) — Git only, never `oc apply` |
| Platform prerequisites | OpenShift AI, Pipelines, OpenShift GitOps, GPU model in `my-first-model` |

## Persist vs ephemeral

**Persistent:** Git repo (including the full digest history of `deploy/overlays/prod/kustomization.yaml`), GHCR/Quay images, manifests, system prompt, docs.
**Ephemeral:** DEV project, Workbench, Secrets (`packmate-llm`, `packmate-prod-llm`), Deployments, Routes, MCP registration, PipelineRuns, Argo CD Applications, custom endpoint objects, PROD namespace.

## Configure

```bash
make configure-participant
make verify-demo-fork
make prepare-demo-baseline
make configure-promotion-registry
make verify-promotion-registry
```

## Commands

```bash
# In Workbench: clone into /opt/app-root/src/packmate-agent (not /opt/app-root/src itself)
make setup-workbench-repository   # optional safe helper
make preflight            # PASS/WARNING/BLOCKED (+ repo branch, RHOAI mirror lightweight)
make bootstrap            # prerequisites + Argo CD reconciles DEV; PROD prep (no overlay oc apply)
make verify-resource-ownership
make rotate-prod-llm-secret   # instructor only when intentional
make verify-python-deps   # in-cluster install against the RHOAI 3.4 mirror (no public PyPI)
make resolve-pipeline-python-image
make render-pipeline      # writes .generated/tekton/packmate-ci.yaml (gitignored)
make validate-pipeline
make prepare-prod          # Re-run PROD prep standalone (idempotent; namespace/Secret/RBAC/Argo only)
make configure-argocd-rbac # SSO group + AppProject "promoter" role, standalone
make verify / verify-dev  # DEV readiness (non-destructive)
make verify-prod          # PROD readiness after an Argo CD Sync
make verify-gitops        # AppProject/Application/RBAC checks
make validate-prod        # Static PROD overlay render checks (offline, no cluster deploy)
make promote PIPELINERUN=<name> # validated candidate → fork promotion PR
make cleanup                # interactive, DEV (packmate-lab) only
```

### Final new-sandbox workflow

1. Provision the OpenShift AI sandbox.
2. Fork `Lindagh1/packmate-agent` on GitHub.
3. Create Data Science Project `packmate-lab`.
4. Create and open the Workbench.
5. Open a terminal.
6. Clone **the fork** into `/opt/app-root/src/packmate-agent`; add canonical as `upstream`.
7. Run `make configure-participant` and `make verify-demo-fork`.
8. Run `make verify-github-write-readiness`.
9. Run `make prepare-demo-baseline`; branch configuration is saved automatically.
10. Run `make configure-promotion-registry` and its verifier.
11. Run `make preflight`, `make bootstrap`, and `make verify-dev`.
12. Run `make verify-demo-fork-live` and `make verify-gitops`.
13. Start Pipeline `packmate-ci` with VolumeClaimTemplate **2 GiB** (rendered defaults use the fork).
14. Promote via PR **in the fork**; Sync `packmate-prod` manually.
15. For a clean room after project deletion: `make discover-packmate-resources` then dry-run `make reset-lab`.

### Why the Pipeline Python digest is not in Git

`openshift/python:3.12-ubi9` resolves to a different immutable digest on each OpenTLC sandbox. Committing one digest causes `manifest unknown` / `ErrImagePull` on the next sandbox. Bootstrap always re-resolves and re-renders from `.tekton/lab/packmate-ci.yaml.tpl` into `.generated/tekton/packmate-ci.yaml`. The RHOAI 3.4 mirror also exposes fewer package versions than public PyPI — Packmate pins `mcp`, `json-repair`, and `pydantic` accordingly.

### Namespace policy

Default: participant creates the DEV Data Science Project in the UI.
If missing, bootstrap prints:

```text
MANUAL STEP REQUIRED:
Create the Data Science Project from the OpenShift AI dashboard.
```

Instructor-only: `ALLOW_CREATE_NAMESPACE=true` (DEV project only — never used for PROD).
PROD namespace creation is always automatic via `prepare-prod.sh` (controlled by `CREATE_PROD_NAMESPACE`, default `true`), never ClickOps.

### Model endpoint (automated, DEV only)

Official lab defaults:

```bash
ENABLE_CUSTOM_ENDPOINTS=true
CREATE_MODEL_CUSTOM_ENDPOINT=true
```

Bootstrap discovers the shared predictor in `my-first-model`, creates the Packmate
custom endpoint in `packmate-lab`, and fails if creation/verification fails.
Participants never run Create endpoint ClickOps. `packmate-prod` never has a custom
model endpoint — `scripts/verify-prod.sh` fails if one is found there. Quote spaced
display/use-case values in `config/sandbox.env` (see `config/sandbox.env.example`).

## Preparing PROD (`prepare-prod.sh`)

Runs automatically from `make bootstrap` when `CREATE_PROD_NAMESPACE=true` or
`CREATE_ARGOCD_APPLICATION=true` (both default `true`). Idempotent; never applies
`deploy/overlays/prod` to the cluster.

```bash
make prepare-prod
```

Creates/labels namespace `packmate-prod` (`packmate.io/environment=prod`, never the
DSP labels), Secret `packmate-prod-llm`, cross-namespace `system:image-puller` RBAC,
Argo CD `AppProject/packmate` + `Application/packmate-prod` (manual Sync, prune off,
self-heal off), the `argocd.argoproj.io/managed-by` namespace label, and — when
`CREATE_ARGOCD_RBAC=true` (default `true`) — the OpenShift group + AppProject
`promoter` role from `scripts/configure-argocd-lab-rbac.sh`.

## Running the Pipeline and promoting (DEV → PROD)

```bash
# Start packmate-ci — workspace "source" MUST use a 2Gi VolumeClaimTemplate,
# never Empty Directory:
oc create -n packmate-lab -f .tekton/lab/packmate-ci-run.yaml

# After it Succeeds and the AI quality gate is PASS:
RUN=$(oc get pipelinerun -n packmate-lab -l tekton.dev/pipeline=packmate-ci \
        --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
make promote PIPELINERUN="$RUN"
```

The script edits only `deploy/overlays/prod/kustomization.yaml` and opens a pull
request to `packmate-v2` — review it, then merge. Argo CD Application `packmate-prod`
then goes **OutOfSync**; Sync it manually (SSO login, prune disabled) to deploy.

## Publish images (instructor, once per version)

1. Actions → **publish-lab-images** → workflow_dispatch **or** push tag `lab-v*`.
2. Copy four digest refs from the job summary.
3. Make each GHCR package **Public**.
4. Distribute refs via `sandbox.env` (out of band).

Internal registry images vanish when the sandbox is deleted; GHCR/Quay do not. Both
`deploy/overlays/dev` and the initial `deploy/overlays/prod` start from the same
published digests; PROD only advances via a promotion PR.

## GitOps absent

See `docs/INSTALL_GITOPS_PREREQUISITE.md` (`GITOPS_OPERATOR_REQUIRED`). Without the
Operator, the Playground and DEV modules still work, but the standard production
path cannot be completed live.

## Safety

- No Secrets in Git
- No `:latest`
- No model redeploy
- No Operator install from lab scripts
- No direct `oc apply -k deploy/overlays/prod` — Argo CD Sync only
- No direct push to the prepared base branch from promotion automation — pull request only
- Destructive cleanup (`make cleanup`) requires typing `DELETE-PACKMATE-LAB` and only ever targets `packmate-lab` (never `packmate-prod`)

## Validated release evidence (2026-07-22, DEV path)

| Item | Value |
|------|-------|
| Tag | `lab-v1.0.0` |
| Workflow | `publish-lab-images` run [29910810996](https://github.com/Lindagh1/packmate-agent/actions/runs/29910810996) **success** |
| GHCR owner | `lindagh1` (packages **public**, linked to repo) |
| Backend | `ghcr.io/lindagh1/packmate-backend@sha256:c10fbeb6fbd63ca478e1b8231ddf874ec7ee1c80663b641d802ffca6e826849f` |
| Frontend | `ghcr.io/lindagh1/packmate-frontend@sha256:d6ade3f968a8e1057cb7e846a6dbded4c0f45f8b1780d16d5dd9d76b55d08305` |
| Weather MCP | `ghcr.io/lindagh1/packmate-weather-mcp@sha256:f4a8dcb5407e3bf9dfbb2e494ccb7fc478a377ce074ef2b3f219b55d57443006` |
| Baggage MCP | `ghcr.io/lindagh1/packmate-baggage-policy-mcp@sha256:17432265c056241b6ce89368f9cd1fe0ff5165d3316ef80116285b78b9d58d1a` |
| Repro namespace | `packmate-repro` (`ALLOW_CREATE_NAMESPACE=true`) |
| preflight / bootstrap / verify | **OK** (SSE + heartbeats on repro Route) |
| PipelineRun | `packmate-ci-validate-20260722-123626` **Succeeded** |
| Quality gate (in Pipeline) | score **0.9559**, scenarios **16**, threshold 0.90, **PASS** |
| Pipeline backend digest | `sha256:d04468d34593a2d9c76f30a318ace2fcbc97e9c4d483b8271497e1dd59a2ca84` (ImageStream `packmate-backend:pipeline` in `packmate-repro` only — live Deployments not auto-promoted) |
| OpenShift GitOps | Installed on this sandbox (`openshift-gitops-operator.v1.21.1`, channel `latest`) |
| Argo CD Application | `packmate-lab` → `packmate-repro`: manual sync **Synced/Healthy**; OutOfSync demo via ConfigMap then re-Synced; controller SA granted namespace `edit` |
| Rollouts / EvalHub | Optional / not configured |

**Not yet independently re-validated on a fresh cluster (documented, not fabricated):**
the `packmate-prod` split — `prepare-prod.sh`, promotion automation, and
`configure-argocd-lab-rbac.sh` — was added
after the run above. `make validate-prod` (offline render checks) and the repository
test suite pass; a full live-cluster DEV→PROD promotion and Sync cycle should be re-run and
logged here (or in `docs/implementation/LAB_ACCEPTANCE_REPORT.md`) before the first
graded class on a new cluster.

### GitOps + portable PROD

Instructor: `INSTALL_OPENSHIFT_GITOPS_OPERATOR=true make instructor-setup` then `make configure-promotion-registry`. PROD overlay must use GHCR digests only — internal OpenShift registry digests are not portable across sandboxes.
