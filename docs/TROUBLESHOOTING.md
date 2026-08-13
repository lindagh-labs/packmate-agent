# Troubleshooting

## Lab bootstrap / preflight

| Message | Action |
|---------|--------|
| `MANUAL STEP REQUIRED: Create the Data Science Project` | Create DSP in OpenShift AI UI first (`ALLOW_CREATE_NAMESPACE` is false by default) |
| `BLOCKED` model not Ready | Instructor checks `my-first-model` — do not redeploy from the lab |
| Custom endpoint create/verify failed | Re-run `make bootstrap`; confirm `aiAssetCustomEndpoints=true` and shared Service reachable — do **not** ask participants to Create endpoint |
| Playground missing Packmate Llama / MCP | Hard-refresh Gen AI studio; `make verify` must PASS asset checks |
| Health check timed out after 180s | Inspect Route/deploy; bootstrap retries every 5s and accepts only HTTP 200 |
| Image empty / unreachable | Instructor must publish GHCR/Quay digests into `config/sandbox.env` |
| `GITOPS_OPERATOR_REQUIRED` | Modules 4, 8, and 9 cannot run live — see `docs/INSTALL_GITOPS_PREREQUISITE.md` |
| `EVALHUB_OPTIONAL_NOT_CONFIGURED` | Expected unless EvalHub annex is prepared |
| Unquoted spaces in `sandbox.env` | Quote `PACKMATE_MODEL_DISPLAY_NAME` / `PACKMATE_MODEL_USE_CASE` (see example file) |

## unable to parse SM or JSON patch from replicas-patch.yaml

Symptom:

```text
error: trouble configuring builtin PatchTransformer with config:
path: replicas-patch.yaml
unable to parse SM or JSON patch
```

Root cause: one Kustomize `patches:` entry referenced a file containing **several**
strategic merge patch documents (`---`). Newer Kustomize / Argo CD builds reject
that pattern.

Fix: use the native Kustomize `replicas:` transformer (and split other multi-doc
patches into one file per resource, or use `labels:`). Do **not**
`oc apply -k deploy/overlays/dev` or `prod` — Argo CD owns those manifests.

Downstream consequences when preflight/bootstrap cannot render overlays:

- Application/packmate-lab may stay OutOfSync / Missing
- DEV Deployments and Routes absent
- Pipeline/packmate-ci and custom model endpoint not created
- Playground assets not ready

Recover with `make preflight` → `make bootstrap` after the overlay fix is on the
Git revision Argo CD tracks. Do not manually apply the overlays.

## Workbench — `fatal: not a git repository`

Symptom:

```text
fatal: not a git repository (or any of the parent directories): .git
```

Cause: Git was run from `/opt/app-root/src`, which can hold Workbench files **without** being a Git repository. The Packmate repo must live at `/opt/app-root/src/packmate-agent`.

Fix:

```bash
cd /opt/app-root/src
git clone --branch packmate-v2 --single-branch \
  https://github.com/YOUR_GITHUB_USERNAME/packmate-agent.git packmate-agent
cd packmate-agent
git remote add upstream https://github.com/Lindagh1/packmate-agent.git
make configure-participant
make verify-demo-fork
```

If promotion prints `BLOCKED_CANONICAL_REPOSITORY_PROMOTION`, fix `origin` with `git remote set-url origin https://github.com/YOUR_USERNAME/packmate-agent.git`, then run `make configure-participant`.

### BLOCKED_NO_PROMOTION_DIFF / “Nothing to promote”

**Symptom:** PipelineRun Succeeded, but `promote-backend-image.sh` exits non-zero with `BLOCKED_NO_PROMOTION_DIFF` (or historically printed “Nothing to promote” after creating a throwaway branch).

**Cause:** `deploy/overlays/prod/kustomization.yaml` already pins the same backend digest as the Pipeline candidate. There is no Git diff and **no PR**.

**Fix (instructor, disposable fork only — never Lindagh1):**

