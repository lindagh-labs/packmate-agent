#!/usr/bin/env bash
# Packmate sandbox bootstrap — idempotent prerequisites + Argo CD–owned DEV runtime.
# Does NOT redeploy the shared model in MODEL_NAMESPACE. Does NOT install Operators.
# Does NOT oc apply deploy/overlays/dev or deploy/overlays/prod.
# Argo CD Application/packmate-lab is the sole owner of Git-tracked DEV runtime resources.
# Creates the Packmate custom model endpoint automatically (CREATE_MODEL_CUSTOM_ENDPOINT=true).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/sandbox-common.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/ensure-secret.sh"

packmate_require_oc
packmate_require_human_user || exit 1
packmate_load_config "${ROOT}" || exit 1

log() { packmate_log "$*"; }
die() { packmate_die "$*"; }

HEALTH_RETRY_SECS=5
HEALTH_MAX_SECS=180
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"

wait_http_200() {
  local url="$1" label="$2"
  shift 2 || true
  local deadline=$((SECONDS + HEALTH_MAX_SECS))
  local code=000
  local last_diag=""
  while (( SECONDS < deadline )); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' -m 20 "$@" "${url}" 2>/dev/null || echo 000)"
    if [[ "${code}" == "200" ]]; then
      log "    OK ${label} (HTTP ${code})"
      return 0
    fi
    last_diag="HTTP ${code}"
    sleep "${HEALTH_RETRY_SECS}"
  done
  die "${label} health failed after ${HEALTH_MAX_SECS}s (last ${last_diag}) url=${url}"
}

wait_backend_pod_health() {
  local deadline=$((SECONDS + HEALTH_MAX_SECS))
  local last=""
  while (( SECONDS < deadline )); do
    if oc -n "${PACKMATE_NAMESPACE}" exec deploy/packmate-backend -- \
          curl -sf -m 15 http://127.0.0.1:8080/health >/dev/null 2>&1 \
      && oc -n "${PACKMATE_NAMESPACE}" exec deploy/packmate-backend -- \
          curl -sf -m 15 http://127.0.0.1:8080/ready >/dev/null 2>&1 \
      && oc -n "${PACKMATE_NAMESPACE}" exec deploy/packmate-backend -- \
          curl -sf -m 15 http://127.0.0.1:8080/metrics >/dev/null 2>&1; then
      log "    OK backend /health /ready /metrics via pod"
      return 0
    fi
    last="pod exec probe failed"
    sleep "${HEALTH_RETRY_SECS}"
  done
  oc -n "${PACKMATE_NAMESPACE}" get deploy,pods -l app.kubernetes.io/part-of=packmate 2>&1 | head -40 >&2 || true
  die "backend health/ready/metrics failed after ${HEALTH_MAX_SECS}s (${last})"
}

wait_deploy() {
  local name="$1"
  log "    waiting for deploy/${name}"
  oc -n "${PACKMATE_NAMESPACE}" rollout status "deploy/${name}" --timeout=300s
}

log "=== Packmate bootstrap ==="
log "user=$(oc whoami)"
log "context=$(oc config current-context)"
log "namespace=${PACKMATE_NAMESPACE}"
log "model=${MODEL_NAMESPACE}/${MODEL_ID}"
log "images: (Git/Argo CD owned — bootstrap does not oc apply DEV overlays)"
log "  backend=${BACKEND_IMAGE:-<overlay default>}"
log "  frontend=${FRONTEND_IMAGE:-<overlay default>}"
log "  weather=${WEATHER_MCP_IMAGE:-<overlay default>}"
log "  baggage=${BAGGAGE_POLICY_MCP_IMAGE:-<overlay default>}"
log "flags: REGISTER_MCP=${REGISTER_MCP} ENABLE_CUSTOM_ENDPOINTS=${ENABLE_CUSTOM_ENDPOINTS:-true} CREATE_MODEL_ENDPOINT=${CREATE_MODEL_CUSTOM_ENDPOINT} CREATE_PIPELINE=${CREATE_PIPELINE} CREATE_ARGOCD=${CREATE_ARGOCD_APPLICATION}"

