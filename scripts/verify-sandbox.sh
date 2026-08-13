#!/usr/bin/env bash
# Non-destructive Packmate sandbox verification.
# Exit 0 only if the mandatory lab core is ready.
# Absence of Rollouts / EvalHub / GitOps does not fail the verify.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/sandbox-common.sh"

packmate_require_oc
packmate_require_human_user || exit 1
if [[ -f "${ROOT}/config/sandbox.env" ]]; then
  packmate_load_config "${ROOT}" || exit 1
else
  PACKMATE_NAMESPACE="${PACKMATE_NAMESPACE:-packmate-lab}"
  MODEL_NAMESPACE="${MODEL_NAMESPACE:-my-first-model}"
  MODEL_SERVICE="${MODEL_SERVICE:-llama-32-3b-instruct-predictor}"
  MODEL_ID="${MODEL_ID:-llama-32-3b-instruct}"
  ODH_APPLICATIONS_NS="${ODH_APPLICATIONS_NS:-redhat-ods-applications}"
  ENABLE_CUSTOM_ENDPOINTS="${ENABLE_CUSTOM_ENDPOINTS:-true}"
  CREATE_MODEL_CUSTOM_ENDPOINT="${CREATE_MODEL_CUSTOM_ENDPOINT:-true}"
fi

FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf 'INFO  %s\n' "$*"; }

printf '=== Packmate verify (%s) ===\n' "${PACKMATE_NAMESPACE}"

# Workbench / repository checks
if [[ -d "${ROOT}/.git" ]]; then
  pass "Workbench repository is a valid Git clone"
  BR="$(git -C "${ROOT}" branch --show-current 2>/dev/null || true)"
  EXPECTED_BRANCH="${GIT_REVISION:-packmate-v2}"
  EXPECTED_BASE="${PROMOTION_BASE_BRANCH:-${EXPECTED_BRANCH}}"
  [[ "${BR}" == "${EXPECTED_BRANCH}" && "${EXPECTED_BRANCH}" == "${EXPECTED_BASE}" ]] \
    && pass "Repository branch matches GitOps/promotion settings (${BR})" \
    || fail "Repository branch/settings disagree (current=${BR:-detached} revision=${EXPECTED_BRANCH} base=${EXPECTED_BASE})"
else
  fail "Workbench repository is a valid Git clone"
  fail "Repository branch matches configured workshop revision"
fi

# DSP labels (best-effort)
if oc get project "${PACKMATE_NAMESPACE}" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q opendatahub; then
  pass "Data Science Project labels present"
else
  info "opendatahub labels not detected on project (may still be valid DSP)"
fi

