#!/usr/bin/env bash
# Deterministic tests for participant configuration and coordinated branch state.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

temporary="$(mktemp -d)"
cleanup() { rm -rf "${temporary}"; }
trap cleanup EXIT

fixture="${temporary}/participant-fork"
git init -q -b packmate-v2 "${fixture}"
git -C "${fixture}" config user.name test
git -C "${fixture}" config user.email test@example.com
git -C "${fixture}" remote add origin https://github.com/demo-student/packmate-agent.git
mkdir -p "${fixture}/scripts/lib" "${fixture}/config"
cp "${ROOT}/scripts/configure-participant.sh" "${fixture}/scripts/"
cp "${ROOT}/scripts/update-sandbox-config.py" "${fixture}/scripts/"
cp "${ROOT}/scripts/lib/fork-safety.sh" "${fixture}/scripts/lib/"
cp "${ROOT}/config/sandbox.env.example" "${fixture}/config/"
git -C "${fixture}" add .
git -C "${fixture}" commit -qm fixture

if (cd "${fixture}" && bash scripts/configure-participant.sh) >/tmp/packmate-configure-participant.txt 2>&1; then
  pass "participant fork configures without manual file editing"
else
  fail "participant fork configures without manual file editing"
  sed -n '1,80p' /tmp/packmate-configure-participant.txt || true
fi

config="${fixture}/config/sandbox.env"
grep -q '^GIT_REPO_URL=https://github.com/demo-student/packmate-agent.git$' "${config}" \
  && grep -q '^GIT_REVISION=packmate-v2$' "${config}" \
  && grep -q '^PROMOTION_BASE_BRANCH=packmate-v2$' "${config}" \
  && grep -q '^PACKMATE_PROMOTION_REGISTRY_OWNER=demo-student$' "${config}" \
  && pass "fork, branch, and GHCR owner are coordinated" \
  || fail "fork, branch, and GHCR owner are coordinated"

[[ "$(git -C "${fixture}" config --get remote.upstream.pushurl)" == "DISABLED" ]] \
  && pass "canonical upstream push is disabled" \
  || fail "canonical upstream push is disabled"

mode="$(stat -c '%a' "${config}")"
[[ "${mode}" == "600" ]] && pass "participant config has private file mode" || fail "participant config mode is ${mode}"

if ! grep -Eqi '(GITHUB_TOKEN|GH_TOKEN|REGISTRY_TOKEN|password)=' "${config}"; then
  pass "participant configuration stores no GitHub credential"
else
  fail "participant configuration stores no GitHub credential"
fi

before="$(sha256sum "${config}" | awk '{print $1}')"
(cd "${fixture}" && bash scripts/configure-participant.sh) >/tmp/packmate-configure-participant-rerun.txt 2>&1 || true
after="$(sha256sum "${config}" | awk '{print $1}')"
[[ "${before}" == "${after}" ]] && pass "configuration is idempotent" || fail "configuration is idempotent"

canonical="${temporary}/canonical"
git init -q -b packmate-v2 "${canonical}"
git -C "${canonical}" remote add origin https://github.com/Lindagh1/packmate-agent.git
mkdir -p "${canonical}/scripts/lib" "${canonical}/config"
cp "${ROOT}/scripts/configure-participant.sh" "${canonical}/scripts/"
cp "${ROOT}/scripts/update-sandbox-config.py" "${canonical}/scripts/"
cp "${ROOT}/scripts/lib/fork-safety.sh" "${canonical}/scripts/lib/"
cp "${ROOT}/config/sandbox.env.example" "${canonical}/config/"
if ! (cd "${canonical}" && bash scripts/configure-participant.sh) >/tmp/packmate-configure-canonical.txt 2>&1 \
  && grep -q BLOCKED_CANONICAL /tmp/packmate-configure-canonical.txt; then
  pass "canonical origin is blocked before config creation"
else
  fail "canonical origin is blocked before config creation"
fi

unsafe_marker="${temporary}/unsafe-branch-executed"
unsafe_assignment='GIT_REVISION=demo/$(touch '${unsafe_marker}')'
if ! python3 "${ROOT}/scripts/update-sandbox-config.py" \
    --file "${temporary}/unsafe.env" --set "${unsafe_assignment}" >/dev/null 2>&1 \
  && [[ ! -e "${unsafe_marker}" ]]; then
  pass "unsafe shell syntax is rejected from managed settings"
else
  fail "unsafe shell syntax is rejected from managed settings"
fi

printf '\nparticipant-configuration summary: PASS=%s FAIL=%s\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