if [[ -n "${BACKEND_IMAGE:-}${FRONTEND_IMAGE:-}${WEATHER_MCP_IMAGE:-}${BAGGAGE_POLICY_MCP_IMAGE:-}" ]]; then
  log "WARN: BACKEND_IMAGE/FRONTEND_IMAGE/MCP image overrides are ignored for live apply — change deploy/overlays/dev via Git; Argo CD owns DEV runtime"
fi

REQUIRE_OPENSHIFT_GITOPS="${REQUIRE_OPENSHIFT_GITOPS:-true}"
if [[ "${REQUIRE_OPENSHIFT_GITOPS}" == "true" || "${CREATE_ARGOCD_APPLICATION}" == "true" ]]; then
  log "==> GitOps prerequisite check (participant bootstrap never installs the Operator)"
  if ! bash "${ROOT}/scripts/check-openshift-gitops.sh"; then
    die "BLOCKED_GITOPS_OPERATOR_NOT_INSTALLED (or not ready). Instructor must run: INSTALL_OPENSHIFT_GITOPS_OPERATOR=true make instructor-setup"
  fi
fi

log "==> Resource ownership guard"
bash "${ROOT}/scripts/check-resource-ownership.sh" || die "BLOCKED_DUAL_OWNERSHIP"

if [[ "${PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE:-true}" == "true" ]]; then
  if grep -qE 'image-registry\.openshift-image-registry\.svc' "${ROOT}/deploy/overlays/prod/kustomization.yaml"; then
    die "BLOCKED_OLD_SANDBOX_PROD_IMAGE_REFERENCE: PROD overlay references an internal registry digest — restore durable GHCR baseline before bootstrap"
  fi
fi

if [[ "${SKIP_CONFIRM}" != "true" ]]; then
  read -r -p "Continue with bootstrap in ${PACKMATE_NAMESPACE}? [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]] || die "Aborted by user"
fi

# Namespace
if ! oc get project "${PACKMATE_NAMESPACE}" >/dev/null 2>&1; then
  if [[ "${ALLOW_CREATE_NAMESPACE}" == "true" ]]; then
    log "ALLOW_CREATE_NAMESPACE=true — creating project ${PACKMATE_NAMESPACE}"
    oc new-project "${PACKMATE_NAMESPACE}" --display-name="Packmate Lab" >/dev/null
    oc label namespace "${PACKMATE_NAMESPACE}" \
      opendatahub.io/dashboard=true \
      modelmesh-enabled=false \
      --overwrite >/dev/null
  else
    cat <<EOF
MANUAL STEP REQUIRED:
Create the Data Science Project from the OpenShift AI dashboard.

Suggested name: ${PACKMATE_NAMESPACE}
Then re-run: make bootstrap
EOF
    exit 1
  fi
fi

# Enable custom endpoints feature
log "==> Enabling custom model endpoints feature"
bash "${ROOT}/scripts/enable-custom-model-endpoints.sh"