```bash
make verify-demo-baseline
make prepare-demo-baseline
# The command switches branch and saves matching GitOps/promotion config.
# Start a new PipelineRun from the prepared branch, then re-run Module 8.
```

Do not invent digests. Do not `oc set image`. Do not claim a promotion occurred when digests are identical.

### Pre-bootstrap vs post-bootstrap fork checks

`make verify-demo-fork` must pass before bootstrap. If Applications still point at Lindagh1/packmate-agent, that is **INFO/ACTION**, not failure — bootstrap migrates them.

After bootstrap, `make verify-demo-fork-live` (also invoked by `make verify-gitops`) **fails** if Applications still point upstream.

### Projects deleted but Argo residue remains

```bash
make discover-packmate-resources
make reset-lab   # dry-run
# CONFIRM_PACKMATE_RESET=packmate-lab-and-prod make reset-lab
```

### Git push askpass ECONNREFUSED (VS Code / Cursor)

HTTPS push may fail with `403 Missing or invalid credentials` and askpass `ECONNREFUSED`.

```bash
unset GIT_ASKPASS SSH_ASKPASS VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_IPC_HANDLE
make verify-github-write-readiness
# Options (never put tokens in sandbox.env, Git, scripts, or screenshots):
# A) Fine-grained token at the interactive HTTPS password prompt
# B) Organization-approved git credential helper
# C) SSH remote when a valid key already exists
gh auth login -h github.com -p https -w
```

Do **not** run `git credential store` with a plaintext token from this workshop. Optional fork-only write probe: `CONFIRM_GITHUB_WRITE_PROBE=fork-only make verify-github-write-readiness`.

### Pipeline publish-candidate Pending / PodReadyToStartContainers=False

Often **not** a CNI bug. Check:

```bash
make diagnose-latest-pipelinerun
oc get events -n packmate-lab --field-selector involvedObject.name=<publish-pod>
```

If you see `FailedMount` / `secret "packmate-ghcr-push" not found`:

```text
FAIL    Promotion push Secret missing
DETAIL  publish-candidate cannot start until Secret/packmate-ghcr-push exists
ACTION  make configure-promotion-registry && make verify-promotion-registry
ACTION  Start a new PipelineRun (preserve the failed run as evidence)
```

Earlier tasks (clone…build-backend) succeed because only `publish-candidate` mounts that Secret.

Or: `./scripts/setup-workbench-repository.sh` from an existing clone helper path. Do **not** delete files already present in `/opt/app-root/src`.

## Workbench — target directory exists without `.git`

If `/opt/app-root/src/packmate-agent` exists but is not a Git repo, the setup script stops safely and refuses to overwrite it. Rename/move that directory, then clone again.

## Transient local TLS/CA error during dependency check

A local throwaway venv may fail with a TLS/CA certificate path error. **In-cluster** validation (same Python image as Tekton) is the source of truth. If `make bootstrap` / Pipeline install succeeds, treat the local TLS error as WARN only — do not disable TLS verification and do not add `--trusted-host` workarounds.

## Tekton `packmate-ci` — `manifest unknown` / `ErrImagePull` for Python

Symptom:

```text
manifest unknown
ErrImagePull
image-registry.../openshift/python@sha256:ae2c1317...
```

Cause: a **sandbox-specific** Python ImageStream digest was committed into the Pipeline. Digests rotate between OpenTLC sandboxes.

Fix: do **not** edit Pipeline YAML by hand. Re-run:

```bash
make bootstrap
```

Bootstrap resolves `openshift/python:3.12-ubi9` on the **current** cluster, renders `.tekton/lab/packmate-ci.yaml.tpl`, and applies the generated Pipeline. If the ImageStreamTag rotates later, run `make bootstrap` again.

## Tekton / Workbench — `No matching distribution found for json-repair>=0.30.0`

Cause: the RHOAI 3.4 package mirror exposes **`json-repair==0.25.3`** only. Packmate pins that version; Packmate’s parser uses `json_repair.loads`, which exists in 0.25.3.

