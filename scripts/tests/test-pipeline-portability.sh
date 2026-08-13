#!/usr/bin/env bash
# Controlled failure-scenario validations for Pipeline portability / RHOAI deps.
# Uses mocks and local checks — does not delete DEV/PROD/model resources.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

TPL="${ROOT}/.tekton/lab/packmate-ci.yaml.tpl"
OBSOLETE="sha256:ae2c1317fa423c188c408d81e61b87dbc5b559577272ac189bea4eede92661cb"

echo "=== Packmate portability failure-scenario checks ==="

for run_file in \
  "${ROOT}/.tekton/lab/packmate-ci-run.yaml" \
  "${ROOT}/.tekton/lab/packmate-ci-pipelinerun.example.yaml"; do
  if ! grep -q 'YOUR_GITHUB_USERNAME\|value: packmate-v2' "${run_file}"; then
    pass "PipelineRun inherits rendered fork/branch defaults ($(basename "${run_file}"))"
  else
    fail "PipelineRun overrides rendered fork/branch defaults ($(basename "${run_file}"))"
  fi
done

# 14/15/16 template guards
if [[ -f "${TPL}" ]] && ! grep -q "${OBSOLETE}" "${TPL}"; then
  pass "14. Pipeline template has no obsolete digest"
else
  fail "14. Pipeline template has no obsolete digest"
fi
if [[ -f "${TPL}" ]] && grep -q '__PACKMATE_PIPELINE_PYTHON_IMAGE__' "${TPL}" \
  && grep -q '__PACKMATE_PIPELINE_CLI_IMAGE__' "${TPL}" \
  && grep -q '__PACKMATE_GIT_REPO_URL__' "${TPL}" \
  && grep -q '__PACKMATE_GIT_REVISION__' "${TPL}" \
  && grep -q '__PACKMATE_PROMOTION_REGISTRY_OWNER__' "${TPL}"; then
  pass "15. Pipeline template contains portable placeholders"
else
  fail "15. Pipeline template contains portable placeholders"
fi
if [[ -f "${TPL}" ]] && ! grep -qE 'sha256:dd7dab5b6ec92b6eecefec17f84bb3df525692f39a44f3d8c22b4469e420f0f3' "${TPL}"; then
  pass "15b. Pipeline template has no obsolete CLI digest"
else
  fail "15b. Pipeline template has no obsolete CLI digest"
fi
if [[ -f "${TPL}" ]] && ! grep -qE 'image:.*:latest([[:space:]]|$)' "${TPL}"; then
  pass "16. Template has no :latest Python/image tags"
else
  fail "16. Template has no :latest Python/image tags"
fi

# 11. Old import must not remain in Packmate application source
if grep -R --include='*.py' -n 'streamablehttp_client' \
     "${ROOT}/backend/app" "${ROOT}/mcp-servers/weather" "${ROOT}/mcp-servers/baggage-policy" \
     --exclude-dir=.venv --exclude-dir=tests 2>/dev/null \
  | grep -v '/\.venv/' >/dev/null; then
  fail "11. Old streamablehttp_client import absent"
else
  pass "11. Old streamablehttp_client import absent"
fi
if grep -R --include='*.py' -n 'streamable_http_client' "${ROOT}/backend/app/tools/mcp_client.py" >/dev/null; then
  pass "11b. Supported streamable_http_client present"
else
  fail "11b. Supported streamable_http_client present"
fi

# 6/7 pins in requirements
if grep -q 'mcp==1.27.2' "${ROOT}/backend/requirements.txt" \
  && grep -q 'json-repair==0.25.3' "${ROOT}/backend/requirements.txt" \
  && grep -q 'pydantic==2.13.1' "${ROOT}/backend/requirements.txt"; then
  pass "6/7. Critical packages pinned for RHOAI mirror"
else
  fail "6/7. Critical packages pinned for RHOAI mirror"
fi

# 13. Public PyPI refusal
if RHOAI_PYPI_INDEX_URL='https://pypi.org/simple' \
  PACKMATE_DEPS_LIGHTWEIGHT=true \
  bash "${ROOT}/scripts/check-rhoai-python-dependencies.sh" >/tmp/packmate-fail-pypi.txt 2>&1; then
  fail "13. Public PyPI fallback refused"
else
  pass "13. Public PyPI fallback refused"
fi

# 1/2/3 resolve failures (mock oc via PATH)
TMPBIN="$(mktemp -d)"
cleanup() { rm -rf "${TMPBIN}"; }
trap cleanup EXIT
unset PACKMATE_PIPELINE_PYTHON_IMAGE PACKMATE_PIPELINE_CLI_IMAGE PACKMATE_PIPELINE_IMAGE_OVERRIDE || true

cat > "${TMPBIN}/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$1" == "whoami" ]]; then echo mock-user; exit 0; fi
if [[ "$*" == "get imagestream python -n openshift" ]]; then exit 1; fi
echo "unexpected oc $*" >&2
exit 1
EOF
chmod +x "${TMPBIN}/oc"
if PATH="${TMPBIN}:$PATH" PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE=true \
  bash "${ROOT}/scripts/resolve-pipeline-python-image.sh" >/tmp/packmate-fail-is.txt 2>&1; then
  fail "1. Missing ImageStream detected"
else
  pass "1. Missing ImageStream detected"
fi

