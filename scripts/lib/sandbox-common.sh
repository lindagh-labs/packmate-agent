#!/usr/bin/env bash
# Shared helpers for Packmate sandbox scripts. Sourced by other scripts.
# shellcheck shell=bash

packmate_root() {
  cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd
}

packmate_load_config() {
  local root="$1"
  local cfg="${PACKMATE_CONFIG:-${root}/config/sandbox.env}"
  if [[ ! -f "${cfg}" ]]; then
    printf 'ERROR: configuration file missing: %s\n' "${cfg}" >&2
    printf 'Run make configure-participant from the repository root.\n' >&2
    return 1
  fi
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1091
  source "${cfg}"
  set +a
  PACKMATE_NAMESPACE="${PACKMATE_NAMESPACE:-${PACKMATE_NS:-${PACKMATE_DEV_NAMESPACE:-packmate-lab}}}"
  PACKMATE_DEV_NAMESPACE="${PACKMATE_DEV_NAMESPACE:-${PACKMATE_NAMESPACE}}"
  PACKMATE_NAMESPACE="${PACKMATE_DEV_NAMESPACE}"
  PACKMATE_NS="${PACKMATE_NAMESPACE}"
  PACKMATE_PROD_NAMESPACE="${PACKMATE_PROD_NAMESPACE:-packmate-prod}"
  MODEL_NAMESPACE="${MODEL_NAMESPACE:-my-first-model}"
  MODEL_SERVICE="${MODEL_SERVICE:-llama-32-3b-instruct-predictor}"
  MODEL_ID="${MODEL_ID:-llama-32-3b-instruct}"
  ODH_APPLICATIONS_NS="${ODH_APPLICATIONS_NS:-redhat-ods-applications}"
  REGISTER_MCP="${REGISTER_MCP:-true}"
  ENABLE_CUSTOM_ENDPOINTS="${ENABLE_CUSTOM_ENDPOINTS:-true}"
  CREATE_MODEL_CUSTOM_ENDPOINT="${CREATE_MODEL_CUSTOM_ENDPOINT:-true}"
  CREATE_PIPELINE="${CREATE_PIPELINE:-true}"
  CREATE_ARGOCD_APPLICATION="${CREATE_ARGOCD_APPLICATION:-true}"
  CREATE_PROD_NAMESPACE="${CREATE_PROD_NAMESPACE:-true}"
  CREATE_PROD_SECRETS="${CREATE_PROD_SECRETS:-true}"
  CREATE_ARGOCD_RBAC="${CREATE_ARGOCD_RBAC:-true}"
  ALLOW_CREATE_NAMESPACE="${ALLOW_CREATE_NAMESPACE:-false}"
  SKIP_CONFIRM="${SKIP_CONFIRM:-false}"
  CANONICAL_GIT_REPO_URL="${CANONICAL_GIT_REPO_URL:-https://github.com/Lindagh1/packmate-agent.git}"
  # Writable fork URL — do not default to canonical upstream
  GIT_REPO_URL="${GIT_REPO_URL:-}"
  GIT_REVISION="${GIT_REVISION:-packmate-v2}"
  PROMOTION_BASE_BRANCH="${PROMOTION_BASE_BRANCH:-${GIT_REVISION}}"
  ALLOW_CANONICAL_REPO_PROMOTION="${ALLOW_CANONICAL_REPO_PROMOTION:-false}"
  LLM_BASE_URL="${LLM_BASE_URL:-http://${MODEL_SERVICE}.${MODEL_NAMESPACE}.svc.cluster.local:8080/v1}"
  LLM_MODEL="${LLM_MODEL:-${MODEL_ID}}"
  LITELLM_API_KEY="${LITELLM_API_KEY:-dummy}"
  PACKMATE_MODEL_DISPLAY_NAME="${PACKMATE_MODEL_DISPLAY_NAME:-Packmate Llama 3.2 3B}"
  PACKMATE_MODEL_USE_CASE="${PACKMATE_MODEL_USE_CASE:-Packmate travel planning, weather and baggage tool calling}"
  PACKMATE_ARGO_GROUP="${PACKMATE_ARGO_GROUP:-packmate-lab-users}"
  PACKMATE_PARTICIPANT_USER="${PACKMATE_PARTICIPANT_USER:-}"
  DISABLE_ARGOCD_LOCAL_ADMIN="${DISABLE_ARGOCD_LOCAL_ADMIN:-false}"
  export PACKMATE_NAMESPACE PACKMATE_NS PACKMATE_DEV_NAMESPACE PACKMATE_PROD_NAMESPACE
  export MODEL_NAMESPACE MODEL_SERVICE MODEL_ID
  export ODH_APPLICATIONS_NS REGISTER_MCP ENABLE_CUSTOM_ENDPOINTS CREATE_MODEL_CUSTOM_ENDPOINT CREATE_PIPELINE
  export CREATE_ARGOCD_APPLICATION CREATE_PROD_NAMESPACE CREATE_PROD_SECRETS CREATE_ARGOCD_RBAC
  export ALLOW_CREATE_NAMESPACE SKIP_CONFIRM
  export CANONICAL_GIT_REPO_URL GIT_REPO_URL GIT_REVISION PROMOTION_BASE_BRANCH ALLOW_CANONICAL_REPO_PROMOTION
  export LLM_BASE_URL LLM_MODEL LITELLM_API_KEY
  export BACKEND_IMAGE FRONTEND_IMAGE WEATHER_MCP_IMAGE BAGGAGE_POLICY_MCP_IMAGE
  export PACKMATE_MODEL_DISPLAY_NAME PACKMATE_MODEL_USE_CASE MODEL_TOKEN
  export PACKMATE_ARGO_GROUP PACKMATE_PARTICIPANT_USER DISABLE_ARGOCD_LOCAL_ADMIN
}