Fix: pull latest `packmate-v2` and re-run `make verify-python-deps`. Do **not** widen the pin to public PyPI.

## Tekton / Workbench — `No matching distribution found for mcp>=1.28`

Cause: the RHOAI 3.4 mirror exposes MCP **1.26.0 / 1.27.0 / 1.27.2** only. Packmate pins **`mcp==1.27.2`**.

## ImportError: `streamablehttp_client`

Cause: older MCP code imported the unsupported symbol. Packmate uses the MCP v1 API:

```python
from mcp.client.streamable_http import streamable_http_client
```

Fix: pull latest `packmate-v2` (do not patch imports in the Workbench by hand).

## Tekton `packmate-ci` — wrong workspace type (EmptyDir)

Symptom: **clone** Succeeds, later tasks fail as if the repository is missing; or `requirements-dev.txt` is not found.

Cause: workspace **`source`** was started as **Empty Directory**. Each task gets a fresh empty volume, so clone output is invisible to **test** / **ai-quality-gate** / **build-backend**.

Fix: Start again with **VolumeClaimTemplate**, **2 GiB**, access mode **ReadWriteOnce**. Do not edit Pipeline YAML. Do not delete the failed PipelineRun.

## Tekton `packmate-ci` — `requirements-dev.txt` not found

Symptom:

```text
ERROR: Could not open requirements file: No such file or directory: requirements-dev.txt
```

Task **clone** is green; task **test** fails.

Cause:

1. Backend dependencies live in **`backend/requirements-dev.txt`** (not at repo root).
2. More often: wrong workspace type (see EmptyDir section above).

Fix:

1. Ensure Pipeline scripts use `workingDir: $(workspaces.source.path)/backend` for pytest and the quality gate (rendered from `.tekton/lab/packmate-ci.yaml.tpl`).
2. Re-start the PipelineRun with a **VolumeClaimTemplate** for workspace `source` (**2Gi**, see `.tekton/lab/packmate-ci-run.yaml`), **or**:

```bash
oc create -n packmate-lab -f .tekton/lab/packmate-ci-run.yaml
```

Do not delete the failed PipelineRun; create a new one. Do not copy `requirements-dev.txt` to the repository root. Do not manually edit digests or requirements pins.

## `oc: command not found`

Install the official OpenShift client into `~/.local/bin` from `mirror.openshift.com`.

## OpenShift login issues

Use the console “Copy login command”. Never commit the token.

## Port-forward lost connection

```text
error: lost connection to pod
```

Restart:

```bash
oc port-forward --address 0.0.0.0 -n my-first-model \
  pod/<ready-predictor-pod> 9000:8080
```

Use `--address 0.0.0.0` so Podman containers can reach the host.

## Model inaccessible from compose

Confirm:

```bash
curl -s http://127.0.0.1:9000/v1/models
podman exec <backend> python -c "import urllib.request;print(urllib.request.urlopen('http://host.containers.internal:9000/v1/models').status)"
```

## HTTP 503 credentials

Backend missing `BASE_URL`, `MODEL`, or `LITELLM_API_KEY`.

## Podman Compose DNS / 502 via Nginx

After recreating backend, restart frontend so Nginx re-resolves `packmate-backend`.

## Service port-forward maps to pod port 80

Prefer forwarding the pod container port 8080 directly.

## Argo CD OutOfSync after a promotion merge (expected)

Symptom: Application `packmate-prod` shows **OutOfSync** right after the Module 8
promotion pull request is merged.

This is **expected**, not a fault: merging only changes
`deploy/overlays/prod/kustomization.yaml` in Git. Nothing in the cluster changes
until a human clicks **Sync**. Confirm the digest in the diff matches what you
expect, then Sync (Prune stays disabled; the Application never auto-heals).

If OutOfSync appears **without** a recent merge, check for manual drift:

```bash
oc -n packmate-prod get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.template.spec.containers[0].image}{"\n"}{end}'
git show packmate-v2:deploy/overlays/prod/kustomization.yaml | grep -A2 packmate-backend
```

