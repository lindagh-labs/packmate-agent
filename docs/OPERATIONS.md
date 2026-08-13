# Operations

## Lab Makefile

| Target | Purpose |
|--------|---------|
| `make verify-demo-fork` | Pre-bootstrap: fork remotes/config (Argo migration is INFO only) |
| `make verify-demo-fork-live` | Post-bootstrap: Applications must follow the fork |
| `make verify-github-write-readiness` | Distinguish read access vs authenticated write (no tokens printed) |
| `make verify-demo-baseline` | Read-only: current PROD digest vs Pipeline candidate / known-good baseline |
| `make prepare-demo-baseline` | Fork-only demo PROD baseline plus coordinated local config |
| `make discover-packmate-resources` | Read-only residue discovery (STALE_PACKMATE classification) |
| `make reset-lab` | Dry-run Packmate reset; destructive needs `CONFIRM_PACKMATE_RESET=packmate-lab-and-prod` |
| `make preflight` | Cluster/image checks |
| `make bootstrap` | Idempotent prerequisites + Argo CD reconciles DEV; PROD prep (no PROD workload apply/sync); Secrets no-op when unchanged |
| `make prepare-prod` | Standalone, idempotent PROD prep (namespace, Secret, image-pull RBAC, Argo AppProject/Application) |
| `make verify-resource-ownership` | Fail if bootstrap still dual-owns Git-tracked DEV/PROD runtime |
| `make rotate-prod-llm-secret` | Instructor-only Secret rotation (`ROTATE_PACKMATE_PROD_LLM_SECRET=true`) |
| `make configure-argocd-rbac` | Standalone: SSO `groups` scope, OpenShift group, AppProject `promoter` role |
| `make verify` / `make verify-dev` | Non-destructive DEV readiness |
| `make verify-prod` | Non-destructive PROD readiness (after an Argo CD Sync) |
| `make verify-gitops` | AppProject/Application/RBAC checks |
| `make validate-prod` | Offline render checks on `deploy/overlays/prod` (no cluster deploy) |
| `make cleanup` | Interactive DEV (`packmate-lab`) namespace delete only |
| `make test` | Unit tests + quality gate + security-check |
| `make render` | Kustomize render (DEV + PROD overlays) |
| `make promote PIPELINERUN=<name>` | Validated candidate → promotion PR in the fork |

## Environments

| Environment | Namespace | Deployed by | Contains |
|-------------|-----------|-------------|----------|
| DEV | `packmate-lab` | `make bootstrap` | Workbench, Playground, AI asset endpoints, Pipeline `packmate-ci`, app workloads |
| PROD | `packmate-prod` | Argo CD Sync only | App workloads only |

## Promotion and Sync — without the Argo CD admin password

## Fork-first workshop model

- Canonical upstream: `Lindagh1/packmate-agent` (release `lab-v2.0.0`).
- Writable repo: participant/instructor fork (`GIT_REPO_URL`).
- Argo CD Applications use `repoURL=GIT_REPO_URL` and `targetRevision=GIT_REVISION`.
- Promotion opens a PR **inside the fork** only (`BLOCKED_CANONICAL_REPOSITORY_PROMOTION` otherwise).
- Demonstrations do not create tags or GitHub Releases.

Every PROD change is: **Pipeline validates (DEV) → pull request promotes (fork) → merge (fork) →
Argo CD Sync deploys (PROD)**. None of these steps needs the Argo CD local admin
account; operators authenticate to Argo CD with OpenShift SSO and hold only the
AppProject `promoter` role (`get` + `sync` on `Application/packmate-prod`).

**Promote** a validated candidate digest:

```bash
make promote PIPELINERUN=<pipelinerun-name>
```

If the command prints `BLOCKED_NO_PROMOTION_DIFF`, PROD already uses the candidate digest — there is **no** PR to open. Resolve with `make prepare-demo-baseline` before re-running the Pipeline exercise. The command changes only the participant fork and saves its branch configuration. Never invent digests; never change Lindagh1 for a demo.

The script edits only `deploy/overlays/prod/kustomization.yaml` and opens a PR to `PROMOTION_BASE_BRANCH` **in the fork**. Review, then merge in the fork.

**Sync** after merge (Argo CD UI, signed in via OpenShift SSO):

1. Open Application `packmate-prod` — status shows **OutOfSync**.
2. Click **Sync**. Prune and self-heal are disabled by design; nothing else in the namespace is touched.
3. Confirm **Synced** / **Healthy**.

Or, if your `promoter` role covers the Argo CD CLI/API and you prefer scripting the click:

```bash
argocd app sync packmate-prod --grpc-web
argocd app wait packmate-prod --health --grpc-web
```

