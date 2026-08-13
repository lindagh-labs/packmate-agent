#!/usr/bin/env bash
# Render the Pipeline with current-sandbox images and participant configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="${ROOT}/.tekton/lab/packmate-ci.yaml.tpl"
OUT_DIR="${ROOT}/.generated/tekton"
OUT="${PACKMATE_RENDERED_PIPELINE:-${OUT_DIR}/packmate-ci.yaml}"
OBSOLETE_PY_DIGEST="sha256:ae2c1317fa423c188c408d81e61b87dbc5b559577272ac189bea4eede92661cb"
OBSOLETE_CLI_DIGEST="sha256:dd7dab5b6ec92b6eecefec17f84bb3df525692f39a44f3d8c22b4469e420f0f3"
PY_PLACEHOLDER="__PACKMATE_PIPELINE_PYTHON_IMAGE__"
CLI_PLACEHOLDER="__PACKMATE_PIPELINE_CLI_IMAGE__"
GIT_URL_PLACEHOLDER="__PACKMATE_GIT_REPO_URL__"
GIT_REV_PLACEHOLDER="__PACKMATE_GIT_REVISION__"
REGISTRY_PLACEHOLDER="__PACKMATE_PROMOTION_REGISTRY__"
REGISTRY_OWNER_PLACEHOLDER="__PACKMATE_PROMOTION_REGISTRY_OWNER__"
IMAGE_NAME_PLACEHOLDER="__PACKMATE_PROMOTION_IMAGE_NAME__"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "${TPL}" ]] || die "Missing template: ${TPL}"

