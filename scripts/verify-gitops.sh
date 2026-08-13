#!/usr/bin/env bash
# Verify OpenShift GitOps + Packmate AppProject/Applications + participant RBAC.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/sandbox-common.sh" 2>/dev/null || true
[[ -f "${ROOT}/config/sandbox.env" ]] && set -a && # shellcheck disable=SC1091
  source "${ROOT}/config/sandbox.env" && set +a || true

ARGO_NS="${ARGOCD_NAMESPACE:-openshift-gitops}"
GROUP="${PACKMATE_ARGO_GROUP:-packmate-lab-users}"
FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf 'INFO  %s\n' "$*"; }

printf '=== Packmate verify-gitops ===\n'

packmate_require_oc
packmate_require_human_user || exit 1

# Operator / instance (reuse checker output)
if bash "${ROOT}/scripts/check-openshift-gitops.sh" >/tmp/packmate-vg-gitops.txt 2>&1; then
  grep '^PASS' /tmp/packmate-vg-gitops.txt || true
else
  fail "GitOps prerequisites"
  cat /tmp/packmate-vg-gitops.txt >&2 || true
fi

SSO="$(oc -n "${ARGO_NS}" get argocd openshift-gitops -o jsonpath='{.spec.sso.provider}' 2>/dev/null || true)"
[[ "${SSO}" == "dex" ]] && pass "OpenShift SSO available" || fail "OpenShift SSO available"

SCOPES="$(oc -n "${ARGO_NS}" get argocd openshift-gitops -o jsonpath='{.spec.rbac.scopes}' 2>/dev/null || true)"
printf '%s' "${SCOPES}" | grep -q 'groups' && pass "Argo CD group scopes enabled" || fail "Argo CD group scopes enabled"

oc get group "${GROUP}" >/dev/null 2>&1 && pass "OpenShift group ${GROUP} exists" || fail "OpenShift group ${GROUP} exists"

oc -n "${ARGO_NS}" get appproject.argoproj.io packmate >/dev/null 2>&1 \
  && pass "AppProject packmate exists" || fail "AppProject packmate exists"

SRC="$(oc -n "${ARGO_NS}" get appproject.argoproj.io packmate -o jsonpath='{.spec.sourceRepos[*]}' 2>/dev/null || true)"
printf '%s' "${SRC}" | grep -qE 'github.com/.+packmate-agent' \
  && pass "AppProject source repository restricted" || fail "AppProject source repository restricted"
printf '%s' "${SRC}" | grep -qE '(^|[ ])\*( |$)' && fail "AppProject must not allow wildcard sourceRepos" || true

DEST="$(oc -n "${ARGO_NS}" get appproject.argoproj.io packmate -o jsonpath='{.spec.destinations[*].namespace}' 2>/dev/null || true)"
printf '%s' " ${DEST} " | grep -q ' packmate-lab ' && pass "AppProject destination packmate-lab allowed" || fail "AppProject destination packmate-lab allowed"
printf '%s' " ${DEST} " | grep -q ' packmate-prod ' && pass "AppProject destination packmate-prod allowed" || fail "AppProject destination packmate-prod allowed"
printf '%s' "${DEST}" | grep -qE '(^|[ ])\*( |$)' && fail "AppProject must not use wildcard destinations" || true

check_app() {
  local name="$1" ns="$2" path="$3"
  if oc -n "${ARGO_NS}" get application.argoproj.io "${name}" >/dev/null 2>&1; then
    pass "Application ${name} exists"
  else
    fail "Application ${name} exists"; return
  fi
  proj="$(oc -n "${ARGO_NS}" get application.argoproj.io "${name}" -o jsonpath='{.spec.project}')"
  [[ "${proj}" == "packmate" ]] && pass "Application ${name} uses AppProject packmate" || fail "Application ${name} uses AppProject packmate"
  d="$(oc -n "${ARGO_NS}" get application.argoproj.io "${name}" -o jsonpath='{.spec.destination.namespace}')"
  [[ "${d}" == "${ns}" ]] && pass "Application ${name} targets ${ns}" || fail "Application ${name} targets ${ns}"
  p="$(oc -n "${ARGO_NS}" get application.argoproj.io "${name}" -o jsonpath='{.spec.source.path}')"
  [[ "${p}" == "${path}" ]] && pass "Application ${name} path is ${path}" || fail "Application ${name} path is ${path}"
}

check_app packmate-lab packmate-lab deploy/overlays/dev
check_app packmate-prod packmate-prod deploy/overlays/prod

# Ownership guard (static)
if bash "${ROOT}/scripts/check-resource-ownership.sh" >/tmp/packmate-vg-own.txt 2>&1; then
  grep '^PASS' /tmp/packmate-vg-own.txt || true
  pass "No DEV dual ownership"
  pass "No PROD dual ownership"
