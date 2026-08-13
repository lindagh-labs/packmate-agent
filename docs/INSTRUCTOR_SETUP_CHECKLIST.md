# Instructor setup checklist

Use before each Packmate v2 (DEV → PROD) session.

## Operators and platform

- [ ] OpenShift AI 3.4.x Ready (`rhods-operator`)
- [ ] OpenShift Pipelines installed (Module 7)
- [ ] OpenShift GitOps installed (required for Modules 4, 8, and 9)
- [ ] GPU / model serving healthy for `llama-32-3b-instruct`
- [ ] User can create Data Science Projects and Workbenches (DEV only)

## Model

- [ ] InferenceService `llama-32-3b-instruct` Ready in `my-first-model`
- [ ] Service `llama-32-3b-instruct-predictor` exists
- [ ] In-cluster `/v1/models` lists `llama-32-3b-instruct`
- [ ] **No** plan to redeploy the model for Packmate, and no plan to redeploy it into `packmate-prod`

## Images (persistent)

- [ ] GitHub Actions `publish-lab-images` ran for this class version
- [ ] Four packages public on GHCR (or mirrored to Quay)
- [ ] Digest refs ready for `BACKEND_IMAGE`, `FRONTEND_IMAGE`, `WEATHER_MCP_IMAGE`, `BAGGAGE_POLICY_MCP_IMAGE`
- [ ] No `:latest` tags
- [ ] `deploy/overlays/prod/kustomization.yaml` on `packmate-v2` starts from the same published digests (confirm with `make validate-prod`)

## Config pack for participants

- [ ] `make discover-packmate-resources` shows no unexpected STALE_PACKMATE (or reset planned)
- [ ] Participants instructed to **fork** `Lindagh1/packmate-agent` with **packmate-v2** included (not “Copy the main branch only”)
- [ ] `config/sandbox.env` template with `GIT_REPO_URL` placeholder + image digests (distributed out-of-band)
- [ ] `ALLOW_CANONICAL_REPO_PROMOTION=false` (never enable for participants)
- [ ] Participants run `make verify-demo-fork` then after bootstrap `make verify-demo-fork-live`
- [ ] `LITELLM_API_KEY=dummy` (or lab token policy documented)
- [ ] `ENABLE_CUSTOM_ENDPOINTS=true` and `CREATE_MODEL_CUSTOM_ENDPOINT=true` (official lab, DEV only)
- [ ] `ALLOW_CREATE_NAMESPACE=false` (DEV project stays ClickOps)

## PROD namespace, Secret, and Argo CD RBAC (new — DEV→PROD)

- [ ] `CREATE_PROD_NAMESPACE=true`, `CREATE_PROD_SECRETS=true`, `CREATE_ARGOCD_APPLICATION=true`, `CREATE_ARGOCD_RBAC=true` set (or explicitly `false` if you plan to run `make prepare-prod` manually later in the day)
- [ ] `LLM_BASE_URL` / `LLM_MODEL` / `LITELLM_API_KEY` (or `LLM_API_KEY`) set for the `packmate-prod-llm` Secret — never commit these
- [ ] After one smoke `make bootstrap`: namespace `packmate-prod` exists, labeled `packmate.io/environment=prod` (**not** DSP labels)
- [ ] `oc -n packmate-prod get secret packmate-prod-llm` exists (values not shown)
- [ ] `oc -n openshift-gitops get appproject packmate` and `oc -n openshift-gitops get application packmate-prod` exist; `make verify-gitops` passes
- [ ] Argo CD `spec.rbac.scopes` includes `groups`; OpenShift group `packmate-lab-users` exists
- [ ] Decide and document the **fork-first promote path**: each participant forks, sets `GIT_REPO_URL`, runs `make verify-demo-fork`, and merges PRs only in their fork (see `docs/INSTRUCTOR_GUIDE.md`)
- [ ] `gh auth status` succeeds on the Workbench image participants use for Module 8
- [ ] `make verify-github-write-readiness` PASS (or documented manual browser/terminal completion)
- [ ] `make prepare-demo-baseline` creates `demo/packmate-workshop` and saves matching local config
- [ ] Argo CD **local admin password never shared**; break-glass retrieval procedure understood (`docs/INSTRUCTOR_GUIDE.md`) and rotated/disabled after class if used

## Smoke on instructor project

- [ ] `make preflight` → no BLOCKED
- [ ] `SKIP_CONFIRM=true make bootstrap` → DEV Synced/Healthy via Argo CD **and** `=== prepare-prod complete ===` printed
- [ ] Second `make bootstrap` leaves `packmate-lab` Synced/Healthy (no manual Argo sync) and `packmate-prod-llm` resourceVersion unchanged
- [ ] `make verify-resource-ownership` passes
- [ ] `make verify` → OK (DEV)
- [ ] Playground in `packmate-lab` shows Packmate Llama 3.2 3B + both MCP after bootstrap
- [ ] Both MCP tools authorize
- [ ] DEV Frontend Route serves UI
- [ ] Pipeline `packmate-ci` visible (if Pipelines present); one run Started with a **2Gi VolumeClaimTemplate** Succeeds with quality gate PASS
- [ ] `make verify-python-deps` PASSes against the RHOAI 3.4 mirror (`mcp==1.27.2`, `json-repair==0.25.3`)
- [ ] Deployed Pipeline Python image matches `oc get istag python:3.12-ubi9 -n openshift` (no obsolete `ae2c1317…` digest)
- [ ] `.tekton/lab/packmate-ci.yaml.tpl` is tracked; rendered YAML under `.generated/tekton/` is **not** committed
- [ ] Participant clone path documented as `/opt/app-root/src/packmate-agent` (never `/opt/app-root/src` as the repo)
- [ ] `make promote PIPELINERUN=<name>` opens a PR touching only `deploy/overlays/prod/kustomization.yaml`
- [ ] Merge the smoke PR, confirm Argo `packmate-prod` goes OutOfSync, Sync it, confirm Synced/Healthy
- [ ] `make verify-prod` → OK; PROD Frontend Route serves UI

## Day-of

- [ ] Dashboard, OpenShift console, and Argo CD URLs shared
- [ ] Branch `packmate-v2` shared
- [ ] Screenshot fallbacks ready if GitOps/Pipelines flaky
- [ ] Cleanup policy explained (`make cleanup` only after class — DEV only; PROD/Argo/group cleanup is manual, see `docs/INSTRUCTOR_GUIDE.md`)

## Optional (not blocking)

- [ ] EvalHub instance — else `EVALHUB_OPTIONAL_NOT_CONFIGURED`
- [ ] Argo Rollouts / canary annex (`deploy/overlays/prod-canary-annex/`) — annex only

- [ ] `INSTALL_OPENSHIFT_GITOPS_OPERATOR=true make instructor-setup`
- [ ] Argo CD shows packmate-lab and packmate-prod
- [ ] `make configure-promotion-registry` and `make verify-promotion-registry`
- [ ] `make verify-gitops` PASS
- [ ] Participant in `packmate-lab-users`; SSO re-login verified