# Direct offline rendering uses harmless examples. Bootstrap exports the real
# participant settings from config/sandbox.env before calling this script.
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/example/packmate-agent.git}"
GIT_REVISION="${GIT_REVISION:-packmate-v2}"
PACKMATE_PROMOTION_REGISTRY="${PACKMATE_PROMOTION_REGISTRY:-ghcr.io}"
PACKMATE_PROMOTION_REGISTRY_OWNER="${PACKMATE_PROMOTION_REGISTRY_OWNER:-example}"
PACKMATE_PROMOTION_IMAGE_NAME="${PACKMATE_PROMOTION_IMAGE_NAME:-packmate-backend}"
[[ "${GIT_REPO_URL}" =~ ^https://github\.com/[A-Za-z0-9_.-]+/packmate-agent(\.git)?$ ]] \
  || die "GIT_REPO_URL must be a GitHub Packmate fork URL"
[[ "${GIT_REPO_URL,,}" != "https://github.com/lindagh1/packmate-agent"* ]] \
  || die "Refusing to render a participant Pipeline from canonical upstream"
git check-ref-format --branch "${GIT_REVISION}" >/dev/null 2>&1 \
  || die "Invalid GIT_REVISION=${GIT_REVISION}"
[[ "${PACKMATE_PROMOTION_REGISTRY}" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid promotion registry"
[[ "${PACKMATE_PROMOTION_REGISTRY_OWNER}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || die "Invalid promotion registry owner"
[[ "${PACKMATE_PROMOTION_IMAGE_NAME}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid promotion image name"

RESOLVE="${ROOT}/scripts/resolve-pipeline-python-image.sh"
[[ -f "${RESOLVE}" ]] || die "Missing ${RESOLVE}"

if [[ -n "${PACKMATE_PIPELINE_PYTHON_IMAGE:-}" ]]; then
  PY_IMG="${PACKMATE_PIPELINE_PYTHON_IMAGE}"
else
  PY_IMG="$(bash "${RESOLVE}")"
fi
[[ -n "${PY_IMG}" ]] || die "Resolved Python image is empty"
[[ "${PY_IMG}" != *":latest"* ]] || die "Resolved Python image must not use :latest"
[[ "${PY_IMG}" == *"@sha256:"* ]] || die "Resolved Python image must be digest-pinned"

if [[ -n "${PACKMATE_PIPELINE_CLI_IMAGE:-}" ]]; then
  CLI_IMG="${PACKMATE_PIPELINE_CLI_IMAGE}"
else
  CLI_IMG="$(
    PACKMATE_PIPELINE_PYTHON_IMAGE= \
    PACKMATE_PIPELINE_IMAGE_OVERRIDE= \
    PACKMATE_PIPELINE_ISTREAM_NAME=cli \
    PACKMATE_PIPELINE_ISTREAM_TAG=latest \
    PACKMATE_PIPELINE_IMAGE_PROBE=oc \
    PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE="${PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE:-false}" \
    PACKMATE_NAMESPACE="${PACKMATE_NAMESPACE:-packmate-lab}" \
      bash "${RESOLVE}"
  )"
fi
[[ -n "${CLI_IMG}" ]] || die "Resolved CLI image is empty"
[[ "${CLI_IMG}" != *":latest"* ]] || die "Resolved CLI image must not use :latest"
[[ "${CLI_IMG}" == *"@sha256:"* ]] || die "Resolved CLI image must be digest-pinned"

mkdir -p "$(dirname "${OUT}")"
python3 - "${TPL}" "${OUT}" \
  "${PY_PLACEHOLDER}" "${PY_IMG}" \
  "${CLI_PLACEHOLDER}" "${CLI_IMG}" \
  "${GIT_URL_PLACEHOLDER}" "${GIT_REPO_URL}" \
  "${GIT_REV_PLACEHOLDER}" "${GIT_REVISION}" \
  "${REGISTRY_PLACEHOLDER}" "${PACKMATE_PROMOTION_REGISTRY}" \
  "${REGISTRY_OWNER_PLACEHOLDER}" "${PACKMATE_PROMOTION_REGISTRY_OWNER}" \
  "${IMAGE_NAME_PLACEHOLDER}" "${PACKMATE_PROMOTION_IMAGE_NAME}" <<'PY'
import sys
tpl, out, *items = sys.argv[1:]
text = open(tpl, encoding="utf-8").read()
for ph, value in zip(items[::2], items[1::2]):
    if ph not in text:
        raise SystemExit(f"placeholder {ph} not found in template")
    text = text.replace(ph, value)
open(out, "w", encoding="utf-8").write(text)
PY

for ph in \
  "${PY_PLACEHOLDER}" "${CLI_PLACEHOLDER}" \
  "${GIT_URL_PLACEHOLDER}" "${GIT_REV_PLACEHOLDER}" \
  "${REGISTRY_PLACEHOLDER}" "${REGISTRY_OWNER_PLACEHOLDER}" "${IMAGE_NAME_PLACEHOLDER}"; do
  grep -q "${ph}" "${OUT}" && die "Unresolved placeholder ${ph} remains in ${OUT}"
done
grep -q "${OBSOLETE_PY_DIGEST}" "${OUT}" && die "Obsolete sandbox Python digest remains in ${OUT}"
grep -q "${OBSOLETE_CLI_DIGEST}" "${OUT}" && die "Obsolete sandbox CLI digest remains in ${OUT}"
grep -q "${OBSOLETE_PY_DIGEST}" "${TPL}" && die "Obsolete sandbox Python digest remains in template"
grep -q "${OBSOLETE_CLI_DIGEST}" "${TPL}" && die "Obsolete sandbox CLI digest remains in template"

python3 - "${OUT}" "${PY_IMG}" "${CLI_IMG}" "${GIT_REPO_URL}" "${GIT_REVISION}" "${PACKMATE_PROMOTION_REGISTRY_OWNER}" <<'PY'
import re, sys
path, py_expected, cli_expected, git_url, git_revision, registry_owner = sys.argv[1:7]
text = open(path, encoding="utf-8").read()
# Defaults and step images
if py_expected not in text:
    raise SystemExit("resolved python image missing from rendered Pipeline")
if cli_expected not in text:
    raise SystemExit("resolved cli image missing from rendered Pipeline")
images = re.findall(r'^\s+image:\s+(\S+)\s*$', text, flags=re.M)
# After param conversion, step images are $(params.python-image); digests appear in defaults.
latest = [i for i in images if i.endswith(":latest") or ":latest@" in i]
if latest:
    raise SystemExit(f":latest forbidden: {latest}")
for expected in (git_url, git_revision, registry_owner):
    if expected not in text:
        raise SystemExit(f"rendered participant value missing: {expected}")
print(f"rendered_ok python={py_expected.split('@')[-1][:19]}…", file=sys.stderr)
PY

if command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; then
  oc apply --dry-run=client -f "${OUT}" >/dev/null \
    || die "oc apply --dry-run=client failed for rendered Pipeline"
  NS="${PACKMATE_NAMESPACE:-packmate-lab}"
  if oc get project "${NS}" >/dev/null 2>&1; then
    oc apply --dry-run=server -n "${NS}" -f "${OUT}" >/dev/null 2>&1 \
      || log "WARNING: oc apply --dry-run=server unavailable or failed (client dry-run OK)"
  fi
else
  python3 - "${OUT}" <<'PY'
import sys
text=open(sys.argv[1], encoding='utf-8').read()
assert 'kind: Pipeline' in text
assert 'name: packmate-ci' in text
print('yaml_sanity_ok')
PY
fi

log "PASS  Pipeline rendered without unresolved placeholders"
log "Rendered Pipeline: ${OUT}"
printf '%s\n' "${OUT}"