(Requires an SSO-issued Argo CD auth token — never the local admin password.)

**Verify** after any Sync:

```bash
make verify-prod
```

## Health endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | Liveness |
| `GET /ready` | Readiness (no LLM dependency) |
| `GET /metrics` | Prometheus metrics |

Available on both DEV and PROD Deployments.

## Environment variables

| Variable | Default | Notes |
|----------|---------|-------|
| `BASE_URL` | empty | OpenAI-compatible base URL |
| `MODEL` | empty | Model id |
| `LITELLM_API_KEY` | from Secret | Never in Git. `packmate-llm` (DEV) / `packmate-prod-llm` (PROD) |
| `OTEL_SERVICE_NAME` | `packmate-backend` | |
| `OTEL_TRACES_EXPORTER` | `none` | |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | empty | Optional |
| `PACKMATE_VERSION` | `dev` | |
| `PACKMATE_TOOL_MODE` | `local` | `local` or `mcp` (OpenShift ConfigMap uses `mcp`) |
| `PACKMATE_WEATHER_MCP_URL` | `http://weather-mcp:8080/mcp` | Streamable HTTP |
| `PACKMATE_BAGGAGE_MCP_URL` | `http://baggage-policy-mcp:8080/mcp` | Streamable HTTP |
| `PACKMATE_MCP_TIMEOUT_SECONDS` | `10` | |
| `PACKMATE_MCP_MAX_RETRIES` | `2` | |
| `PACKMATE_STREAM_HEARTBEAT_SECONDS` | `10` | Max silence between SSE frames |

## Chat endpoints

| Endpoint | Response | Notes |
|----------|----------|-------|
| `POST /api/v1/chat` | `application/json` PackingResponse | Sync; keep for tests/evals |
| `POST /api/v1/chat/stream` | `text/event-stream` | Public UI; heartbeats defeat AWS ELB idle ~60s |

Streaming smoke (Compose or port-forward):

```bash
PACKMATE_API=http://127.0.0.1:8000 bash scripts/test-streaming-smoke.sh
```

## Local compose

```bash
podman compose up --build -d
podman compose ps
podman compose logs --no-color
podman compose down
```

## Image builds

```bash
podman build -t packmate-backend:dev -f backend/Containerfile backend
podman build -t packmate-frontend:dev -f frontend/Containerfile frontend
podman build -t packmate-weather-mcp:dev -f mcp-servers/weather/Containerfile mcp-servers/weather
podman build -t packmate-baggage-policy-mcp:dev -f mcp-servers/baggage-policy/Containerfile mcp-servers/baggage-policy
```

## MCP versioning

- MCP servers are Deployments pinned by digest in each overlay (same promotion flow as the backend, though only the backend has a scripted promotion path today).
- They are **not** Argo Rollouts by default; change carefully and rely on deterministic + Playground regression checks.

## GitOps expectations

- DEV Argo demo Application (`packmate-lab`): manual sync, illustrative only.
- **PROD** Application `packmate-prod`: **manual sync always**, prune off, self-heal off, destination `packmate-prod` only.
- PROD images move by digest, only after a merged promotion pull request — never by editing the cluster directly.
- `packmate-prod-llm` Secret is excluded from Sync diffing (`ignoreDifferences`) so it is never pruned or overwritten by Git.

## Incident checklist

1. `/ready` and `/health` (DEV and PROD)
2. Predictor Service endpoints (`my-first-model`)
3. Secret present: `packmate-llm` (DEV) / `packmate-prod-llm` (PROD)
4. Recent Argo CD sync status for `packmate-prod` (`make verify-gitops`, `oc get application packmate-prod -n openshift-gitops`)
5. Quality gate on the last promoted commit
6. If PROD is unhealthy after a promotion: stop, preserve evidence, and correct the desired state through the normal reviewed Git process; do not edit the Deployment directly

## Lab release validation pointers (2026-07-22, DEV path)

- Repro NS: `packmate-repro` (GHCR digests)
- PipelineRun: `packmate-ci-validate-20260722-123626` Succeeded
- Argo Application `packmate-lab` Synced/Healthy (destination `packmate-repro`)
- Do not auto-promote Pipeline digests onto live Deployments

The `packmate-prod` split (`prepare-prod.sh`, promotion automation,
`configure-argocd-lab-rbac.sh`) was added after
this run; `make validate-prod` and the repository test suite pass, but a fresh
live-cluster DEV→PROD promotion and Sync cycle has not yet been re-logged here — see
`docs/implementation/LAB_ACCEPTANCE_REPORT.md` for current status.

## Portable PROD images

Never commit OpenShift internal-registry digests to the shared PROD overlay. Use GHCR promotion via publish-candidate + promote-backend-image.sh.