## Application packmate-lab becomes OutOfSync after bootstrap

Root cause: bootstrap used to `oc apply` Git-tracked DEV runtime resources while
Argo CD Application `packmate-lab` owns the same manifests (`deploy/overlays/dev`).
That dual ownership is removed — bootstrap must **not** apply the DEV overlay.

Fix: update to current `packmate-v2`, run `make verify-resource-ownership`, then
`make bootstrap`. Do **not** paper over the issue with a manual Argo sync as the
standing procedure. Bootstrap waits for Argo CD to reconcile DEV.

## Secret resourceVersion changes on every bootstrap

Root cause: `prepare-prod` / bootstrap re-applied Secrets with `oc apply` even
when data was identical, bumping `resourceVersion`.

Fix: current scripts create-if-missing and no-op when data matches. Ordinary
bootstrap never rotates credentials. Instructor rotation only:

```bash
ROTATE_PACKMATE_PROD_LLM_SECRET=true make rotate-prod-llm-secret
```

Do not repeatedly `oc apply` the Secret to “fix” anything.

## Argo CD remains OutOfSync on PROD ServiceAccounts after a successful Sync

OpenShift automatically adds a generated `*-dockercfg-*` pull Secret and the
matching annotation to every ServiceAccount. These fields do not come from the
Packmate overlay. The `packmate-prod` Application ignores only those generated
entries while continuing to compare the Git-owned `packmate-ghcr-pull` entry.

If all four ServiceAccounts remain OutOfSync, update to the current workshop
branch and rerun `make prepare-prod`, then hard-refresh `packmate-prod`. Do not
remove generated dockercfg Secrets or disable comparison for all
`imagePullSecrets`.

## Argo CD shows "permission denied" / promoter role has no effect after RBAC setup

Symptom: the instructor just ran `make configure-argocd-rbac` (or `CREATE_ARGOCD_RBAC=true`
during `make bootstrap`/`make prepare-prod`), but a participant still cannot see or
Sync `Application/packmate-prod`, or sees no `promoter` actions in the Argo CD UI.

Cause: Argo CD reads OpenShift **group membership from the OAuth token issued at
login time**. Adding a user to `packmate-lab-users` after they already logged in
does not retroactively update their session.

Fix:

1. Participant: **log out** of the Argo CD UI, then **log back in** via OpenShift SSO
   (do not use the local admin account).
2. If the role still does not apply, the instructor may need to reload the RBAC
   scopes:

```bash
oc rollout restart deployment/<argocd-name>-server -n openshift-gitops
```

3. Confirm membership and role are actually in place:

```bash
oc get group packmate-lab-users -o jsonpath='{.users}'
make verify-gitops
```

## Cross-namespace image pull failures (`packmate-prod` cannot pull from `packmate-lab`)

Symptom: after an Argo CD Sync, `packmate-prod` Pods sit in `ImagePullBackOff` /
`ErrImagePull` even though the digest in `deploy/overlays/prod/kustomization.yaml`
is correct.

Cause: this only happens if an overlay/image reference points at the **internal**
OpenShift registry in `packmate-lab` instead of the published GHCR/Quay digest.
The shipped `deploy/overlays/prod` uses public GHCR digests, so this is rare in the
official lab, but can occur if an instructor customizes the overlay to use
internal-registry images.

Fix:

1. Prefer digest-pinned **GHCR/Quay** references in `deploy/overlays/prod` (no
   cross-namespace pull needed).
2. If internal-registry images are required, confirm the cross-namespace
   `system:image-puller` grant from `prepare-prod.sh` is in place:

```bash
oc -n packmate-lab auth can-i get imagestreams/layers \
  --as=system:serviceaccount:packmate-prod:packmate-backend
```

3. If it returns `no`, re-run `make prepare-prod` (idempotent) or grant manually:

```bash
oc -n packmate-lab adm policy add-role-to-user system:image-puller \
  system:serviceaccount:packmate-prod:packmate-backend
```

