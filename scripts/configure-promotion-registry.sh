#!/usr/bin/env bash
# Create GHCR push (and optional pull) Secrets for portable promotion.
# Credentials from env or secure prompt — never argv, never echoed, never Git.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "${ROOT}/config/sandbox.env" ]] && set -a && source "${ROOT}/config/sandbox.env" && set +a || true
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/ensure-secret.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/sandbox-common.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/promotion-registry.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/fork-safety.sh"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PACKMATE_PROMOTION_REGISTRY="${PACKMATE_PROMOTION_REGISTRY:-ghcr.io}"
PACKMATE_PROMOTION_REGISTRY_OWNER="${PACKMATE_PROMOTION_REGISTRY_OWNER:-}"
PACKMATE_PROMOTION_IMAGE_NAME="${PACKMATE_PROMOTION_IMAGE_NAME:-packmate-backend}"
PACKMATE_PROMOTION_PUSH_SECRET="${PACKMATE_PROMOTION_PUSH_SECRET:-packmate-ghcr-push}"
PACKMATE_PROMOTION_PULL_SECRET="${PACKMATE_PROMOTION_PULL_SECRET:-packmate-ghcr-pull}"
LAB_NS="${PACKMATE_NAMESPACE:-packmate-lab}"
PROD_NS="${PACKMATE_PROD_NAMESPACE:-packmate-prod}"
PIPELINE_SA="${PACKMATE_PIPELINE_SA:-packmate-pipeline}"

packmate_require_oc
packmate_require_human_user || exit 1
oc get project "${LAB_NS}" >/dev/null 2>&1 \
  || die "Data Science Project ${LAB_NS} is missing — create it in OpenShift AI first"

[[ "${PACKMATE_PROMOTION_REGISTRY_OWNER}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
  || die "Invalid PACKMATE_PROMOTION_REGISTRY_OWNER — run make configure-participant"
CONFIGURED_REPO="$(packmate_normalize_github_owner_repo "${GIT_REPO_URL:-}" 2>/dev/null || true)"
[[ -n "${CONFIGURED_REPO}" ]] && ! packmate_is_canonical_owner_repo "${CONFIGURED_REPO}" \
  || die "GIT_REPO_URL is not a participant fork — run make configure-participant"
FORK_OWNER="${CONFIGURED_REPO%%/*}"
[[ "${PACKMATE_PROMOTION_REGISTRY_OWNER,,}" == "${FORK_OWNER,,}" ]] \
  || die "GHCR owner must match fork owner ${FORK_OWNER} — run make configure-participant"

USER_NAME="${PACKMATE_REGISTRY_USERNAME:-}"
TOKEN="${PACKMATE_REGISTRY_TOKEN:-}"

if [[ -z "${TOKEN}" ]] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
  [[ -n "${USER_NAME}" ]] || USER_NAME="$(gh api user -q .login 2>/dev/null || true)"
fi

if [[ -z "${USER_NAME}" ]]; then
  read -r -p "Registry username: " USER_NAME
fi
if [[ -z "${TOKEN}" ]]; then
  read -r -s -p "Registry token (input hidden): " TOKEN
  printf '\n'
fi
[[ -n "${USER_NAME}" && -n "${TOKEN}" ]] || die "Username and token required"

# Re-running this explicit command is the supported credential update operation.
PACKMATE_SECRET_ALLOW_ROTATION="${PACKMATE_SECRET_ALLOW_ROTATION:-true}" \
  packmate_ensure_docker_registry_secret \
    "${LAB_NS}" "${PACKMATE_PROMOTION_PUSH_SECRET}" \
    "${PACKMATE_PROMOTION_REGISTRY}" "${USER_NAME}" "${TOKEN}" \
  || die "Failed to ensure push Secret"

# Link to Pipeline SA — preserve unrelated imagePullSecrets
oc -n "${LAB_NS}" secrets link "${PIPELINE_SA}" "${PACKMATE_PROMOTION_PUSH_SECRET}" --for=pull,mount >/dev/null 2>&1 \
  || oc -n "${LAB_NS}" patch sa "${PIPELINE_SA}" --type merge -p \
    "{\"imagePullSecrets\":[{\"name\":\"${PACKMATE_PROMOTION_PUSH_SECRET}\"}],\"secrets\":[{\"name\":\"${PACKMATE_PROMOTION_PUSH_SECRET}\"}]}" >/dev/null 2>&1 \
  || true
log "OK: linked push Secret to SA/${PIPELINE_SA}"

if oc get project "${PROD_NS}" >/dev/null 2>&1; then
  packmate_copy_registry_secret \
    "${LAB_NS}" "${PACKMATE_PROMOTION_PUSH_SECRET}" \
    "${PROD_NS}" "${PACKMATE_PROMOTION_PULL_SECRET}" \
    || die "Failed to copy registry access into ${PROD_NS}"
  log "OK: Secret/${PACKMATE_PROMOTION_PULL_SECRET} ready in ${PROD_NS}"
else
  log "INFO: ${PROD_NS} is not created yet; bootstrap will copy registry access safely"
fi

unset TOKEN
log "configure-promotion-registry: complete (credentials are in OpenShift Secrets, not Git)"