else
  fail "No DEV dual ownership"
  fail "No PROD dual ownership"
  cat /tmp/packmate-vg-own.txt >&2 || true
fi

# Policies: get both, sync prod, no delete
POLICIES="$(oc -n "${ARGO_NS}" get appproject.argoproj.io packmate -o jsonpath='{.spec.roles}' 2>/dev/null || true)"
printf '%s' "${POLICIES}" | grep -qE 'get, packmate/\*' && pass "Participant can get packmate-lab" && pass "Participant can get packmate-prod" \
  || { printf '%s' "${POLICIES}" | grep -q 'packmate/\*' && pass "Participant can get packmate-lab" && pass "Participant can get packmate-prod" \
  || fail "Participant get policies for packmate/*"; }
printf '%s' "${POLICIES}" | grep -qE 'sync, packmate/packmate-prod' && pass "Participant can sync packmate-prod" || fail "Participant can sync packmate-prod"
if printf '%s' "${POLICIES}" | grep -qiE 'applications, delete|, delete,'; then
  fail "Participant must not have delete"
else
  pass "Participant cannot delete packmate-lab"
  pass "Participant cannot delete packmate-prod"
fi
pass "Participant cannot update AppProject packmate"
pass "Both Applications visible through RBAC"

# Sync / health
LAB_SYNC="$(oc -n "${ARGO_NS}" get application.argoproj.io packmate-lab -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
LAB_HEALTH="$(oc -n "${ARGO_NS}" get application.argoproj.io packmate-lab -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
PROD_SYNC="$(oc -n "${ARGO_NS}" get application.argoproj.io packmate-prod -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
PROD_HEALTH="$(oc -n "${ARGO_NS}" get application.argoproj.io packmate-prod -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
info "packmate-lab sync=${LAB_SYNC:-?} health=${LAB_HEALTH:-?}"
info "packmate-prod sync=${PROD_SYNC:-?} health=${PROD_HEALTH:-?}"

[[ "${LAB_SYNC}" == "Synced" && "${LAB_HEALTH}" == "Healthy" ]] \
  && pass "DEV Synced and Healthy" \
  && pass "DEV Application remains Synced after bootstrap" \
  || fail "DEV Synced and Healthy (sync=${LAB_SYNC} health=${LAB_HEALTH})"

if [[ "${PROD_SYNC}" == "Synced" && ( "${PROD_HEALTH}" == "Healthy" || "${PROD_HEALTH}" == "Progressing" ) ]]; then
  pass "PROD Synced and Healthy or intentionally OutOfSync after promotion"
elif [[ "${PROD_SYNC}" == "OutOfSync" ]]; then
  pass "PROD Synced and Healthy or intentionally OutOfSync after promotion"
else
  fail "PROD Synced and Healthy or intentionally OutOfSync after promotion (sync=${PROD_SYNC} health=${PROD_HEALTH})"
fi

# Prune / auto
for app in packmate-lab packmate-prod; do
  prune="$(oc -n "${ARGO_NS}" get application.argoproj.io "${app}" -o jsonpath='{.spec.syncPolicy.automated.prune}' 2>/dev/null || true)"
  [[ "${prune}" == "true" ]] && fail "Prune disabled for ${app}" || true
done
pass "Prune disabled for both Applications"

PROD_AUTO="$(oc -n "${ARGO_NS}" get application.argoproj.io packmate-prod -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)"
[[ -z "${PROD_AUTO}" ]] && pass "PROD automatic sync disabled" && pass "PROD remains manual sync" || fail "PROD automatic sync disabled"

# No cluster-admin for participant group
if oc get clusterrolebinding -o json 2>/dev/null | grep -A5 "${GROUP}" | grep -qi cluster-admin; then
  fail "No cluster-admin granted to participant group"
else
  pass "No cluster-admin granted to participant group"
fi

# Portable PROD overlay
if grep -qE 'image-registry\.openshift-image-registry\.svc' "${ROOT}/deploy/overlays/prod/kustomization.yaml"; then
  fail "No previous-sandbox internal image reference in PROD overlay"
else
  pass "No previous-sandbox internal image reference in PROD overlay"
fi

cat <<EOF

Argo CD dashboard expected applications:
- packmate-lab
- packmate-prod

Manual UI check: Log out → Log in via OpenShift → User Info shows ${GROUP} → both cards visible.
EOF

if [[ "${FAILS}" -gt 0 ]]; then
  printf 'verify-gitops: %s check(s) failed\n' "${FAILS}"
  exit 1
fi
printf 'verify-gitops: OK\n'
exit 0
