#!/usr/bin/env bash
# Configure Argo CD RBAC so packmate-lab participants can Sync only the
# packmate-prod Application (via the AppProject "promoter" role) — never
# role:admin, never the cluster-admins group. Idempotent.
#
# Does NOT print the Argo CD admin password and does NOT fetch admin Secret
# values to stdout.
#
# Env vars:
#   PACKMATE_ARGO_GROUP           OpenShift group for lab participants (default: packmate-lab-users)
#   PACKMATE_PARTICIPANT_USER     User added to the group (default: `oc whoami`)
#   DISABLE_ARGOCD_LOCAL_ADMIN    "true" to disable the local Argo CD admin account (default: false)
#   ARGOCD_NAMESPACE              Namespace hosting the ArgoCD CR (default: openshift-gitops)
#   ARGOCD_NAME                   Name of the ArgoCD CR (default: autodetected)
#   GIT_REPO_URL                  Repo URL substituted into argocd/appproject-packmate.yaml
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
if [[ -f "${ROOT}/scripts/lib/sandbox-common.sh" ]]; then
  source "${ROOT}/scripts/lib/sandbox-common.sh"
fi

if declare -F packmate_log >/dev/null 2>&1; then
  log() { packmate_log "$*"; }
  die() { packmate_die "$*"; }
else
  log() { printf '%s\n' "$*"; }
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
fi
warn() { printf 'WARN: %s\n' "$*" >&2; }

# Load config/sandbox.env if present (best-effort — only for GIT_REPO_URL).
if declare -F packmate_load_config >/dev/null 2>&1; then
  packmate_load_config "${ROOT}" 2>/dev/null || true
fi

command -v oc >/dev/null 2>&1 || die "oc CLI not found"
oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift (oc whoami failed)"
if declare -F packmate_require_human_user >/dev/null 2>&1; then
  packmate_require_human_user || exit 1
fi

PACKMATE_ARGO_GROUP="${PACKMATE_ARGO_GROUP:-packmate-lab-users}"
PACKMATE_PARTICIPANT_USER="${PACKMATE_PARTICIPANT_USER:-$(oc whoami)}"
DISABLE_ARGOCD_LOCAL_ADMIN="${DISABLE_ARGOCD_LOCAL_ADMIN:-false}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
GIT_REPO_URL="${GIT_REPO_URL:-}"
BACKUP_FILE="/tmp/argocd-before-packmate-rbac.yaml"

[[ -n "${GIT_REPO_URL}" ]] || die "GIT_REPO_URL must be set to your fork URL (config/sandbox.env)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/fork-safety.sh"
if packmate_is_canonical_owner_repo "${GIT_REPO_URL}" \
  && [[ "${ALLOW_CANONICAL_REPO_PROMOTION:-false}" != "true" ]]; then
  die "GIT_REPO_URL must be your GitHub fork, not Lindagh1/packmate-agent"
fi

log "=== Packmate Argo CD lab RBAC ==="
log "group=${PACKMATE_ARGO_GROUP} user=${PACKMATE_PARTICIPANT_USER} namespace=${ARGOCD_NAMESPACE}"
log "disable_local_admin=${DISABLE_ARGOCD_LOCAL_ADMIN}"
log "git_repo_url=${GIT_REPO_URL}"

# ---------------------------------------------------------------------------
# 1) Detect the ArgoCD CR
# ---------------------------------------------------------------------------
if ! oc get crd argocds.argoproj.io >/dev/null 2>&1; then
  die "ArgoCD CRD not found — OpenShift GitOps operator not installed. See docs/INSTALL_GITOPS_PREREQUISITE.md"
fi

if [[ -z "${ARGOCD_NAME:-}" ]]; then
  ARGOCD_NAME="$(oc get argocd -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
[[ -n "${ARGOCD_NAME}" ]] || die "no ArgoCD CR found in namespace ${ARGOCD_NAMESPACE} (oc get argocd -n ${ARGOCD_NAMESPACE})"
log "OK: ArgoCD CR ${ARGOCD_NAME} found in ${ARGOCD_NAMESPACE}"

# ---------------------------------------------------------------------------
# 2) Backup current ArgoCD CR YAML (idempotent — always refreshed)
# ---------------------------------------------------------------------------
oc get argocd "${ARGOCD_NAME}" -n "${ARGOCD_NAMESPACE}" -o yaml > "${BACKUP_FILE}"
log "OK: backed up current ArgoCD CR to ${BACKUP_FILE}"

# ---------------------------------------------------------------------------
# 3) Patch spec.rbac.scopes to include "groups" — merge carefully, never
#    touch spec.rbac.policy / defaultPolicy, never grant role:admin here.
# ---------------------------------------------------------------------------
PATCH_FILE="$(mktemp)"
NEEDS_PATCH="$(python3 - "${ARGOCD_NAMESPACE}" "${ARGOCD_NAME}" "${PATCH_FILE}" <<'PY'
import json
import subprocess
import sys

ns, name, patch_file = sys.argv[1:4]

r = subprocess.run(["oc", "get", "argocd", name, "-n", ns, "-o", "json"], capture_output=True, text=True)
if r.returncode != 0:
    print(f"ERROR: cannot read ArgoCD CR: {r.stderr.strip()}", file=sys.stderr)
    sys.exit(2)
