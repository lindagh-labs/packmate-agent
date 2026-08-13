#!/usr/bin/env bash
# Packmate sandbox preflight — PASS / WARNING / BLOCKED / OPTIONAL_UNAVAILABLE
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/sandbox-common.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/fork-safety.sh"

PASS=0
WARN=0
BLOCK=0
OPT=0

pass() { printf 'PASS                 %s\n' "$*"; PASS=$((PASS + 1)); }
warn() { printf 'WARNING              %s\n' "$*"; WARN=$((WARN + 1)); }
block() { printf 'BLOCKED              %s\n' "$*"; BLOCK=$((BLOCK + 1)); }
opt() { printf 'OPTIONAL_UNAVAILABLE %s\n' "$*"; OPT=$((OPT + 1)); }

packmate_require_oc
packmate_require_human_user || exit 1
if [[ -f "${ROOT}/config/sandbox.env" ]]; then
  packmate_load_config "${ROOT}" || true
else
  packmate_log "NOTE: config/sandbox.env missing — using defaults for discovery checks"
  PACKMATE_NAMESPACE="${PACKMATE_NAMESPACE:-packmate-lab}"
  MODEL_NAMESPACE="${MODEL_NAMESPACE:-my-first-model}"
  MODEL_SERVICE="${MODEL_SERVICE:-llama-32-3b-instruct-predictor}"
  MODEL_ID="${MODEL_ID:-llama-32-3b-instruct}"
fi

printf '\n=== Packmate preflight ===\n'
printf 'user=%s context=%s\n' "$(oc whoami)" "$(oc config current-context)"
printf 'namespace=%s model=%s/%s\n\n' "${PACKMATE_NAMESPACE}" "${MODEL_NAMESPACE}" "${MODEL_ID}"

# Repository root / branch
if [[ -d "${ROOT}/.git" ]]; then
  pass "Repository root is a valid Git clone (${ROOT})"
  BR="$(git -C "${ROOT}" branch --show-current 2>/dev/null || true)"
  EXPECTED_BRANCH="${GIT_REVISION:-packmate-v2}"
  EXPECTED_BASE="${PROMOTION_BASE_BRANCH:-${EXPECTED_BRANCH}}"
  if [[ "${BR}" == "${EXPECTED_BRANCH}" && "${EXPECTED_BRANCH}" == "${EXPECTED_BASE}" ]]; then
    pass "Current branch matches GitOps and promotion settings (${BR})"
  else
    block "Branch settings disagree (current=${BR:-detached} GIT_REVISION=${EXPECTED_BRANCH} PROMOTION_BASE_BRANCH=${EXPECTED_BASE})"
    printf 'ACTION               Run make configure-participant; for a prepared demo branch run make prepare-demo-baseline\n'
  fi
else
  block "Repository root is a valid Git clone (missing .git under ${ROOT})"
fi

# config/sandbox.env
if [[ -f "${ROOT}/config/sandbox.env" ]]; then
  pass "config/sandbox.env present"
else
  block "config/sandbox.env missing — run make configure-participant"
fi

# Participant fork and registry settings must be concrete and coordinated before
# any cluster work or candidate publication.
CONFIGURED_REPO="$(packmate_normalize_github_owner_repo "${GIT_REPO_URL:-}" 2>/dev/null || true)"
if [[ -n "${CONFIGURED_REPO}" ]] && ! packmate_is_canonical_owner_repo "${CONFIGURED_REPO}"; then
  pass "GitOps repository is a participant fork (${CONFIGURED_REPO})"
else
  block "GIT_REPO_URL is not a configured participant fork"
  printf 'ACTION               Run make configure-participant\n'
