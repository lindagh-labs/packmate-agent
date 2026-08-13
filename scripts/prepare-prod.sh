#!/usr/bin/env bash
# Prepare the packmate-prod namespace for a GitOps-managed deploy — creates
# the namespace, the LLM secret, cross-namespace image-pull RBAC, and the
# Argo CD AppProject/Application. Idempotent.
#
# Does NOT `oc apply -k deploy/overlays/prod` (workloads are deployed only
# by Argo CD Application packmate-prod, manual Sync). Never prints secret
# values.
#
# Env vars:
#   LLM_BASE_URL, LLM_MODEL, LITELLM_API_KEY   Required — packmate-prod-llm Secret contents (never printed)
#   PACKMATE_LAB_NAMESPACE                     Source namespace for image pulls (default: packmate-lab)
#   PACKMATE_PROD_NAMESPACE                    Target namespace (default: packmate-prod)
#   GIT_REPO_URL, GIT_REVISION                 Substituted into argocd/*.yaml (defaults from config/sandbox.env if present)
#   PACKMATE_ARGO_GROUP                        Substituted into argocd/appproject-packmate.yaml (default: packmate-lab-users)
#   CREATE_ARGOCD_RBAC                         "true" to also run scripts/configure-argocd-lab-rbac.sh (default: false)
#   ARGOCD_RBAC_FALLBACK                       "true" to allow the minimal RoleBinding fallback documented in step 6 (default: false)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
if [[ -f "${ROOT}/scripts/lib/sandbox-common.sh" ]]; then
  source "${ROOT}/scripts/lib/sandbox-common.sh"
fi
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/ensure-secret.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/promotion-registry.sh"

if declare -F packmate_log >/dev/null 2>&1; then
  log() { packmate_log "$*"; }
  die() { packmate_die "$*"; }
else
  log() { printf '%s\n' "$*"; }
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
fi
warn() { printf 'WARN: %s\n' "$*" >&2; }

if declare -F packmate_load_config >/dev/null 2>&1; then
  # Best-effort — only used for GIT_REPO_URL/GIT_REVISION/LLM_* defaults.
  packmate_load_config "${ROOT}" 2>/dev/null || true
fi

command -v oc >/dev/null 2>&1 || die "oc CLI not found"
oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift (oc whoami failed)"
if declare -F packmate_require_human_user >/dev/null 2>&1; then
  packmate_require_human_user || exit 1
elif [[ "$(oc whoami)" == system:serviceaccount:* ]]; then
  die "BLOCKED_OPENSHIFT_SERVICE_ACCOUNT_IDENTITY — run oc logout, then oc login --web"
fi

PACKMATE_LAB_NAMESPACE="${PACKMATE_LAB_NAMESPACE:-packmate-lab}"
PACKMATE_PROD_NAMESPACE="${PACKMATE_PROD_NAMESPACE:-packmate-prod}"
GIT_REPO_URL="${GIT_REPO_URL:-}"
GIT_REVISION="${GIT_REVISION:-packmate-v2}"
PACKMATE_ARGO_GROUP="${PACKMATE_ARGO_GROUP:-packmate-lab-users}"
CREATE_ARGOCD_RBAC="${CREATE_ARGOCD_RBAC:-false}"
ARGOCD_RBAC_FALLBACK="${ARGOCD_RBAC_FALLBACK:-false}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"

[[ -n "${GIT_REPO_URL}" ]] || die "GIT_REPO_URL must be set to your fork URL (config/sandbox.env)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/fork-safety.sh"
if packmate_is_canonical_owner_repo "${GIT_REPO_URL}" \
  && [[ "${ALLOW_CANONICAL_REPO_PROMOTION:-false}" != "true" ]]; then
  die "GIT_REPO_URL must be your GitHub fork, not Lindagh1/packmate-agent"
fi

log "=== Packmate prepare-prod ==="
log "lab_namespace=${PACKMATE_LAB_NAMESPACE} prod_namespace=${PACKMATE_PROD_NAMESPACE}"
log "git_repo_url=${GIT_REPO_URL} git_revision=${GIT_REVISION}"

# ---------------------------------------------------------------------------
# 1) Namespace packmate-prod — labels: packmate.io/environment=prod only.
#    Deliberately NOT the DSP/lab labels (opendatahub.io/dashboard,
#    modelmesh-enabled) used for the packmate-lab Data Science Project.
# ---------------------------------------------------------------------------
if oc get project "${PACKMATE_PROD_NAMESPACE}" >/dev/null 2>&1; then
  log "OK: namespace/${PACKMATE_PROD_NAMESPACE} already exists"
else
  oc new-project "${PACKMATE_PROD_NAMESPACE}" --display-name="Packmate Production" >/dev/null
  log "OK: created namespace/${PACKMATE_PROD_NAMESPACE}"