# Discover and require shared model (no redeploy)
READY="$(oc get inferenceservice "${MODEL_ID}" -n "${MODEL_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
[[ "${READY}" == "True" ]] || die "Model ${MODEL_ID} not Ready in ${MODEL_NAMESPACE}"
if oc -n "${PACKMATE_NAMESPACE}" get inferenceservice "${MODEL_ID}" >/dev/null 2>&1; then
  die "InferenceService ${MODEL_ID} must not exist in ${PACKMATE_NAMESPACE}"
fi
packmate_discover_model_url || die "Cannot discover model Service URL"
log "model_url=${PACKMATE_MODEL_BASE_URL}"

# Secrets (idempotent — no apply when data identical; never print values)
log "==> Ensuring Secret packmate-llm"
packmate_ensure_opaque_secret "${PACKMATE_NAMESPACE}" packmate-llm \
  "BASE_URL=${LLM_BASE_URL}" \
  "MODEL=${LLM_MODEL}" \
  "LITELLM_API_KEY=${LITELLM_API_KEY}" \
  || die "packmate-llm Secret preparation failed"

# Custom model endpoint (bootstrap-owned; not in Git overlays)
log "==> Creating Packmate custom model endpoint"
CREATE_MODEL_CUSTOM_ENDPOINT="${CREATE_MODEL_CUSTOM_ENDPOINT}" \
  bash "${ROOT}/scripts/create-packmate-model-endpoint.sh" \
  || die "custom model endpoint creation/verification failed"
if [[ "${CREATE_MODEL_CUSTOM_ENDPOINT}" == "true" ]]; then
  oc -n "${PACKMATE_NAMESPACE}" get cm gen-ai-aa-custom-model-endpoints >/dev/null \
    || die "ConfigMap gen-ai-aa-custom-model-endpoints missing after create"
fi

# Pipeline (DEV only) — not owned by Argo CD overlays
if [[ "${CREATE_PIPELINE}" == "true" ]]; then
  if packmate_api_has '^pipelines[[:space:]].*tekton\.dev'; then
    log "==> Resolving Pipeline Python image (openshift/python:3.12-ubi9)"
    PACKMATE_NAMESPACE="${PACKMATE_NAMESPACE}" \
      bash "${ROOT}/scripts/resolve-pipeline-python-image.sh" >/tmp/packmate-python-image.txt
    RESOLVED_PY_IMAGE="$(tr -d '[:space:]' </tmp/packmate-python-image.txt)"
    [[ -n "${RESOLVED_PY_IMAGE}" ]] || die "Failed to resolve Pipeline Python image"
    log "    Python image: ${RESOLVED_PY_IMAGE}"

    log "==> Verifying RHOAI Python package compatibility (in-cluster)"
    PACKMATE_NAMESPACE="${PACKMATE_NAMESPACE}" \
      bash "${ROOT}/scripts/check-rhoai-python-dependencies.sh"

    log "==> Rendering lab Pipeline packmate-ci from template"
    PACKMATE_PIPELINE_PYTHON_IMAGE="${RESOLVED_PY_IMAGE}" \
    PACKMATE_NAMESPACE="${PACKMATE_NAMESPACE}" \
    PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE=true \
    PACKMATE_RENDERED_PIPELINE="${ROOT}/.generated/tekton/packmate-ci.yaml" \
      RENDERED="$(bash "${ROOT}/scripts/render-packmate-pipeline.sh" | tail -n 1)"
    [[ -f "${RENDERED}" ]] || die "Rendered Pipeline missing: ${RENDERED}"
    bash "${ROOT}/scripts/validate-packmate-pipeline.sh"
    grep -q "${RESOLVED_PY_IMAGE}" "${RENDERED}" || die "Rendered Pipeline missing resolved digest"
    grep -q 'ae2c1317fa423c188c408d81e61b87dbc5b559577272ac189bea4eede92661cb' "${RENDERED}" \
      && die "Obsolete Python digest still present in rendered Pipeline"
    grep -q '__PACKMATE_PIPELINE_PYTHON_IMAGE__' "${RENDERED}" \
      && die "Unresolved placeholder in rendered Pipeline"

    log "==> Applying rendered Pipeline packmate-ci"
    oc apply -n "${PACKMATE_NAMESPACE}" -f "${RENDERED}" >/dev/null
    DEPLOYED_IMG="$(oc -n "${PACKMATE_NAMESPACE}" get pipeline.tekton.dev packmate-ci -o yaml \
      | grep -E 'default: .*openshift/python@|image: .*openshift/python@' | head -1 | awk '{print $NF}' || true)"
    printf '%s' "${DEPLOYED_IMG}" | grep -q "${RESOLVED_PY_IMAGE##*@}" \
      || die "Deployed Pipeline Python image mismatch (deployed=${DEPLOYED_IMG} expected=${RESOLVED_PY_IMAGE})"
    log "    Deployed Pipeline uses ${RESOLVED_PY_IMAGE}"
    if ! oc -n "${PACKMATE_NAMESPACE}" get bc packmate-backend >/dev/null 2>&1; then
      oc -n "${PACKMATE_NAMESPACE}" apply -f - <<EOF
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: packmate-backend
  labels:
    app.kubernetes.io/part-of: packmate
spec:
  lookupPolicy:
    local: false
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: packmate-backend
  labels:
    app.kubernetes.io/part-of: packmate
spec:
  output:
    to:
      kind: ImageStreamTag
      name: packmate-backend:pipeline
  runPolicy: Serial
  source:
    type: Binary
    binary: {}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Containerfile
EOF
      log "    BuildConfig/ImageStream packmate-backend created"
    fi
    log "    Pipeline/packmate-ci ready — Start with VolumeClaimTemplate 2Gi (not Empty Directory)"
  else
    log "    WARNING: Pipelines API absent — skip CREATE_PIPELINE"
  fi
fi

# PROD prep + AppProject/Applications (no PROD overlay apply, no PROD sync)
if [[ "${CREATE_PROD_NAMESPACE}" == "true" || "${CREATE_ARGOCD_APPLICATION}" == "true" ]]; then
  if oc get crd applications.argoproj.io >/dev/null 2>&1 || [[ "${CREATE_PROD_NAMESPACE}" == "true" ]]; then
    log "==> Preparing packmate-prod (GitOps destination; no direct workload apply)"
    CREATE_ARGOCD_RBAC="${CREATE_ARGOCD_RBAC}" \
    PACKMATE_LAB_NAMESPACE="${PACKMATE_DEV_NAMESPACE:-${PACKMATE_NAMESPACE}}" \
    PACKMATE_PROD_NAMESPACE="${PACKMATE_PROD_NAMESPACE:-packmate-prod}" \
    GIT_REPO_URL="${GIT_REPO_URL}" \
    GIT_REVISION="${GIT_REVISION}" \
    PACKMATE_ARGO_GROUP="${PACKMATE_ARGO_GROUP:-packmate-lab-users}" \
    LLM_BASE_URL="${LLM_BASE_URL}" \
    LLM_MODEL="${LLM_MODEL}" \
    LITELLM_API_KEY="${LITELLM_API_KEY}" \
      bash "${ROOT}/scripts/prepare-prod.sh" \
      || die "prepare-prod failed"
  else
    die "BLOCKED_GITOPS_OPERATOR_NOT_INSTALLED — cannot create Argo CD Applications; refuse partial DEV runtime ownership"
  fi
fi

# Argo CD reconciles deploy/overlays/dev — bootstrap never oc apply -k that path
log "==> Waiting for Application/packmate-lab (Argo CD owns DEV runtime)"
bash "${ROOT}/scripts/wait-for-argocd-app.sh" packmate-lab "${ARGOCD_NAMESPACE}" \
  || die "Application/packmate-lab failed to become Synced/Healthy"

for d in weather-mcp baggage-policy-mcp packmate-backend packmate-frontend; do
  wait_deploy "${d}"
done

# MCP registration after Routes exist (bootstrap-owned ConfigMap; not in overlays)
W_HOST="$(oc -n "${PACKMATE_NAMESPACE}" get route weather-mcp -o jsonpath='{.spec.host}' 2>/dev/null || true)"
B_HOST="$(oc -n "${PACKMATE_NAMESPACE}" get route baggage-policy-mcp -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "${W_HOST}" ]] || die "Route weather-mcp missing after Argo sync"
[[ -n "${B_HOST}" ]] || die "Route baggage-policy-mcp missing after Argo sync"

log "==> MCP health checks"
wait_http_200 "https://${W_HOST}/health" "weather /health"
wait_http_200 "https://${B_HOST}/health" "baggage /health"

if [[ "${REGISTER_MCP}" == "true" ]]; then
  log "==> Registering MCP servers in ${ODH_APPLICATIONS_NS}"
  python3 - <<PY
import json, subprocess, tempfile, os
ns = "${ODH_APPLICATIONS_NS}"
name = "gen-ai-aa-mcp-servers"
weather = {
  "url": f"https://${W_HOST}/mcp",
  "description": "Packmate demonstration weather MCP server (Open-Meteo). Tool: get_weather. No credentials required.",
}
baggage = {
  "url": f"https://${B_HOST}/mcp",
  "description": "Packmate demonstration baggage policy MCP server. Tools: check_baggage_rules, get_general_baggage_rules. Deterministic demo rules with mandatory disclaimer.",
}
data = {}
r = subprocess.run(["oc", "get", "cm", name, "-n", ns, "-o", "json"], capture_output=True, text=True)
if r.returncode == 0:
  doc = json.loads(r.stdout)
  data = dict(doc.get("data") or {})
data["Packmate-Weather-MCP"] = json.dumps(weather, indent=2)
data["Packmate-Baggage-Policy-MCP"] = json.dumps(baggage, indent=2)
cm = {
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {"name": name, "namespace": ns},
  "data": data,
}
path = tempfile.mktemp(suffix=".json")
open(path, "w").write(json.dumps(cm))
subprocess.check_call(["oc", "apply", "-f", path])
os.unlink(path)
print("    MCP ConfigMap applied (existing keys preserved)")
PY
fi

log "==> Verifying AI assets for ${PACKMATE_NAMESPACE} Playground"
oc get cm gen-ai-aa-mcp-servers -n "${ODH_APPLICATIONS_NS}" -o json \
  | grep -q Packmate-Weather-MCP || die "Weather MCP not registered"
oc get cm gen-ai-aa-mcp-servers -n "${ODH_APPLICATIONS_NS}" -o json \
  | grep -q Packmate-Baggage-Policy-MCP || die "Baggage MCP not registered"
if [[ "${CREATE_MODEL_CUSTOM_ENDPOINT}" == "true" ]]; then
  oc -n "${PACKMATE_NAMESPACE}" get cm gen-ai-aa-custom-model-endpoints -o jsonpath='{.data.config\.yaml}' \
    | grep -q "${MODEL_ID}" || die "Packmate custom model endpoint missing ${MODEL_ID}"
  oc -n "${PACKMATE_NAMESPACE}" get cm gen-ai-aa-custom-model-endpoints -o jsonpath='{.data.config\.yaml}' \
    | grep -q "Packmate Llama" || die "Packmate display name missing from custom endpoint"
fi
log "    model + MCP assets ready for Playground (refresh Gen AI studio if needed)"

log "==> Backend / frontend health checks"
wait_backend_pod_health
ROUTE_HOST="$(oc -n "${PACKMATE_NAMESPACE}" get route packmate-frontend -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "${ROUTE_HOST}" ]] || die "Route packmate-frontend missing"
wait_http_200 "https://${ROUTE_HOST}/" "frontend /"

# Confirm DEV still Synced after health probes (no dual-ownership drift)
DEV_SYNC="$(oc -n "${ARGOCD_NAMESPACE}" get applications.argoproj.io packmate-lab -o jsonpath='{.status.sync.status}')"
DEV_HEALTH="$(oc -n "${ARGOCD_NAMESPACE}" get applications.argoproj.io packmate-lab -o jsonpath='{.status.health.status}')"
[[ "${DEV_SYNC}" == "Synced" && "${DEV_HEALTH}" == "Healthy" ]] \
  || die "Application/packmate-lab drifted to sync=${DEV_SYNC} health=${DEV_HEALTH} after bootstrap — dual ownership suspected"
log "OK: Application/packmate-lab remains Synced / Healthy after bootstrap"

PROD_SYNC="$(oc -n "${ARGOCD_NAMESPACE}" get applications.argoproj.io packmate-prod -o jsonpath='{.status.sync.status}' 2>/dev/null || echo unknown)"
PROD_HEALTH="$(oc -n "${ARGOCD_NAMESPACE}" get applications.argoproj.io packmate-prod -o jsonpath='{.status.health.status}' 2>/dev/null || echo unknown)"
log "INFO: Application/packmate-prod sync=${PROD_SYNC} health=${PROD_HEALTH} (manual Sync only — bootstrap does not sync PROD)"

log "==> SSE smoke test"
export PACKMATE_API="https://${ROUTE_HOST}"
bash "${ROOT}/scripts/test-streaming-smoke.sh" || die "SSE smoke failed"

cat <<EOF

=== Bootstrap complete ===
DEV Route: https://${ROUTE_HOST}/
DEV namespace: ${PACKMATE_NAMESPACE} (runtime owned by Argo CD Application/packmate-lab)
PROD namespace: ${PACKMATE_PROD_NAMESPACE:-packmate-prod} (manual Argo CD Sync only)

AI assets prepared for project Packmate Lab (${PACKMATE_NAMESPACE}):
  - Packmate Llama 3.2 3B (custom endpoint → shared model in ${MODEL_NAMESPACE})
  - Packmate-Weather-MCP
  - Packmate-Baggage-Policy-MCP

Remaining UI steps:
1. Gen AI studio → Playground → Project: Packmate Lab
2. Select Packmate Llama 3.2 3B → enable both MCP → paste playground/system-instructions.md
3. Pipelines → packmate-ci → Start → Workspace VolumeClaimTemplate 2Gi
4. Promote: scripts/promote-backend-image.sh --pipelinerun <name> --create-pr
5. Argo CD (OpenShift SSO) → packmate-prod → Sync (Prune off)

Next: make verify-dev && make verify-prod (after Sync)
EOF
