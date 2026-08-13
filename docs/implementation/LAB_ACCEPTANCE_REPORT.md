# Lab acceptance report — Packmate v2

**Date:** 2026-07-22 (DEV path acceptance run); **DEV→PROD addendum added 2026-07-23** (see § 12)
**Branch:** `packmate-v2`
**Commit tested (pre-acceptance docs WIP):** `b4a170e` (+ local doc/RBAC fixes committed with this report)
**Verdict (2026-07-22, DEV path only):** **LAB_READY_WITH_MANUAL_VISUAL_CHECKS**
**Verdict (2026-07-23, DEV→PROD scope):** **PROD PROMOTION PATH IMPLEMENTED, PENDING LIVE-CLUSTER RE-VALIDATION** — see § 12 for exactly what was and was not re-checked in this pass.

---

## 13. Addendum — portable Pipeline Python + RHOAI deps (2026-07-30)

| Item | Result |
|------|--------|
| Template | `.tekton/lab/packmate-ci.yaml.tpl` with `__PACKMATE_PIPELINE_PYTHON_IMAGE__` / CLI placeholders as Pipeline param defaults |
| Rendered | `.generated/tekton/packmate-ci.yaml` (gitignored) |
| Resolve | `scripts/resolve-pipeline-python-image.sh` → internal digest of `openshift/python:3.12-ubi9` |
| Deps | `mcp==1.27.2`, `json-repair==0.25.3`, `pydantic==2.13.1` (RHOAI 3.4 cpu-ubi9 x86_64) |
| MCP API | `streamable_http_client` |
| Check | `make verify-python-deps` (in-cluster source of truth) |
| Workbench | `scripts/setup-workbench-repository.sh` clones into `/opt/app-root/src/packmate-agent` |
| Bootstrap | resolve → in-cluster deps → render → validate → apply rendered Pipeline |
| Git identity | `scripts/configure-git-identity.sh` / `make configure-git` (repo-local; no tokens; `gh` optional) |
| Validated PipelineRun | `packmate-ci-6hxnr` (sandbox2571) — all tasks Succeeded; quality **0.9559**; candidate `sha256:93465ee6…`; model uid/gen unchanged |
| Idempotent bootstrap | Second `make bootstrap` keeps PipelineRun count stable; does not recreate model; does not apply PROD/DEV overlays; preserves Secret resourceVersion when data unchanged; leaves `packmate-lab` Synced/Healthy without manual Argo sync |
| Resource ownership | `make verify-resource-ownership` — Argo CD sole owner of Git-tracked DEV/PROD runtime |

Do not commit rendered digests. Participants never hand-edit Tekton YAML or requirements.

| Item | Value |
|------|-------|
| Acceptance namespace | `packmate-acceptance-20260722-1419` |
| Config file | `/tmp/packmate-acceptance-20260722-1419.env` (not committed; via `PACKMATE_CONFIG`) |
| Images | Public GHCR digests (`lab-v1.0.0`) |
| Preserved | `packmate-lab`, `packmate-repro`, `my-first-model` |

### GHCR digests used

| Component | Reference |
|-----------|-----------|
| Backend | `ghcr.io/lindagh1/packmate-backend@sha256:c10fbeb6fbd63ca478e1b8231ddf874ec7ee1c80663b641d802ffca6e826849f` |
| Frontend | `ghcr.io/lindagh1/packmate-frontend@sha256:d6ade3f968a8e1057cb7e846a6dbded4c0f45f8b1780d16d5dd9d76b55d08305` |
| Weather MCP | `ghcr.io/lindagh1/packmate-weather-mcp@sha256:f4a8dcb5407e3bf9dfbb2e494ccb7fc478a377ce074ef2b3f219b55d57443006` |
| Baggage MCP | `ghcr.io/lindagh1/packmate-baggage-policy-mcp@sha256:17432265c056241b6ce89368f9cd1fe0ff5165d3316ef80116285b78b9d58d1a` |

Anonymous `skopeo inspect` on all four: **OK**.

---

## 2. Participant command path

| Check | Result |
|-------|--------|
| Makefile targets `preflight` `bootstrap` `verify` `cleanup` `test` `render` `promote` | Present |
| Guide paths (`playground/system-instructions.md`, `test-prompts.json`, `promote-backend-image.sh`, `sandbox.env.example`) | Exist |
| Secrets in Git | None required; `config/sandbox.env` gitignored |
| `make … CONFIG=` | **Not wired** — scripts use `PACKMATE_CONFIG` or `config/sandbox.env` (documented in guide Pro Tip) |

---

## 3. Acceptance namespace results

| Step | Result |
|------|--------|
| `make preflight` | **OK** (exit 0) |
| `make bootstrap` | **OK** (exit 0) |
| `make verify` | **OK** (exit 0) |
| DSP labels | PASS |
| Weather + Baggage MCP Running | PASS |
| `/health` MCP Routes | HTTP 200 |
| `/mcp` | Endpoint reachable (HTTP 406 on empty POST — expected without MCP session headers) |
| Backend / frontend Running | PASS |
| Frontend Route | HTTP 200 |
| SSE | `started` → heartbeats → `completed` |
| Metrics `packmate_*` | PASS |
| Images | All GHCR digests (no internal `packmate-lab` registry dependency) |