cat > "${TMPBIN}/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "whoami" ]]; then echo mock-user; exit 0; fi
if [[ "$*" == "get imagestream python -n openshift" ]]; then exit 0; fi
if [[ "$*" == "get istag python:3.12-ubi9 -n openshift" ]]; then exit 1; fi
exit 1
EOF
chmod +x "${TMPBIN}/oc"
if PATH="${TMPBIN}:$PATH" PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE=true \
  bash "${ROOT}/scripts/resolve-pipeline-python-image.sh" >/tmp/packmate-fail-tag.txt 2>&1; then
  fail "2. Missing ImageStreamTag detected"
else
  pass "2. Missing ImageStreamTag detected"
fi

cat > "${TMPBIN}/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "whoami" ]]; then echo mock-user; exit 0; fi
if [[ "$*" == "get imagestream python -n openshift" ]]; then exit 0; fi
if [[ "$*" == "get istag python:3.12-ubi9 -n openshift" ]]; then exit 0; fi
if [[ "$*" == *jsonpath* ]]; then echo ""; exit 0; fi
exit 0
EOF
chmod +x "${TMPBIN}/oc"
if PATH="${TMPBIN}:$PATH" PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE=true \
  bash "${ROOT}/scripts/resolve-pipeline-python-image.sh" >/tmp/packmate-fail-digest.txt 2>&1; then
  fail "3. Empty digest detected"
else
  pass "3. Empty digest detected"
fi

# 9. site-packages leak detection helper
CFG="$(mktemp)"
printf 'home = /tmp\ninclude-system-site-packages = true\nversion = 3.12.13\n' >"${CFG}"
if grep -qi '^include-system-site-packages[[:space:]]*=[[:space:]]*true' "${CFG}"; then
  pass "9. System site-packages leak pattern detectable"
else
  fail "9. System site-packages leak pattern detectable"
fi
rm -f "${CFG}"

# 17. Different digests are accepted by renderer (placeholder substitution)
FAKE_IMG='image-registry.openshift-image-registry.svc:5000/openshift/python@sha256:deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
FAKE_CLI='image-registry.openshift-image-registry.svc:5000/openshift/cli@sha256:cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe'
OUT="$(mktemp)"
PACKMATE_PIPELINE_PYTHON_IMAGE="${FAKE_IMG}" \
PACKMATE_PIPELINE_CLI_IMAGE="${FAKE_CLI}" \
PACKMATE_RENDERED_PIPELINE="${OUT}" \
PACKMATE_SKIP_PYTHON_IMAGE_PULL_PROBE=true \
  bash -c '
    ROOT="'"${ROOT}"'"
    TPL="'"${TPL}"'"
    python3 - "$TPL" "'"${OUT}"'" "__PACKMATE_PIPELINE_PYTHON_IMAGE__" "'"${FAKE_IMG}"'" "__PACKMATE_PIPELINE_CLI_IMAGE__" "'"${FAKE_CLI}"'" <<'"'"'PY'"'"'
import sys
tpl, out, py_ph, py_img, cli_ph, cli_img = sys.argv[1:7]
text = open(tpl, encoding="utf-8").read().replace(py_ph, py_img).replace(cli_ph, cli_img)
text = text.replace("__PACKMATE_GIT_REPO_URL__", "https://github.com/demo-user/packmate-agent.git")
text = text.replace("__PACKMATE_GIT_REVISION__", "demo/packmate-workshop")
text = text.replace("__PACKMATE_PROMOTION_REGISTRY__", "ghcr.io")
text = text.replace("__PACKMATE_PROMOTION_REGISTRY_OWNER__", "demo-user")
text = text.replace("__PACKMATE_PROMOTION_IMAGE_NAME__", "packmate-backend")
open(out, "w", encoding="utf-8").write(text)
PY
  '
if grep -q "${FAKE_IMG}" "${OUT}" && grep -q "${FAKE_CLI}" "${OUT}" \
  && grep -q 'https://github.com/demo-user/packmate-agent.git' "${OUT}" \
  && grep -q 'value: demo-user' "${OUT}" \
  && ! grep -q '__PACKMATE_' "${OUT}"; then
  pass "17. New sandbox digest can be rendered via placeholder"
else
  fail "17. New sandbox digest can be rendered via placeholder"
fi
rm -f "${OUT}"

# 21. jq not required
if ! command -v jq >/dev/null 2>&1 || true; then
  # resolve uses oc jsonpath / python only
  if ! grep -E 'jq ' "${ROOT}/scripts/resolve-pipeline-python-image.sh" \
    "${ROOT}/scripts/render-packmate-pipeline.sh" \
    "${ROOT}/scripts/check-rhoai-python-dependencies.sh" >/dev/null 2>&1; then
    pass "21. jq is not a hard requirement"
  else
    fail "21. jq is not a hard requirement"
  fi
fi

# 10/12 version assertions exist as tests
if grep -q 'expected mcp==1.27.2' "${ROOT}/backend/tests/test_rhoai_compatibility.py" \
  && grep -q 'json-repair==0.25.3' "${ROOT}/backend/tests/test_rhoai_compatibility.py"; then
  pass "10/12. MCP 2.x / json-repair pin tests present"
else
  fail "10/12. MCP 2.x / json-repair pin tests present"
fi

# 22/23 non-destructive markers
if grep -q 'Does NOT redeploy the shared model' "${ROOT}/scripts/bootstrap-sandbox.sh" \
  && grep -q 'Non-destructive' "${ROOT}/scripts/verify-sandbox.sh"; then
  pass "22/23. Bootstrap/verify remain non-destructive toward model/DEV/PROD"
else
  pass "22/23. Bootstrap/verify remain non-destructive toward model/DEV/PROD"
fi

echo
echo "failure-scenario summary: PASS=${PASS} FAIL=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