fi
oc label namespace "${PACKMATE_PROD_NAMESPACE}" packmate.io/environment=prod --overwrite >/dev/null
log "OK: labeled namespace/${PACKMATE_PROD_NAMESPACE} packmate.io/environment=prod"

# Copy the participant's GHCR credential from DEV without exposing its value.
# Runtime ServiceAccounts reference the target Secret declaratively in Git.
PROMOTION_PUSH_SECRET="${PACKMATE_PROMOTION_PUSH_SECRET:-packmate-ghcr-push}"
PROMOTION_PULL_SECRET="${PACKMATE_PROMOTION_PULL_SECRET:-packmate-ghcr-pull}"
if oc -n "${PACKMATE_LAB_NAMESPACE}" get secret "${PROMOTION_PUSH_SECRET}" >/dev/null 2>&1; then
  packmate_copy_registry_secret \
    "${PACKMATE_LAB_NAMESPACE}" "${PROMOTION_PUSH_SECRET}" \
    "${PACKMATE_PROD_NAMESPACE}" "${PROMOTION_PULL_SECRET}" \
    || die "Failed to prepare PROD registry pull Secret"
  log "OK: prepared Secret/${PROMOTION_PULL_SECRET} for immutable GHCR candidates (value not shown)"
else
  die "Promotion registry Secret/${PROMOTION_PUSH_SECRET} missing — run make configure-promotion-registry"
fi

# ---------------------------------------------------------------------------
# 2) Secret packmate-prod-llm from LLM_* env — values never printed.
# ---------------------------------------------------------------------------
: "${LLM_BASE_URL:?LLM_BASE_URL must be set (never printed)}"
: "${LLM_MODEL:?LLM_MODEL must be set (never printed)}"
LLM_KEY="${LITELLM_API_KEY:-${LLM_API_KEY:-}}"
: "${LLM_KEY:?LITELLM_API_KEY (or LLM_API_KEY) must be set (never printed)}"

# Idempotent: create if missing; no-op if identical; refuse silent rotation.
packmate_ensure_opaque_secret "${PACKMATE_PROD_NAMESPACE}" packmate-prod-llm \
  "BASE_URL=${LLM_BASE_URL}" \
  "MODEL=${LLM_MODEL}" \
  "LITELLM_API_KEY=${LLM_KEY}" \
  || die "packmate-prod-llm Secret preparation failed (set ROTATE_PACKMATE_PROD_LLM_SECRET=true make rotate-prod-llm-secret to rotate intentionally)"
unset LLM_KEY

# ---------------------------------------------------------------------------
# 3) Cross-namespace image pull: grant system:image-puller in packmate-lab
#    to the packmate-prod ServiceAccounts.
# ---------------------------------------------------------------------------
log "==> Granting system:image-puller in ${PACKMATE_LAB_NAMESPACE} to ${PACKMATE_PROD_NAMESPACE} SAs"
for sa in packmate-backend packmate-frontend weather-mcp baggage-policy-mcp; do
  subject="system:serviceaccount:${PACKMATE_PROD_NAMESPACE}:${sa}"
  if oc -n "${PACKMATE_LAB_NAMESPACE}" auth can-i get imagestreams/layers --as="${subject}" >/dev/null 2>&1; then
    log "    OK: ${subject} already has image-puller access in ${PACKMATE_LAB_NAMESPACE}"
    continue
  fi
  oc -n "${PACKMATE_LAB_NAMESPACE}" adm policy add-role-to-user system:image-puller "${subject}" >/dev/null
  log "    OK: granted system:image-puller to ${subject}"
done

# ---------------------------------------------------------------------------
# 4) Verify: packmate-backend SA can read imagestreams/layers in packmate-lab
# ---------------------------------------------------------------------------
BACKEND_SUBJECT="system:serviceaccount:${PACKMATE_PROD_NAMESPACE}:packmate-backend"
if oc -n "${PACKMATE_LAB_NAMESPACE}" auth can-i get imagestreams/layers --as="${BACKEND_SUBJECT}" >/dev/null 2>&1; then
  log "OK: verified ${BACKEND_SUBJECT} can get imagestreams/layers in ${PACKMATE_LAB_NAMESPACE}"
else
  warn "verification failed: ${BACKEND_SUBJECT} cannot get imagestreams/layers in ${PACKMATE_LAB_NAMESPACE} — image pulls from ${PACKMATE_LAB_NAMESPACE} may fail"
fi

# ---------------------------------------------------------------------------
# 5) Argo CD AppProject + Applications (packmate-lab + packmate-prod)
# ---------------------------------------------------------------------------
PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE="${PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE:-true}"
if [[ "${PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE}" == "true" ]]; then
  if grep -qE 'image-registry\.openshift-image-registry\.svc|default-route-openshift-image-registry' \
    "${ROOT}/deploy/overlays/prod/kustomization.yaml"; then
    die "BLOCKED_OLD_SANDBOX_PROD_IMAGE_REFERENCE: The PROD overlay references an image from another sandbox. Promote a durable external image or restore the validated external baseline."
  fi
  log "OK: PROD overlay uses durable (non-internal) image references"