## PROD Secret `packmate-prod-llm` missing

Symptom: `packmate-backend` in `packmate-prod` is `CrashLoopBackOff` / `503` after
Sync, or `make verify-prod` fails with `Secret packmate-prod-llm missing`.

Cause: Argo CD **never creates or prunes** `packmate-prod-llm` — it is intentionally
outside Git (`ignoreDifferences` on `Application/packmate-prod`) and is only created
by `scripts/prepare-prod.sh` (auto-run from `make bootstrap`, or standalone via
`make prepare-prod`).

Fix:

```bash
LLM_BASE_URL=... LLM_MODEL=... LITELLM_API_KEY=... make prepare-prod
oc -n packmate-prod get secret packmate-prod-llm   # confirm it exists (values not shown)
```

Never recreate this Secret through Git / Argo CD — it must stay a cluster-side,
instructor-managed object so a future Sync can never delete or overwrite it.

## Tekton permissions

Ensure `registry-auth` and `gitops-repo-auth` Secrets exist in the pipeline namespace. No tokens in YAML.

## Rollout blocked / CRD missing

```bash
oc api-resources | grep -i rollout
```

If absent, install Argo Rollouts operator before applying prod overlay Rollout objects.

## Quality gate failed

```bash
.venv/bin/python -m evals.runner --mode deterministic --threshold 0.90
```

Inspect failing scenario evaluator messages; fixtures must stay schema-valid.

## Gen AI Playground shows no MCP servers

1. Confirm Routes for `weather-mcp` and `baggage-policy-mcp`.
2. Confirm admin ConfigMap `gen-ai-aa-mcp-servers` in `redhat-ods-applications` with `https://…/mcp` URLs.
3. Authorize tools in the Playground UI after registration.

## MCP calls fail from backend (`PACKMATE_TOOL_MODE=mcp`)

1. Check `PACKMATE_WEATHER_MCP_URL` / `PACKMATE_BAGGAGE_MCP_URL` end with `/mcp`.
2. `curl` in-cluster Service: `http://weather-mcp:8080/health`.
3. Review NetworkPolicy egress from backend to MCP pods.
4. Increase `PACKMATE_MCP_TIMEOUT_SECONDS` if cold starts are slow.

## EvalHub optional step skipped

Expected when no EvalHub CRD/instance exists. Deterministic gate must still pass. See `evaluations/README.md`.

## Workbench cannot reach model Service

Workbench must run in a project/network that can reach `my-first-model`. Prefer in-cluster URLs over laptop port-forward.

## Public Route chat times out around 60 seconds

Symptoms:

- `POST https://<frontend-route>/api/v1/chat` fails near **~60s** (504 / TLS EOF)
- Same request succeeds from inside the cluster (frontend pod → backend) in 30–90s
- Route already has `haproxy.router.openshift.io/timeout: 180s`
- Nginx `proxy_*_timeout` is already 180s

Root cause on RHDP / AWS Classic Load Balancer sandboxes:

1. The OpenShift router is behind an **AWS Classic ELB** whose default **idle timeout is ~60s**.
2. That idle timeout applies to the whole connection while waiting for the full response body.
3. Raising only the Route HAProxy annotation **does not** change the AWS ELB idle timeout (cluster-wide IngressController / LB setting — out of participant scope).

What Packmate does instead (compatible with the participant guide):

- Keep Route annotation `haproxy.router.openshift.io/timeout: 180s` and Nginx proxy timeouts at 180s.
- **Public UI uses `POST /api/v1/chat/stream` (SSE)** with heartbeats ≤10s so the AWS ELB idle timer never fires during long LLM/tool runs.
- Sync `POST /api/v1/chat` remains for tests, evals, and in-cluster scripts (can still hit ELB idle if called publicly on slow runs).
- Agent loop still caches tools, omits unused profile tool, and forces JSON after weather + baggage.

Verify streaming through the public Route:

