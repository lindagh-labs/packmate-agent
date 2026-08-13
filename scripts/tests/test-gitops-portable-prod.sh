#!/usr/bin/env bash
# Non-destructive failure-scenario checks for GitOps + portable PROD images.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== GitOps / portable PROD failure-scenario checks ==="

# AppProject allows both destinations in Git
grep -q 'namespace: packmate-lab' "${ROOT}/argocd/appproject-packmate.yaml" \
  && grep -q 'namespace: packmate-prod' "${ROOT}/argocd/appproject-packmate.yaml" \
  && pass "AppProject template allows packmate-lab and packmate-prod" \
  || fail "AppProject destinations"

grep -q 'packmate/\*' "${ROOT}/argocd/appproject-packmate.yaml" \
  && pass "Participant get packmate/* policy present" \
  || fail "Participant get policy"

grep -q 'sync, packmate/packmate-prod' "${ROOT}/argocd/appproject-packmate.yaml" \
  && pass "Participant sync packmate-prod policy present" \
  || fail "Participant sync policy"

grep -q 'project: packmate' "${ROOT}/argocd/application-packmate-lab.yaml" \
  && pass "DEV Application uses AppProject packmate" \
  || fail "DEV Application project"

grep -q 'path: deploy/overlays/dev' "${ROOT}/argocd/application-packmate-lab.yaml" \
  && pass "DEV Application path is deploy/overlays/dev" \
  || fail "DEV path"

grep -q 'path: deploy/overlays/prod' "${ROOT}/argocd/application-packmate-prod.yaml" \
  && pass "PROD Application path is deploy/overlays/prod" \
  || fail "PROD path"

# No automated prune on either app
! grep -qE 'prune:\s*true' "${ROOT}/argocd/application-packmate-lab.yaml" \
  && ! grep -qE 'prune:\s*true' "${ROOT}/argocd/application-packmate-prod.yaml" \
  && pass "Prune disabled in Application manifests" \
  || fail "Prune must be false"

# PROD has no automated sync
! grep -q 'automated:' "${ROOT}/argocd/application-packmate-prod.yaml" \
  && pass "PROD automatic sync disabled in manifest" \
  || fail "PROD must not automate sync"

grep -q 'kind: ServiceAccount' "${ROOT}/argocd/application-packmate-prod.yaml" \
  && grep -q -- '-dockercfg-' "${ROOT}/argocd/application-packmate-prod.yaml" \
  && grep -q 'packmate-ghcr-pull' "${ROOT}/deploy/overlays/prod/kustomization.yaml" \
  && pass "PROD ignores only OpenShift-generated ServiceAccount pull secrets" \
  || fail "PROD ServiceAccount generated-field ignore"

# PROD overlay portable
! grep -qE 'image-registry\.openshift-image-registry\.svc' "${ROOT}/deploy/overlays/prod/kustomization.yaml" \
  && pass "PROD overlay has no internal registry reference" \
  || fail "PROD overlay must not use internal registry"

grep -Eq 'newName:[[:space:]]+ghcr\.io/[A-Za-z0-9_.-]+/packmate-backend' \
    "${ROOT}/deploy/overlays/prod/kustomization.yaml" \
  && pass "PROD backend uses durable GHCR image" \
  || fail "PROD backend durable GHCR image"

# DEV overlay must not declare Workbench/Pipeline kinds
if grep -RInE 'kind:\s*(Notebook|Pipeline|PipelineRun|Workbench)' "${ROOT}/deploy/overlays/dev" >/dev/null 2>&1; then
  fail "DEV overlay must not contain Workbench/Pipeline resources"
else
  pass "DEV overlay has no Workbench/Pipeline kinds"
fi

# Scripts exist
for s in check-openshift-gitops install-openshift-gitops-operator instructor-setup \
         diagnose-packmate-image-reference configure-promotion-registry publish-backend-candidate; do
  [[ -x "${ROOT}/scripts/${s}.sh" ]] && pass "script ${s}.sh present" || fail "script ${s}.sh"
done

# Promote rejects internal refs (dry logic)
grep -q 'BLOCKED_NON_PORTABLE_PROD_IMAGE_REFERENCE' "${ROOT}/scripts/promote-backend-image.sh" \
  && pass "promote script blocks non-portable refs" \
  || fail "promote portable guard"

# Fork-first: Applications never hard-code canonical repo
! grep -q 'https://github.com/Lindagh1/packmate-agent.git' \
    "${ROOT}/argocd/application-packmate-lab.yaml" \
    "${ROOT}/argocd/application-packmate-prod.yaml" \
  && pass "Application manifests do not hard-code canonical repo" \
  || fail "Application manifests must use __GIT_REPO_URL__"

grep -q 'BLOCKED_CANONICAL_REPOSITORY_PROMOTION' "${ROOT}/scripts/lib/fork-safety.sh" \
  && pass "fork-safety blocks canonical promotion" \
  || fail "fork-safety blocks canonical promotion"

# Pipeline has publish-candidate
grep -q 'name: publish-candidate' "${ROOT}/.tekton/lab/packmate-ci.yaml.tpl" \
  && pass "Pipeline includes publish-candidate" \
  || fail "publish-candidate task"

printf '\nfailure-scenario summary: PASS=%s FAIL=%s\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