cr = json.loads(r.stdout)

spec = cr.get("spec", {}) or {}
rbac = spec.get("rbac", {}) or {}
current_scopes = rbac.get("scopes", "") or ""

# scopes is a string like "[groups, email]" — parse the bracket contents.
inner = current_scopes.strip()
if inner.startswith("[") and inner.endswith("]"):
    inner = inner[1:-1]
parts = [p.strip() for p in inner.split(",") if p.strip()]

if "groups" in parts:
    print("false")  # already configured — no-op
    sys.exit(0)

parts.append("groups")
new_scopes = "[" + ", ".join(parts) + "]"

patch = {"spec": {"rbac": {"scopes": new_scopes}}}
with open(patch_file, "w") as f:
    json.dump(patch, f)
print("true")
PY
)"

if [[ "${NEEDS_PATCH}" == "true" ]]; then
  oc patch argocd "${ARGOCD_NAME}" -n "${ARGOCD_NAMESPACE}" --type=merge --patch-file "${PATCH_FILE}" >/dev/null
  log "OK: patched spec.rbac.scopes to include 'groups' (policy/defaultPolicy untouched)"
else
  log "OK: spec.rbac.scopes already includes 'groups' — no patch needed (idempotent)"
fi
rm -f "${PATCH_FILE}"

# ---------------------------------------------------------------------------
# 4) Optional: disable local Argo CD admin account
# ---------------------------------------------------------------------------
if [[ "${DISABLE_ARGOCD_LOCAL_ADMIN}" == "true" ]]; then
  CURRENT_DISABLE="$(oc get argocd "${ARGOCD_NAME}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.disableAdmin}' 2>/dev/null || true)"
  if [[ "${CURRENT_DISABLE}" == "true" ]]; then
    log "OK: spec.disableAdmin already true — no patch needed (idempotent)"
  else
    oc patch argocd "${ARGOCD_NAME}" -n "${ARGOCD_NAMESPACE}" --type=merge -p '{"spec":{"disableAdmin":true}}' >/dev/null
    log "OK: patched spec.disableAdmin=true"
  fi
else
  log "SKIP: DISABLE_ARGOCD_LOCAL_ADMIN=false — local admin account left as-is"
fi

# ---------------------------------------------------------------------------
# 5) Create the OpenShift Group and add the participant user — idempotent.
#    Never uses cluster-admins; never grants role:admin to participants.
# ---------------------------------------------------------------------------
if oc get group "${PACKMATE_ARGO_GROUP}" >/dev/null 2>&1; then
  log "OK: group/${PACKMATE_ARGO_GROUP} already exists"
else
  oc adm groups new "${PACKMATE_ARGO_GROUP}" >/dev/null
  log "OK: created group/${PACKMATE_ARGO_GROUP}"
fi

if [[ -n "${PACKMATE_PARTICIPANT_USER}" ]]; then
  EXISTING_MEMBERS="$(oc get group "${PACKMATE_ARGO_GROUP}" -o jsonpath='{.users[*]}' 2>/dev/null || true)"
  if grep -qw "${PACKMATE_PARTICIPANT_USER}" <<<"${EXISTING_MEMBERS}"; then
    log "OK: user ${PACKMATE_PARTICIPANT_USER} already in group/${PACKMATE_ARGO_GROUP}"
  else
    oc adm groups add-users "${PACKMATE_ARGO_GROUP}" "${PACKMATE_PARTICIPANT_USER}" >/dev/null
    log "OK: added ${PACKMATE_PARTICIPANT_USER} to group/${PACKMATE_ARGO_GROUP}"
  fi
else
  warn "no PACKMATE_PARTICIPANT_USER resolved (oc whoami failed) — group membership not changed"
fi

# ---------------------------------------------------------------------------
# 6) Re-apply the AppProject with the "promoter" role (Sync on packmate-prod
#    only — never role:admin, never cluster-admins) if the file is present.
# ---------------------------------------------------------------------------
APPPROJECT_FILE="${ROOT}/argocd/appproject-packmate.yaml"
if [[ -f "${APPPROJECT_FILE}" ]]; then
  sed -e "s|__GIT_REPO_URL__|${GIT_REPO_URL}|g" \
      -e "s|__PACKMATE_ARGO_GROUP__|${PACKMATE_ARGO_GROUP}|g" \
      "${APPPROJECT_FILE}" | oc apply -f - >/dev/null
  log "OK: re-applied argocd/appproject-packmate.yaml (participant/promoter roles -> group ${PACKMATE_ARGO_GROUP})"
else
  warn "argocd/appproject-packmate.yaml not found — skipping AppProject re-apply"
fi

# ---------------------------------------------------------------------------
# 7) Document the SSO reconnect requirement
# ---------------------------------------------------------------------------
cat <<EOF

=== Reconnect required ===
Argo CD reads OpenShift group membership from the OAuth token issued at
login time. Participants added to '${PACKMATE_ARGO_GROUP}' must LOG OUT and
LOG BACK IN to the Argo CD UI (Log in via OpenShift) for the new group
membership — and therefore get on packmate-lab + packmate-prod and Sync on
packmate-prod — to take effect. Open User Info and confirm group claims.
Never use the local Argo CD admin password.

Backup of the ArgoCD CR before this run: ${BACKUP_FILE}
EOF

log "Done."