fi
CONFIGURED_FORK_OWNER="${CONFIGURED_REPO%%/*}"
if [[ "${PACKMATE_PROMOTION_REGISTRY_OWNER:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
  && [[ "${PACKMATE_PROMOTION_REGISTRY_OWNER,,}" == "${CONFIGURED_FORK_OWNER,,}" ]]; then
  pass "GHCR owner matches the participant fork (${PACKMATE_PROMOTION_REGISTRY_OWNER})"
else
  block "GHCR owner does not match the participant fork (${PACKMATE_PROMOTION_REGISTRY_OWNER:-unset} vs ${CONFIGURED_FORK_OWNER:-unset})"
  printf 'ACTION               Run make configure-participant\n'
fi

# oc / connection
pass "oc installed and authenticated as $(oc whoami)"

# OpenShift AI
if oc get csv -A --no-headers 2>/dev/null | grep -Eq 'rhods-operator|opendatahub'; then
  pass "OpenShift AI operator CSV present (OPENSHIFT_AI_AVAILABLE)"
elif oc get odhdashboardconfig -A >/dev/null 2>&1; then
  pass "OdhDashboardConfig present (OPENSHIFT_AI_AVAILABLE)"
else
  block "OpenShift AI not detected"
fi

# Participant namespace
if oc get project "${PACKMATE_NAMESPACE}" >/dev/null 2>&1; then
  pass "Data Science Project ${PACKMATE_NAMESPACE} exists"
elif [[ "${ALLOW_CREATE_NAMESPACE:-false}" == "true" ]]; then
  warn "Namespace ${PACKMATE_NAMESPACE} absent — bootstrap will create it (ALLOW_CREATE_NAMESPACE=true)"
else
  block "MANUAL STEP REQUIRED: Create the Data Science Project from the OpenShift AI dashboard (${PACKMATE_NAMESPACE})"
fi

# Namespace RBAC smoke (skip hard fail when namespace will be created by bootstrap)
if oc get project "${PACKMATE_NAMESPACE}" >/dev/null 2>&1; then
  if oc auth can-i create deployments -n "${PACKMATE_NAMESPACE}" >/dev/null 2>&1; then
    pass "User can create Deployments in ${PACKMATE_NAMESPACE}"
  else
    block "Insufficient rights in ${PACKMATE_NAMESPACE} (cannot create Deployments)"
  fi
elif [[ "${ALLOW_CREATE_NAMESPACE:-false}" == "true" ]]; then
  if oc auth can-i create projects >/dev/null 2>&1 || oc auth can-i create namespaces >/dev/null 2>&1; then
    pass "User can create projects/namespaces (bootstrap will create ${PACKMATE_NAMESPACE})"
  else
    block "ALLOW_CREATE_NAMESPACE=true but user cannot create projects"
  fi
else
  block "Insufficient rights in ${PACKMATE_NAMESPACE} (namespace missing)"
fi

# Model
if oc get inferenceservice "${MODEL_ID}" -n "${MODEL_NAMESPACE}" >/dev/null 2>&1; then
  READY="$(oc get inferenceservice "${MODEL_ID}" -n "${MODEL_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${READY}" == "True" ]]; then
    pass "InferenceService ${MODEL_ID} Ready in ${MODEL_NAMESPACE}"
  else
    block "InferenceService ${MODEL_ID} not Ready (status=${READY:-unknown})"
  fi
else
  block "Model InferenceService ${MODEL_ID} missing in ${MODEL_NAMESPACE}"
fi

if oc get svc "${MODEL_SERVICE}" -n "${MODEL_NAMESPACE}" >/dev/null 2>&1; then
  pass "Model Service ${MODEL_SERVICE} exists"
  if packmate_discover_model_url; then
    pass "Model base URL discovered: ${PACKMATE_MODEL_BASE_URL}"
    # Probe /v1/models from packmate namespace if it exists
    if oc get project "${PACKMATE_NAMESPACE}" >/dev/null 2>&1; then
      POD="packmate-preflight-probe-$$"
      oc -n "${PACKMATE_NAMESPACE}" delete pod "${POD}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      if oc -n "${PACKMATE_NAMESPACE}" run "${POD}" --image=registry.access.redhat.com/ubi9/ubi-minimal:9.4 \
        --restart=Never --quiet \
        --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"probe","image":"registry.access.redhat.com/ubi9/ubi-minimal:9.4","command":["sleep","60"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"runAsNonRoot":true}}]}}' \
        --command -- sleep 60 >/dev/null 2>&1; then
        if oc -n "${PACKMATE_NAMESPACE}" wait --for=condition=Ready "pod/${POD}" --timeout=90s >/dev/null 2>&1; then
          BODY="$(oc -n "${PACKMATE_NAMESPACE}" exec "${POD}" -- curl -sS -m 20 "${PACKMATE_MODEL_BASE_URL}/models" 2>/dev/null || true)"
          if printf '%s' "${BODY}" | grep -q "${MODEL_ID}"; then
            pass "/v1/models lists ${MODEL_ID}"
          else
            block "/v1/models did not list ${MODEL_ID}"
          fi
        else
          warn "Could not Ready probe pod for /v1/models"
        fi
        oc -n "${PACKMATE_NAMESPACE}" delete pod "${POD}" --wait=false >/dev/null 2>&1 || true
      else
        warn "Could not create probe pod for /v1/models"
      fi
    fi
  fi
else
  block "Model Service ${MODEL_SERVICE} missing"
fi

# Images
check_image() {
  local name="$1" ref="$2"
  if [[ -z "${ref}" ]]; then
    warn "${name} image empty in config — set before bootstrap (or rely on overlay digests)"
    return
  fi
  if [[ "${ref}" == *":latest"* ]]; then
    block "${name} uses forbidden :latest tag (${ref})"
    return
  fi
  if [[ "${ref}" == image-registry.openshift-image-registry.svc* ]]; then
    # ref like .../ns/name@sha256:... or .../ns/name:tag
    local path_part is_name
    path_part="$(echo "${ref}" | sed -E 's|^[^/]+/||; s|@.*||; s|:.*||')"
    is_name="$(basename "${path_part}")"
    local is_ns
    is_ns="$(dirname "${path_part}")"
    [[ "${is_ns}" == "." ]] && is_ns="${PACKMATE_NAMESPACE}"
    if oc -n "${is_ns}" get is "${is_name}" >/dev/null 2>&1; then
      pass "${name} ImageStream ${is_ns}/${is_name} present"
    else
      warn "${name} internal ImageStream ${is_ns}/${is_name} not found yet"
    fi
    return
  fi
  if command -v skopeo >/dev/null 2>&1; then
    if skopeo inspect "docker://${ref}" >/dev/null 2>&1; then
      pass "${name} image reachable: ${ref}"
    else
      block "${name} image not reachable: ${ref}"
    fi
  else
    warn "${name} set to ${ref} (skopeo not installed — reachability not verified)"
  fi
}

check_image BACKEND "${BACKEND_IMAGE:-}"
check_image FRONTEND "${FRONTEND_IMAGE:-}"
check_image WEATHER_MCP "${WEATHER_MCP_IMAGE:-}"
check_image BAGGAGE_POLICY_MCP "${BAGGAGE_POLICY_MCP_IMAGE:-}"

# Pipelines
if packmate_api_has '^pipelines[[:space:]].*tekton\.dev'; then
  pass "Tekton Pipelines API available (PIPELINES_AVAILABLE)"
else
  warn "Tekton Pipelines API missing — Pipeline module will be skipped"
fi

# GitOps (Argo CD Application CRD)
if packmate_api_has 'applications\.argoproj\.io|appprojects\.argoproj\.io' \
  || oc get crd applications.argoproj.io >/dev/null 2>&1; then
  pass "Argo CD Application API available (GITOPS_AVAILABLE)"
else
  warn "OpenShift GitOps / Argo CD Application CRD absent — see docs/INSTALL_GITOPS_PREREQUISITE.md"
fi

# Rollouts
if packmate_api_has '^rollouts[[:space:]]' || oc get crd rollouts.argoproj.io >/dev/null 2>&1; then
  pass "Argo Rollouts API available"
else
  opt "Argo Rollouts not installed (ROLLOUTS optional annex)"
fi

# EvalHub
if packmate_api_has '^evalhubs[[:space:]]'; then
  if oc get evalhubs -A --no-headers 2>/dev/null | grep -q .; then
    pass "EvalHub instance present"
  else
    opt "EvalHub CRD present but EVALHUB_OPTIONAL_NOT_CONFIGURED"
  fi
else
  opt "EvalHub CRD absent (optional)"
fi

# RHOAI Python mirror + ImageStream (lightweight — full check runs in bootstrap)
if PACKMATE_DEPS_LIGHTWEIGHT=true bash "${ROOT}/scripts/check-rhoai-python-dependencies.sh" >/tmp/packmate-preflight-deps.txt 2>&1; then
  pass "RHOAI Python package mirror reachable (lightweight)"
else
  block "RHOAI Python package mirror check failed (see /tmp/packmate-preflight-deps.txt)"
fi

if oc get istag python:3.12-ubi9 -n openshift >/dev/null 2>&1; then
  pass "Pipeline Python ImageStreamTag openshift/python:3.12-ubi9 available"
else
  block "Pipeline Python ImageStreamTag openshift/python:3.12-ubi9 missing"
fi

TPL="${ROOT}/.tekton/lab/packmate-ci.yaml.tpl"
if [[ -f "${TPL}" ]]; then
  if grep -qE 'sha256:ae2c1317fa423c188c408d81e61b87dbc5b559577272ac189bea4eede92661cb' "${TPL}"; then
    block "Tracked Pipeline template contains obsolete sandbox Python digest"
  else
    pass "Tracked Pipeline template contains no sandbox-specific Python digest"
  fi
  if grep -q '__PACKMATE_PIPELINE_PYTHON_IMAGE__' "${TPL}"; then
    pass "Pipeline template uses portable Python image placeholder"
  else
    block "Pipeline template missing __PACKMATE_PIPELINE_PYTHON_IMAGE__ placeholder"
  fi
else
  block "Missing .tekton/lab/packmate-ci.yaml.tpl"
fi

# Ownership guard (static — no cluster mutation)
if bash "${ROOT}/scripts/check-resource-ownership.sh" >/tmp/packmate-preflight-own.txt 2>&1; then
  pass "Resource ownership: Argo CD owns Git-tracked runtime overlays"
else
  block "Resource ownership check failed"
  sed -n '1,40p' /tmp/packmate-preflight-own.txt || true
fi

# Portable promotion push Secret (required before Pipeline publish-candidate)
PUSH_SECRET="${PACKMATE_PROMOTION_PUSH_SECRET:-packmate-ghcr-push}"
if oc -n "${PACKMATE_NAMESPACE}" get secret "${PUSH_SECRET}" >/dev/null 2>&1; then
  pass "Promotion push Secret ${PUSH_SECRET} present in ${PACKMATE_NAMESPACE}"
else
  block "Promotion push Secret ${PUSH_SECRET} missing in ${PACKMATE_NAMESPACE}"
  printf 'FAIL    publish-candidate will stay Pending (FailedMount)\n'
  printf 'DETAIL  Task mounts Secret/%s; kubelet cannot start the Pod without it\n' "${PUSH_SECRET}"
  printf 'ACTION  Instructor: make configure-promotion-registry && make verify-promotion-registry\n'
fi

printf '\n=== Summary ===\n'
printf 'PASS=%s WARNING=%s BLOCKED=%s OPTIONAL_UNAVAILABLE=%s\n' "${PASS}" "${WARN}" "${BLOCK}" "${OPT}"
if [[ "${BLOCK}" -gt 0 ]]; then
  printf 'Preflight BLOCKED — fix required items before make bootstrap\n'
  exit 1
fi
printf 'Preflight OK\n'
exit 0
