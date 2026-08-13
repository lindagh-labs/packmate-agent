#!/usr/bin/env bash
# Validate rendered Packmate Pipeline YAML (non-destructive).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${PACKMATE_RENDERED_PIPELINE:-${ROOT}/.generated/tekton/packmate-ci.yaml}"
TPL="${ROOT}/.tekton/lab/packmate-ci.yaml.tpl"
OBSOLETE_PY="sha256:ae2c1317fa423c188c408d81e61b87dbc5b559577272ac189bea4eede92661cb"
OBSOLETE_CLI="sha256:dd7dab5b6ec92b6eecefec17f84bb3df525692f39a44f3d8c22b4469e420f0f3"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS  %s\n' "$*"; }

[[ -f "${TPL}" ]] || die "Missing template ${TPL}"
grep -q "${OBSOLETE_PY}" "${TPL}" && die "Template contains obsolete Python digest"
grep -q "${OBSOLETE_CLI}" "${TPL}" && die "Template contains obsolete CLI digest"
grep -q '__PACKMATE_PIPELINE_PYTHON_IMAGE__' "${TPL}" || die "Template missing Python placeholder"
for placeholder in \
  __PACKMATE_GIT_REPO_URL__ __PACKMATE_GIT_REVISION__ \
  __PACKMATE_PROMOTION_REGISTRY__ __PACKMATE_PROMOTION_REGISTRY_OWNER__ \
  __PACKMATE_PROMOTION_IMAGE_NAME__; do
  grep -q "${placeholder}" "${TPL}" || die "Template missing ${placeholder}"
done
pass "Pipeline template OK"

if [[ ! -f "${OUT}" ]]; then
  if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
    PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE="${PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE:-true}" \
      bash "${ROOT}/scripts/render-packmate-pipeline.sh" >/dev/null
  else
    # Offline validation uses syntactically valid non-pullable examples. Bootstrap
    # always overwrites this generated file with live cluster digests.
    PACKMATE_PIPELINE_PYTHON_IMAGE='registry.example.invalid/openshift/python@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    PACKMATE_PIPELINE_CLI_IMAGE='registry.example.invalid/openshift/cli@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE=true \
      bash "${ROOT}/scripts/render-packmate-pipeline.sh" >/dev/null
  fi
fi
[[ -f "${OUT}" ]] || die "Rendered Pipeline missing: ${OUT}"
grep -q '__PACKMATE_PIPELINE_PYTHON_IMAGE__' "${OUT}" && die "Unresolved Python placeholder in ${OUT}"
grep -q '__PACKMATE_PIPELINE_CLI_IMAGE__' "${OUT}" && die "Unresolved CLI placeholder in ${OUT}"
grep -q '__PACKMATE_' "${OUT}" && die "Unresolved participant placeholder in ${OUT}"
grep -q "${OBSOLETE_PY}" "${OUT}" && die "Obsolete Python digest in rendered file"
grep -qE '^\s+image:.*:latest([[:space:]]|$)' "${OUT}" && die ":latest image in rendered Pipeline"
pass "Rendered Pipeline file OK (${OUT})"

if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
  oc apply --dry-run=client -f "${OUT}" >/dev/null || die "client dry-run failed"
  pass "oc apply --dry-run=client OK"
  NS="${PACKMATE_NAMESPACE:-packmate-lab}"
  if oc get project "${NS}" >/dev/null 2>&1; then
    if oc apply --dry-run=server -n "${NS}" -f "${OUT}" >/dev/null 2>&1; then
      pass "oc apply --dry-run=server OK"
    else
      printf 'WARNING  oc apply --dry-run=server unavailable\n'
    fi
  fi
fi

printf 'validate-pipeline: OK\n'
