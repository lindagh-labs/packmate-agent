# Technical decisions

## Phase 5 — Evaluations

- Deterministic fixtures are the CI source of truth; live mode is opt-in only.
- Weighted scoring favors structure, baggage safety, and privacy.
- Invalid-date scenarios assert schema rejection rather than forcing a valid PackingResponse.
- Evidence payloads redact medical/message/token-like keys.
- Evaluation reports under `backend/evals/reports/` are gitignored except `.gitkeep`.

## Phase 6 — Observability

- Prometheus metrics always enabled via `/metrics`.
- OpenTelemetry tracing is optional and disabled by default (`OTEL_TRACES_EXPORTER=none`).
- Spans and metrics never include user messages, medical notes, or LLM payloads.
- `/ready` does not depend on external LLM availability.

## Phase 7 — OpenShift manifests

- Kustomize overlays for packmate-dev and packmate-prod.
- LLM credentials via Secret reference packmate-llm/LITELLM_API_KEY only.
- Images use PLACEHOLDER tags (never latest); digests expected in prod GitOps updates.
- Public Route targets frontend only; backend remains ClusterIP.

## Phase 10 — Argo Rollouts (prod backend)

- Prod replaces `Deployment/packmate-backend` with a canary `Rollout`; dev keeps a plain Deployment.
- Stable Service remains `packmate-backend` (frontend Nginx upstream unchanged); canary Service is `packmate-backend-canary`.
- Canary steps: 10% → smoke analysis → pause → 50% → smoke analysis → pause → 100%.
- Optional `AnalysisTemplate/packmate-backend-prometheus` is shipped but not wired into default steps.
- `scripts/canary-demo.sh` supports the optional canary demonstration and does not apply participant runtime overlays.

## Phase 11 — Security

- `scripts/security-check.sh` runs offline checks (tags, privileges, non-root, secrets-in-git, cluster-admin, key patterns).
- OAuth proxy component stays optional and disabled by default in overlays.
- Optional dev `LimitRange` example documents namespace default requests/limits; not enabled unless added to dev kustomization.

## OpenShift AI recenter — MCP transport

- Cluster audit (OAI Self-Managed **3.4.2**): no MCP-named CRDs; Playground registration is the platform ConfigMap `gen-ai-aa-mcp-servers` in `redhat-ods-applications` with JSON `{url, description}` per server key.
- That ConfigMap was **absent** at audit time; registration remains a **cluster-admin / manual** step.
- Packmate MCP servers implement **Streamable HTTP** via the official Python MCP SDK (`mcp.server.fastmcp.FastMCP.streamable_http_app()`), endpoint path **`/mcp`**.
- SSE (`sse_app`) is not the primary Playground path; it remains available in the SDK for inspectors/debug but is not exposed as a separate Route in Packmate manifests.
- Traveler profile stays **in-app only** (no shared MCP) to avoid leaking sensitive notes.

## OpenShift AI recenter — backend tool modes

- `PACKMATE_TOOL_MODE=local` (default): unit tests and laptop/Workbench local runs use in-process Python tools.
- `PACKMATE_TOOL_MODE=mcp`: OpenShift deployments call `weather-mcp` and `baggage-policy-mcp` via Streamable HTTP; business logic is not duplicated in the backend adapters.
- OpenShift ConfigMap defaults to `mcp` with ClusterIP URLs `http://weather-mcp:8080/mcp` and `http://baggage-policy-mcp:8080/mcp`.
- Sensitive profile keys are rejected by `assert_safe_mcp_arguments` before any MCP call.