packmate_log() { printf '%s\n' "$*"; }
packmate_die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

packmate_require_oc() {
  command -v oc >/dev/null || packmate_die "oc CLI not found"
  oc whoami >/dev/null 2>&1 || packmate_die "not logged in to OpenShift (oc whoami failed)"
}

packmate_require_human_user() {
  local user
  user="$(oc whoami 2>/dev/null || true)"
  [[ -n "${user}" ]] || packmate_die "BLOCKED_OPENSHIFT_AUTHENTICATION — run: oc login --web"
  if [[ "${user}" == system:serviceaccount:* ]]; then
    cat >&2 <<EOF
BLOCKED_OPENSHIFT_SERVICE_ACCOUNT_IDENTITY
DETAIL  oc is authenticated as ${user}
ACTION  Run: oc logout
ACTION  Run: oc login --web
ACTION  Confirm your human sandbox username with: oc whoami
EOF
    return 1
  fi
  printf 'PASS  OpenShift human identity confirmed (%s)\n' "${user}"
}

packmate_api_has() {
  local pattern="$1"
  oc api-resources 2>/dev/null | grep -Ei "${pattern}" >/dev/null 2>&1
}

packmate_discover_model_url() {
  local ns="${MODEL_NAMESPACE}"
  local svc="${MODEL_SERVICE}"
  oc get svc "${svc}" -n "${ns}" >/dev/null 2>&1 || return 1
  local svc_port target cluster_ip
  svc_port="$(oc get svc "${svc}" -n "${ns}" -o jsonpath='{.spec.ports[0].port}')"
  target="$(oc get svc "${svc}" -n "${ns}" -o jsonpath='{.spec.ports[0].targetPort}')"
  cluster_ip="$(oc get svc "${svc}" -n "${ns}" -o jsonpath='{.spec.clusterIP}')"
  local probe_port="${svc_port}"
  if [[ "${cluster_ip}" == "None" || -z "${cluster_ip}" ]]; then
    probe_port="${target}"
  fi
  PACKMATE_MODEL_SVC_PORT="${svc_port}"
  PACKMATE_MODEL_TARGET_PORT="${target}"
  PACKMATE_MODEL_PROBE_PORT="${probe_port}"
  PACKMATE_MODEL_BASE_URL="http://${svc}.${ns}.svc.cluster.local:${probe_port}/v1"
  PACKMATE_MODEL_AUTH="$(oc get svc "${svc}" -n "${ns}" -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/enable-auth}' 2>/dev/null || true)"
  export PACKMATE_MODEL_SVC_PORT PACKMATE_MODEL_TARGET_PORT PACKMATE_MODEL_PROBE_PORT
  export PACKMATE_MODEL_BASE_URL PACKMATE_MODEL_AUTH
}