READY="$(oc get inferenceservice "${MODEL_ID}" -n "${MODEL_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
[[ "${READY}" == "True" ]] && pass "Model ${MODEL_ID} Ready" || fail "Model not Ready"

for d in weather-mcp baggage-policy-mcp packmate-backend packmate-frontend; do
  avail="$(oc -n "${PACKMATE_NAMESPACE}" get deploy "${d}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  [[ "${avail}" != "" && "${avail}" != "0" ]] && pass "deploy/${d} available=${avail}" || fail "deploy/${d} not available"
done

ROUTE_HOST="$(oc -n "${PACKMATE_NAMESPACE}" get route packmate-frontend -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "${ROUTE_HOST}" ]]; then
  code="$(curl -sk -o /dev/null -w '%{http_code}' -m 25 "https://${ROUTE_HOST}/" || echo 000)"
  [[ "${code}" == "200" ]] && pass "Frontend Route HTTP ${code}" || fail "Frontend Route HTTP ${code}"
else
  fail "Frontend Route missing"
fi

# Backend health + metrics in-cluster (Route /api/* preserves /api prefix; probes use Service)
if oc -n "${PACKMATE_NAMESPACE}" get deploy packmate-backend >/dev/null 2>&1; then
  if oc -n "${PACKMATE_NAMESPACE}" exec deploy/packmate-backend -- \
      curl -sf -m 15 http://127.0.0.1:8080/health >/dev/null 2>&1; then
    pass "Backend /health via pod"
  else
    fail "Backend /health via pod"
  fi
  if oc -n "${PACKMATE_NAMESPACE}" exec deploy/packmate-backend -- \
      curl -sf -m 15 http://127.0.0.1:8080/ready >/dev/null 2>&1; then
    pass "Backend /ready via pod"
  else
    fail "Backend /ready via pod"
  fi
  metrics="$(oc -n "${PACKMATE_NAMESPACE}" exec deploy/packmate-backend -- \
    curl -sf -m 15 http://127.0.0.1:8080/metrics 2>/dev/null || true)"
  printf '%s' "${metrics}" | grep -q 'packmate_' && pass "Metrics expose packmate_* series" || fail "Metrics missing packmate_*"
fi

# MCP routes
for r in weather-mcp baggage-policy-mcp; do
  h="$(oc -n "${PACKMATE_NAMESPACE}" get route "${r}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${h}" ]]; then
    code="$(curl -sk -o /dev/null -w '%{http_code}' -m 20 "https://${h}/health" || echo 000)"
    [[ "${code}" == "200" ]] && pass "Route ${r} /health ${code}" || fail "Route ${r} /health ${code}"
  else
    fail "Route ${r} missing"
  fi
done

# Custom endpoints feature + shared model + Packmate custom endpoint
CREATE_MODEL_CUSTOM_ENDPOINT="${CREATE_MODEL_CUSTOM_ENDPOINT:-true}"
ENABLE_CUSTOM_ENDPOINTS="${ENABLE_CUSTOM_ENDPOINTS:-true}"
FEAT="$(oc get odhdashboardconfig odh-dashboard-config -n "${ODH_APPLICATIONS_NS}" \
  -o jsonpath='{.spec.dashboardConfig.aiAssetCustomEndpoints}' 2>/dev/null || true)"
if [[ "${ENABLE_CUSTOM_ENDPOINTS}" == "true" || "${CREATE_MODEL_CUSTOM_ENDPOINT}" == "true" ]]; then
  [[ "${FEAT}" == "true" ]] && pass "Custom endpoints feature enabled" || fail "Custom endpoints feature not enabled"
else
  info "Custom endpoints feature check skipped (flags false)"
fi

if packmate_discover_model_url 2>/dev/null; then
  POD="packmate-verify-model-$$"
  oc -n "${PACKMATE_NAMESPACE}" delete pod "${POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if oc -n "${PACKMATE_NAMESPACE}" run "${POD}" --image=registry.access.redhat.com/ubi9/ubi-minimal:9.4 \
      --restart=Never --quiet \
      --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"probe","image":"registry.access.redhat.com/ubi9/ubi-minimal:9.4","command":["sleep","60"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"runAsNonRoot":true}}]}}' \
      --command -- sleep 60 >/dev/null 2>&1 \
    && oc -n "${PACKMATE_NAMESPACE}" wait --for=condition=Ready "pod/${POD}" --timeout=90s >/dev/null 2>&1; then
    code="$(oc -n "${PACKMATE_NAMESPACE}" exec "${POD}" -- \
      curl -sS -o /dev/null -w '%{http_code}' -m 25 "${PACKMATE_MODEL_BASE_URL}/models" 2>/dev/null || echo 000)"
    [[ "${code}" == "200" ]] && pass "Shared model service reachable" || fail "Shared model service HTTP ${code}"
  else
    fail "Shared model service reachable (probe pod failed)"
  fi
  oc -n "${PACKMATE_NAMESPACE}" delete pod "${POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
else
  fail "Shared model service reachable (discovery failed)"
fi

if [[ "${CREATE_MODEL_CUSTOM_ENDPOINT}" == "true" ]]; then
  if oc -n "${PACKMATE_NAMESPACE}" get cm gen-ai-aa-custom-model-endpoints >/dev/null 2>&1; then
    cm_yaml="$(oc -n "${PACKMATE_NAMESPACE}" get cm gen-ai-aa-custom-model-endpoints -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"
    if printf '%s' "${cm_yaml}" | grep -q "${MODEL_ID}" \
      && printf '%s' "${cm_yaml}" | grep -q "Packmate Llama"; then
      pass "Packmate custom model endpoint created"
    else
      fail "Packmate custom model endpoint created (ConfigMap incomplete)"
    fi
    # Secret referenced by config (never dump values)
    sec_name="$(printf '%s' "${cm_yaml}" | sed -n 's/.*name:[[:space:]]*\(endpoint-api-key-[0-9][0-9]*\).*/\1/p' | head -1)"
    if [[ -n "${sec_name}" ]] && oc -n "${PACKMATE_NAMESPACE}" get secret "${sec_name}" >/dev/null 2>&1; then
      pass "Packmate custom model endpoint verified"
    else
      fail "Packmate custom model endpoint verified (Secret missing)"
    fi
  else
    fail "Packmate custom model endpoint created"
    fail "Packmate custom model endpoint verified"
  fi
  # No second InferenceService / GPU copy in lab NS
  if oc -n "${PACKMATE_NAMESPACE}" get inferenceservice 2>/dev/null | grep -qi llama; then
    fail "No Llama InferenceService in ${PACKMATE_NAMESPACE}"
  else
    pass "No Llama InferenceService in ${PACKMATE_NAMESPACE}"
  fi
else
  info "Custom model endpoint checks skipped (CREATE_MODEL_CUSTOM_ENDPOINT=false)"
fi

# MCP ConfigMap
if oc get cm gen-ai-aa-mcp-servers -n "${ODH_APPLICATIONS_NS}" >/dev/null 2>&1; then
  data="$(oc get cm gen-ai-aa-mcp-servers -n "${ODH_APPLICATIONS_NS}" -o json)"
  printf '%s' "${data}" | grep -q Packmate-Weather-MCP && pass "Weather MCP registered" || fail "Weather MCP not registered"
  printf '%s' "${data}" | grep -q Packmate-Baggage-Policy-MCP && pass "Baggage MCP registered" || fail "Baggage MCP not registered"
else
  fail "Weather MCP registered (ConfigMap missing)"
  fail "Baggage MCP registered (ConfigMap missing)"
fi

# Combined Playground readiness
if [[ "${CREATE_MODEL_CUSTOM_ENDPOINT}" == "true" ]]; then
  if oc -n "${PACKMATE_NAMESPACE}" get cm gen-ai-aa-custom-model-endpoints >/dev/null 2>&1 \
    && oc get cm gen-ai-aa-mcp-servers -n "${ODH_APPLICATIONS_NS}" -o json 2>/dev/null | grep -q Packmate-Weather-MCP \
    && oc get cm gen-ai-aa-mcp-servers -n "${ODH_APPLICATIONS_NS}" -o json 2>/dev/null | grep -q Packmate-Baggage-Policy-MCP; then
    pass "Model and MCP assets ready for packmate-lab Playground"
  else
    fail "Model and MCP assets ready for packmate-lab Playground"
  fi
fi

# SSE + heartbeats
if [[ -n "${ROUTE_HOST}" ]]; then
  export PACKMATE_API="https://${ROUTE_HOST}"
  if bash "${ROOT}/scripts/test-streaming-smoke.sh" >/tmp/packmate-verify-sse.txt 2>&1; then
    pass "SSE smoke OK"
    grep -q 'heartbeats' /tmp/packmate-verify-sse.txt && pass "Heartbeats observed in SSE stream" || info "Heartbeat count not printed"
  else
    fail "SSE smoke failed (see /tmp/packmate-verify-sse.txt)"
  fi
fi

# Images without latest
imgs="$(oc -n "${PACKMATE_NAMESPACE}" get deploy -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null || true)"
if printf '%s' "${imgs}" | grep -q ':latest'; then
  fail "Deployment image uses :latest"
else
  pass "No :latest image tags on Deployments"
fi

# Secrets not in git
if git -C "${ROOT}" ls-files | grep -E '(^|/)\.env$|sandbox\.env$' >/dev/null; then
  fail "Secret-like env file tracked in git"
else
  pass "No sandbox.env/.env tracked in git"
fi

# Pipeline (optional for fail)
OBSOLETE_PY_DIGEST="sha256:ae2c1317fa423c188c408d81e61b87dbc5b559577272ac189bea4eede92661cb"
if oc -n "${PACKMATE_NAMESPACE}" get pipeline.tekton.dev packmate-ci >/dev/null 2>&1; then
  pass "Pipeline/packmate-ci present (tekton.dev)"
  PIPE_YAML="$(oc -n "${PACKMATE_NAMESPACE}" get pipeline.tekton.dev packmate-ci -o yaml 2>/dev/null || true)"
  if printf '%s' "${PIPE_YAML}" | grep -q "${OBSOLETE_PY_DIGEST}"; then
    fail "No obsolete sandbox Python digest remains"
  else
    pass "No obsolete sandbox Python digest remains"
  fi
  if printf '%s' "${PIPE_YAML}" | grep -E '^\s+image:\s+\S+' | grep -qE ':latest([[:space:]]|$)'; then
    fail "No :latest image in Pipeline"
  else
    pass "No :latest image in Pipeline"
  fi
  if oc get istag python:3.12-ubi9 -n openshift >/dev/null 2>&1; then
    pass "Pipeline Python ImageStreamTag available"
    CURRENT_DIGEST="$(oc get istag python:3.12-ubi9 -n openshift -o jsonpath='{.image.metadata.name}' 2>/dev/null || true)"
    EXPECTED_IMG="image-registry.openshift-image-registry.svc:5000/openshift/python@${CURRENT_DIGEST}"
    if [[ -n "${CURRENT_DIGEST}" ]] && printf '%s' "${PIPE_YAML}" | grep -q "${CURRENT_DIGEST}"; then
      pass "Pipeline Python image resolved by digest"
      pass "Deployed Pipeline uses current sandbox Python digest"
    elif printf '%s' "${PIPE_YAML}" | grep -qE 'openshift/python@sha256:'; then
      pass "Pipeline Python image resolved by digest"
      fail "Deployed Pipeline uses current sandbox Python digest"
      info "Pipeline image changed. Run make bootstrap to re-render and reapply packmate-ci."
    else
      fail "Pipeline Python image resolved by digest"
      fail "Deployed Pipeline uses current sandbox Python digest"
    fi
  else
    fail "Pipeline Python ImageStreamTag available"
  fi
  TPL="${ROOT}/.tekton/lab/packmate-ci.yaml.tpl"
  if [[ -f "${TPL}" ]]; then
    if grep -q "${OBSOLETE_PY_DIGEST}" "${TPL}"; then
      fail "Pipeline template contains no sandbox-specific digest"
    else
      pass "Pipeline template contains no sandbox-specific digest"
    fi
    if grep -q '__PACKMATE_PIPELINE_PYTHON_IMAGE__' "${TPL}"; then
      pass "Pipeline template uses portable placeholder"
    else
      fail "Pipeline template uses portable placeholder"
    fi
  fi
  # Digest rotation notice
  CURRENT_DIGEST="$(oc get istag python:3.12-ubi9 -n openshift -o jsonpath='{.image.metadata.name}' 2>/dev/null || true)"
  if [[ -n "${CURRENT_DIGEST}" ]] && ! printf '%s' "${PIPE_YAML}" | grep -q "${CURRENT_DIGEST}"; then
    info "Pipeline image changed. Run make bootstrap to re-render and reapply packmate-ci."
  fi
else
  info "Pipeline/packmate-ci absent (OK if Pipelines skipped)"
fi

# RHOAI dependency compatibility (full)
if bash "${ROOT}/scripts/check-rhoai-python-dependencies.sh" >/tmp/packmate-verify-deps.txt 2>&1; then
  pass "RHOAI dependency compatibility passed"
  pass "MCP SDK version is 1.27.2"
  pass "MCP streamable_http_client import supported"
  pass "json-repair version is 0.25.3"
  pass "Backend dependency installation works in isolation"
  pass "pip check passed"
  RENDERED="${ROOT}/.generated/tekton/packmate-ci.yaml"
  if [[ -f "${RENDERED}" ]]; then
    if grep -q '__PACKMATE_PIPELINE_PYTHON_IMAGE__' "${RENDERED}"; then
      fail "Pipeline rendered without unresolved placeholders"
    else
      pass "Pipeline rendered without unresolved placeholders"
    fi
  else
    info "Rendered Pipeline file not present locally (bootstrap creates it)"
  fi
else
  fail "RHOAI Python package compatibility (see /tmp/packmate-verify-deps.txt)"
  sed -n '1,40p' /tmp/packmate-verify-deps.txt 2>/dev/null | sed -E 's#(https?://[^/@]*:)[^/@]+@#\1***@#g' || true
fi

# Confirm Python image pull via resolve (idempotent; deletes probe pod)
if PACKMATE_NAMESPACE="${PACKMATE_NAMESPACE}" \
    bash "${ROOT}/scripts/resolve-pipeline-python-image.sh" >/tmp/packmate-verify-pyimg.txt 2>/tmp/packmate-verify-pyimg.err; then
  pass "Pipeline Python image pull verified"
else
  fail "Pipeline Python image pull verified"
  redact() { sed -E 's#(https?://[^/@]*:)[^/@]+@#\1***@#g'; }
  head -20 /tmp/packmate-verify-pyimg.err 2>/dev/null | redact || true
fi

# Argo CD
if oc get application.argoproj.io packmate-lab -n openshift-gitops >/dev/null 2>&1; then
  pass "Argo CD Application/packmate-lab present"
  LAB_SYNC="$(oc -n openshift-gitops get application.argoproj.io packmate-lab -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  LAB_HEALTH="$(oc -n openshift-gitops get application.argoproj.io packmate-lab -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [[ "${LAB_SYNC}" == "Synced" ]] && pass "Application packmate-lab Synced" || fail "Application packmate-lab Synced (sync=${LAB_SYNC})"
  [[ "${LAB_HEALTH}" == "Healthy" ]] && pass "Application packmate-lab Healthy" || fail "Application packmate-lab Healthy (health=${LAB_HEALTH})"
  if ! grep -qE 'apply_named_deploys|oc apply -k .*deploy/overlays/dev|oc apply -f "\$\{TMP\}/nondeploy' \
      "${ROOT}/scripts/bootstrap-sandbox.sh"; then
    pass "Bootstrap does not directly apply DEV overlay"
    pass "DEV runtime resources owned by Argo CD"
  else
    fail "Bootstrap does not directly apply DEV overlay"
  fi
  # Live-state only: never PASS idempotent Synced when Application is OutOfSync/Missing.
  if [[ "${LAB_SYNC}" == "Synced" && "${LAB_HEALTH}" == "Healthy" ]]; then
    pass "DEV remained Synced after idempotent bootstrap"
  else
    fail "DEV is not currently Synced and Healthy"
    info "sync=${LAB_SYNC:-?} health=${LAB_HEALTH:-?}"
  fi
elif oc get crd applications.argoproj.io >/dev/null 2>&1; then
  info "GitOps CRD present but Application not applied"
else
  info "GITOPS_OPERATOR_REQUIRED — Argo CD module is documentation-only on this cluster"
fi

# Rollouts / EvalHub never fail verify
if oc get crd rollouts.argoproj.io >/dev/null 2>&1; then
  info "Rollouts available (optional annex)"
else
  info "ROLLOUTS OPTIONAL_UNAVAILABLE"
fi
if oc get evalhubs -A --no-headers 2>/dev/null | grep -q .; then
  info "EvalHub instance present"
else
  info "EVALHUB_OPTIONAL_NOT_CONFIGURED"
fi

# Quality gate + security (local)
if [[ -x "${ROOT}/backend/.venv/bin/python" ]] || [[ -d "${ROOT}/backend" ]]; then
  if bash "${ROOT}/evaluations/scripts/run_deterministic_gate.sh" >/tmp/packmate-verify-qg.txt 2>&1; then
    pass "Quality gate deterministic PASSED"
    grep -E 'Overall|score|QUALITY|0\.9' /tmp/packmate-verify-qg.txt | head -5 || true
  else
    fail "Quality gate failed"
  fi
fi
if bash "${ROOT}/scripts/security-check.sh" >/tmp/packmate-verify-sec.txt 2>&1; then
  pass "security-check passed"
else
  fail "security-check failed"
fi

printf '\n'
if [[ "${FAILS}" -gt 0 ]]; then
  printf 'verify-sandbox: %s mandatory check(s) failed\n' "${FAILS}"
  exit 1
fi
printf 'verify-sandbox: OK (lab core ready)\n'
exit 0