---

## 4. Playground prerequisites (technical)

| Check | Result |
|-------|--------|
| InferenceService `llama-32-3b-instruct` Ready | True |
| `/v1/models` | OK (id `llama-32-3b-instruct`) |
| ConfigMap MCP `Packmate-Weather-MCP` | Present |
| ConfigMap MCP `Packmate-Baggage-Policy-MCP` | Present |
| `playground/system-instructions.md` | Present (50 lines) |
| `playground/test-prompts.json` | 10 prompts |
| Guide steps: project, model, MCP, copy/paste prompt, New chat, View code | Documented |

**UI ClickOps:** `MANUAL_VISUAL_CHECK` (not automated).

---

## 5. Pipeline

| Item | Value |
|------|-------|
| Failed run (RBAC) | `packmate-ci-acceptance-20260722-142535` — build forbidden without `instantiatebinary` |
| Successful run | **`packmate-ci-acceptance-20260722-142839`** |
| Succeeded | **True** |
| clone / test / ai-quality-gate / validate-manifests / build-backend / publish-result | All Succeeded |
| Quality gate | score **0.9559**, scenarios **16**, status **PASS**, threshold 0.90 |
| Backend digest produced | `sha256:a0a658c7ff981e56de4ed796030f6774d77e5e6a2d8a9ffc1cfdba1f9983c767` |
| Live Deployment auto-replaced? | **No** — still GHCR `c10fbeb6…` |
| `packmate-lab` backend | Unchanged (internal digest `c057f9f1…`) |

**Minimal fix applied:** Role `packmate-pipeline` now includes `buildconfigs/instantiate` and `buildconfigs/instantiatebinary` (+ imagestream update verbs). This is required by the current Module 7 Pipeline.

---

## 6. Argo CD

| Check | Result |
|-------|--------|
| Application | `packmate-lab` in `openshift-gitops` |
| Destination | `packmate-acceptance-20260722-1419` |
| Repository | Participant fork (`GIT_REPO_URL`) @ `packmate-v2` — never promote into `Lindagh1/packmate-agent` |
| Automated prune / selfHeal | Absent (manual sync) |
| Sync | Manual → **Synced** |
| Health | **Healthy** |
| `packmate-lab` workloads | Still Running (not pruned) |

---

## 7. Repository tests

| Suite | Result |
|-------|--------|
| Backend pytest | **125 passed** |
| Weather MCP | **6 passed** |
| Baggage MCP | **9 passed** |
| Frontend (Podman node:22) | **26 tests** + build OK |
| Quality gate | **0.9559 PASS** |
| security-check | **PASS** |
| `git diff --check` | Trailing whitespace in guide **fixed** |

---

## 8. Guide module audit (`docs/PARTICIPANT_GUIDE.md`)

| Module | Status |
|--------|--------|
| 0 Before you start | PASS |
| 1 Discover Packmate | PASS |
| 2 Data Science Project | PASS + MANUAL_VISUAL_CHECK |
| 3 Workbench | PASS + MANUAL_VISUAL_CHECK |
| 4 Clone and bootstrap | PASS (PACKMATE_CONFIG tip added) |
| 5 AI asset endpoints | PASS + MANUAL_VISUAL_CHECK |
| 6 Playground | PASS (prereqs) + MANUAL_VISUAL_CHECK |
| 7 Export and compare | PASS + MANUAL_VISUAL_CHECK |
| 8 Industrialized Route | PASS (+ MANUAL_VISUAL_CHECK for browser UX) |
| 9 Pipeline packmate-ci | PASS (after RBAC Role fix) + MANUAL_VISUAL_CHECK for UI Start |
| 10 Argo CD | PASS + MANUAL_VISUAL_CHECK |
| Conclusion / annexes | PASS |
| EvalHub / Rollouts | OPTIONAL_UNAVAILABLE / optional annex |

### Documentation corrections made

1. Trailing whitespace cleanup (`git diff --check`).  
2. Pro Tip: use `PACKMATE_CONFIG` for alternate env files (Makefile has no `CONFIG=`).  
3. Clarify Argo Application name `packmate-lab` vs destination namespace.  
4. Acceptance report (this file) + DOCX assembly plan already present from prior doc work.

### Functional fix required for acceptance (not app logic)

- Tekton Role: allow `buildconfigs/instantiatebinary` so `oc start-build --from-dir` works for participants.

---

## 9. Manual UI checks remaining

- Create DSP / Workbench screenshots  
- Playground: paste prompt, authorize MCP, observe tool calls, View code  
- Pipelines UI **Start** button (CLI PipelineRun validated)  
- Argo CD UI Sync button (CLI sync validated)

---

## 10. Optional limitations

- EvalHub not configured (`EVALHUB_OPTIONAL_NOT_CONFIGURED`)  
- Rollouts optional annex  
- Custom model endpoint is **automated** by bootstrap (`CREATE_MODEL_CUSTOM_ENDPOINT=true`); participants never Create endpoint
- Shared Application name `packmate-lab` retargets destination when bootstrapping another namespace (instructor should use one GitOps destination per class cluster)