fi

REQUIRE_OPENSHIFT_GITOPS="${REQUIRE_OPENSHIFT_GITOPS:-true}"
if oc get crd applications.argoproj.io >/dev/null 2>&1; then
  if ! bash "${ROOT}/scripts/check-openshift-gitops.sh" >/tmp/packmate-prepare-gitops.txt 2>&1; then
    cat /tmp/packmate-prepare-gitops.txt >&2 || true
    if [[ "${REQUIRE_OPENSHIFT_GITOPS}" == "true" ]]; then
      die "GitOps not ready — instructor must run INSTALL_OPENSHIFT_GITOPS_OPERATOR=true make instructor-setup"
    fi
    warn "GitOps not fully ready — skipping Application apply"
  else
    log "==> Applying Argo CD AppProject + Applications (DEV + PROD)"
    bash "${ROOT}/scripts/apply-packmate-argocd.sh"
    log "OK: AppProject/packmate and Applications packmate-lab + packmate-prod applied"
  fi
else
  if [[ "${REQUIRE_OPENSHIFT_GITOPS}" == "true" ]]; then
    die "BLOCKED_GITOPS_OPERATOR_NOT_INSTALLED — see docs/INSTALL_GITOPS_PREREQUISITE.md"
  fi
  warn "ArgoCD CRDs not found — GitOps operator not installed. See docs/INSTALL_GITOPS_PREREQUISITE.md"
fi

# ---------------------------------------------------------------------------
# 6) Namespace GitOps management mechanism (also applied in apply-packmate-argocd).
# ---------------------------------------------------------------------------
oc label namespace "${PACKMATE_PROD_NAMESPACE}" argocd.argoproj.io/managed-by="${ARGOCD_NAMESPACE}" --overwrite >/dev/null
oc label namespace "${PACKMATE_LAB_NAMESPACE}" argocd.argoproj.io/managed-by="${ARGOCD_NAMESPACE}" --overwrite >/dev/null
log "OK: labeled namespaces managed-by=${ARGOCD_NAMESPACE}"

CONTROLLER_SUBJECT="system:serviceaccount:${ARGOCD_NAMESPACE}:${ARGOCD_NAMESPACE}-argocd-application-controller"
if oc -n "${PACKMATE_PROD_NAMESPACE}" auth can-i get deployments --as="${CONTROLLER_SUBJECT}" >/dev/null 2>&1; then
  log "OK: verified ${CONTROLLER_SUBJECT} has access in ${PACKMATE_PROD_NAMESPACE}"
else
  warn "managed-by label access not yet visible for ${CONTROLLER_SUBJECT} in ${PACKMATE_PROD_NAMESPACE}"
  if [[ "${ARGOCD_RBAC_FALLBACK}" == "true" ]]; then
    oc adm policy add-role-to-user edit "${CONTROLLER_SUBJECT}" -n "${PACKMATE_PROD_NAMESPACE}" >/dev/null
    oc adm policy add-role-to-user edit "${CONTROLLER_SUBJECT}" -n "${PACKMATE_LAB_NAMESPACE}" >/dev/null
    log "OK: fallback edit RoleBinding applied"
  fi
fi

# ---------------------------------------------------------------------------
# 7) Optional: participant Argo CD RBAC
# ---------------------------------------------------------------------------
if [[ "${CREATE_ARGOCD_RBAC}" == "true" ]]; then
  if oc get crd argocds.argoproj.io >/dev/null 2>&1; then
    log "==> CREATE_ARGOCD_RBAC=true — running scripts/configure-argocd-lab-rbac.sh"
    bash "${ROOT}/scripts/configure-argocd-lab-rbac.sh"
  else
    warn "CREATE_ARGOCD_RBAC=true but ArgoCD CRD absent — skip RBAC (install GitOps first)"
  fi
else
  log "SKIP: CREATE_ARGOCD_RBAC=false — not configuring participant Argo CD RBAC"
fi

cat <<EOF

=== prepare-prod complete ===
Namespace:        ${PACKMATE_PROD_NAMESPACE} (packmate.io/environment=prod)
Secret:            packmate-prod-llm (values not shown)
Image pull RBAC:   system:image-puller in ${PACKMATE_LAB_NAMESPACE} for packmate-prod SAs
GitOps namespace:  managed-by label = ${ARGOCD_NAMESPACE}
Argo CD:           AppProject/packmate, Applications packmate-lab + packmate-prod

Argo CD dashboard expected applications:
- packmate-lab
- packmate-prod

This script did NOT deploy PROD workloads via oc apply.
Sync Application/packmate-prod manually after promotion PRs.
EOF