```bash
curl -sS -N --max-time 180 \
  -H 'Content-Type: application/json' -H 'Accept: text/event-stream' \
  -X POST "https://$(oc -n packmate-lab get route packmate-frontend -o jsonpath='{.spec.host}')/api/v1/chat/stream" \
  -d '{"message":"Je pars a Rome pendant quatre jours avec un bagage cabine."}' | head -40
```

Expect `event: started` quickly, optional `progress` / `heartbeat`, then `completed` with PackingResponse JSON. Total duration may exceed 60s as long as heartbeats continue.

If heartbeats are missing, check Nginx `proxy_buffering off` for `/api/v1/chat/stream` and response headers `X-Accel-Buffering: no`.

## Public stream ends with `agent_error` (transport OK)

Symptoms:

- SSE shows `started` / `progress` / `heartbeat`, then `event: error` with `agent_error`
- No ELB EOF / 504; heartbeats keep the connection alive
- Same scenario may succeed intermittently

Typical causes on `llama-32-3b-instruct` (Packmate lab):

1. **Multi tool-calls in one assistant turn** — gateway returns 400 (`This model only supports single tool-calls at once`) on the next completion once multi-tool history is present. Fix: process **one** tool call per round and rewrite history accordingly.
2. **Truncated final JSON** — `finish_reason=length` at the completion budget. Fix: higher final `max_tokens`, truncation retry, recover `weather_summary` from tool context when omitted.
3. **Malformed JSON** — missing commas / prose wrappers. Fix: deterministic JSON repair in the parser, then Pydantic validation (never skip validation).
4. **Transient final-generation flakes** — after tools succeed, the model still fails schema/parse a few times, then succeeds on an immediate retry. Packmate applies **at most one** automatic retry for classified `retryable` errors only (not 401/403, not missing LLM config, not user validation, not deterministic baggage outcomes). SSE may show `progress` with `stage=retrying_generation`. Metrics: `packmate_agent_retries_total`, `packmate_agent_retry_success_total`, `packmate_agent_retry_exhausted_total`.

Do **not** disable baggage rules, MCP, or Pydantic validation, and do not return a hardcoded packing list.

Check retry counters:

```bash
oc -n packmate-lab exec deploy/packmate-backend -- \
  curl -sf http://127.0.0.1:8080/metrics | grep packmate_agent_retry
```

Reproduce without logging raw model output:

```bash
oc -n packmate-lab exec deploy/packmate-backend -- python -c '
import asyncio, time
from app.agent.service import AgentService
async def main():
  r = await AgentService().chat("Weekend in Oslo in February, cabin bag only, expect snow.")
  print(r.destination, len(r.packing_items), len(r.baggage_warnings))
asyncio.run(main())
'
```

## GitOps Operator not installed

Symptom: `BLOCKED_GITOPS_OPERATOR_NOT_INSTALLED` or bootstrap fails GitOps check.

Fix (instructor only):

```bash
INSTALL_OPENSHIFT_GITOPS_OPERATOR=true make instructor-setup
make verify-gitops
```

Never install the Community Argo CD Operator. Never share the local Argo CD admin password.

## Argo CD dashboard shows only packmate-prod

Checks:

1. `oc get application packmate-lab -n openshift-gitops`
2. AppProject `packmate` destinations include `packmate-lab` and `packmate-prod`
3. Role policies include `get, packmate/*`
4. User is in OpenShift group `packmate-lab-users`
5. Log out of Argo CD → Log in via OpenShift again → User Info shows the group

## PROD `manifest unknown` / ErrImagePull for packmate-backend

Cause: PROD overlay referenced an OpenShift **internal** registry digest from another sandbox.

Fix: restore the durable GHCR baseline (never `oc set image`). Diagnose:

```bash
./scripts/diagnose-packmate-image-reference.sh \
  --image-reference "<failing-ref>" \
  --source-namespace packmate-lab \
  --target-namespace packmate-prod
```

Expected: `ROOT_CAUSE=OLD_SANDBOX_REFERENCE`. Promote via external GHCR only.