---

## 11. Final verdict (2026-07-22, DEV path)

**LAB_READY_WITH_MANUAL_VISUAL_CHECKS**

Technical path (images, bootstrap, verify, SSE, PipelineRun, Argo Sync, tests, quality gate) was validated on a fresh GHCR-only namespace. The evidence predates the current Modules 1–9 guide and the final participant-owned GHCR flow.

---

## 12. DEV→PROD addendum (2026-07-23)

The participant guide is now organized as Modules 1–9 (RHDP, OpenShift AI, workspace, bootstrap, Playground, DEV, CI, promotion, and production). PROD and GitOps automation includes `scripts/prepare-prod.sh`, promotion automation, `scripts/configure-argocd-lab-rbac.sh`, verification scripts, and the Argo CD manifests.

**Re-checked in this documentation pass (2026-07-23, offline/local — no live cluster in this environment):**

| Check | Result |
|---|---|
| `make validate-prod` (offline render of `deploy/overlays/prod`) | **Passed** — no Notebook/Pipeline/PipelineRun/Workbench kinds, no `:latest`, no `packmate-lab` references, `packmate-prod-llm` secretKeyRef present, exactly 4 Deployments, all digest-pinned |
| Backend pytest | **125 passed** (unchanged from § 7) |
| Deterministic AI quality gate | **score 0.9559, PASS** (threshold 0.90; unchanged from § 7) |
| `scripts/security-check.sh` | **All checks passed** |
| Frontend (`npm ci && npm run test -- --run`) / MCP suites | **Not re-run in this pass** — carried forward from § 7 (26 frontend tests, 6 Weather, 9 Baggage); re-run before the next class if the frontend or MCP servers changed |

**Not re-checked in this pass — genuinely pending a live cluster:**

- End-to-end `make bootstrap` on a fresh sandbox confirming `packmate-prod` namespace/Secret/RBAC/Argo objects are created as described in `prepare-prod.sh`.
- A live PipelineRun → Module 8 promotion PR review/merge → Argo CD `packmate-prod` OutOfSync → Module 9 Sync → Synced/Healthy → PROD Route smoke cycle.
- SSO group/`promoter`-role propagation (log out/in) on a real Argo CD instance with `spec.rbac.scopes` patched by `configure-argocd-lab-rbac.sh`.

**Recommendation:** run the current Modules 1–9 procedure end-to-end on a fresh sandbox before the first graded DEV→PROD class. Until then, treat the promotion/Argo-RBAC path as **implemented and offline-validated**, not yet **live-cluster acceptance-tested**.

## Addendum — GitOps dual apps + portable PROD (2026-07-30)

| Item | Result |
|------|--------|
| Root cause of e7442bcc | OLD_SANDBOX_REFERENCE (manifest missing) |
| PROD baseline | `ghcr.io/lindagh1/packmate-backend@sha256:c10fbeb6…` |
| Applications | packmate-lab + packmate-prod under AppProject packmate |
| Participant RBAC | get packmate/*; sync packmate-prod |

## Addendum — Fork-first workshop model (lab-v2.0.0)

| Item | Result |
|------|--------|
| Canonical upstream | `Lindagh1/packmate-agent` @ `packmate-v2` — read-only for demos |
| Writable target | Participant/demo fork (`GIT_REPO_URL`) |
| Safety | `make verify-demo-fork`; promotion emits `BLOCKED_CANONICAL_REPOSITORY_PROMOTION` against upstream |
| Argo CD | Applications use `__GIT_REPO_URL__` / `__GIT_REVISION__` (fork), not hard-coded canonical |
| Release policy | One canonical `lab-v2.0.0`; no release per demonstration |
| Tests | `scripts/tests/test-fork-first-workshop.sh` |

## Addendum — Clean-room deep audit hardening

| Item | Result |
|------|--------|
| Pre-bootstrap fork check | `make verify-demo-fork` — Argo upstream residue = INFO/ACTION |
| Post-bootstrap fork check | `make verify-demo-fork-live` wired into `make verify-gitops` |
| GitHub write readiness | `make verify-github-write-readiness` (askpass / ECONNREFUSED guidance) |
| Repeatable demo baseline | `make prepare-demo-baseline` (fork-only; `demo/packmate-workshop`, config saved automatically) |
| Early no-diff promotion | `BLOCKED_NO_PROMOTION_DIFF` before branch creation when PROD == candidate |
| Residue discovery | `make discover-packmate-resources` (read-only classifications) |
| Safe reset | `make reset-lab` dry-run; destructive needs `CONFIRM_PACKMATE_RESET=packmate-lab-and-prod` |
| Acceptance | `make acceptance-static` / `acceptance-prebootstrap` / `acceptance-postbootstrap` |
| Tests | `scripts/tests/test-deep-audit-hardening.sh` |
| Patch release | Required after this hardening lands on `packmate-v2` beyond `lab-v2.0.0` (do not create yet) |
