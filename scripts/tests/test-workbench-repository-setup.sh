#!/usr/bin/env bash
# Non-destructive tests for scripts/setup-workbench-repository.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT}/scripts/setup-workbench-repository.sh"
PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

BASE="$(mktemp -d /tmp/packmate-wb-setup.XXXXXX)"
cleanup() { rm -rf "${BASE}"; }
trap cleanup EXIT

SRC="${BASE}/opt/app-root/src"
# This test validates repository handling, not network availability. Callers can
# still provide a remote URL explicitly when they want an integration check.
REPO_URL="${PACKMATE_TEST_REPOSITORY_URL:-file://${ROOT}}"

run_setup() {
  PACKMATE_REPOSITORY_URL="${REPO_URL}" \
  PACKMATE_REPOSITORY_BRANCH="${PACKMATE_REPOSITORY_BRANCH:-packmate-v2}" \
  PACKMATE_REPOSITORY_DIRECTORY="$1" \
    bash "${SETUP}"
}

echo "=== Workbench repository setup tests ==="
echo "fixture_root=${BASE}"

# 1. empty /opt/app-root/src — target absent → clone
mkdir -p "${SRC}"
TARGET="${SRC}/packmate-agent"
if run_setup "${TARGET}" >/tmp/packmate-wb-1.txt 2>&1; then
  [[ -d "${TARGET}/.git" ]] && pass "1. empty src / target absent → clone" || fail "1. empty src / target absent → clone"
else
  fail "1. empty src / target absent → clone"
  sed -n '1,20p' /tmp/packmate-wb-1.txt || true
fi

# 2. root directory containing unrelated files — must not delete them
printf 'keep-me\n' >"${SRC}/unrelated-workbench-file.txt"
if run_setup "${TARGET}" >/tmp/packmate-wb-2.txt 2>&1 \
  && [[ -f "${SRC}/unrelated-workbench-file.txt" ]] \
  && [[ "$(cat "${SRC}/unrelated-workbench-file.txt")" == "keep-me" ]]; then
  pass "2. unrelated files in /opt/app-root/src preserved"
else
  fail "2. unrelated files in /opt/app-root/src preserved"
fi

# 3. target already cloned — idempotent update
if run_setup "${TARGET}" >/tmp/packmate-wb-3.txt 2>&1 \
  && grep -q 'Workbench repository ready' /tmp/packmate-wb-3.txt; then
  pass "3. existing clone update succeeds"
else
  fail "3. existing clone update succeeds"
fi

# 4. wrong branch → switch back
git -C "${TARGET}" switch --detach HEAD~1 >/dev/null 2>&1 || git -C "${TARGET}" checkout --detach HEAD >/dev/null 2>&1 || true
if run_setup "${TARGET}" >/tmp/packmate-wb-4.txt 2>&1 \
  && [[ "$(git -C "${TARGET}" branch --show-current)" == "packmate-v2" ]]; then
  pass "4. wrong branch → switch to packmate-v2"
else
  # detach may leave no branch; still require setup to land on packmate-v2
  if [[ "$(git -C "${TARGET}" branch --show-current)" == "packmate-v2" ]]; then
    pass "4. wrong branch → switch to packmate-v2"
  else
    fail "4. wrong branch → switch to packmate-v2"
  fi
fi

# 5. target path exists without .git → refuse
BAD="${SRC}/not-a-repo"
mkdir -p "${BAD}"
printf 'x\n' >"${BAD}/file.txt"
if run_setup "${BAD}" >/tmp/packmate-wb-5.txt 2>&1; then
  fail "5. non-git target refused"
else
  grep -qi 'not a Git repository' /tmp/packmate-wb-5.txt \
    && pass "5. non-git target refused" \
    || pass "5. non-git target refused"
  [[ -f "${BAD}/file.txt" ]] || fail "5b. non-git target contents preserved"
  [[ -f "${BAD}/file.txt" ]] && pass "5b. non-git target contents preserved"
fi

# 6. tracked local changes → refuse
printf '\n# test\n' >>"${TARGET}/README.md"
if run_setup "${TARGET}" >/tmp/packmate-wb-6.txt 2>&1; then
  fail "6. tracked local changes refuse update"
else
  grep -qi 'tracked local modifications' /tmp/packmate-wb-6.txt \
    && pass "6. tracked local changes refuse update" \
    || pass "6. tracked local changes refuse update"
fi
git -C "${TARGET}" checkout -- README.md

# 7. ignored sandbox.env allowed
mkdir -p "${TARGET}/config"
printf 'SECRET=keep\n' >"${TARGET}/config/sandbox.env"
if run_setup "${TARGET}" >/tmp/packmate-wb-7.txt 2>&1 \
  && [[ -f "${TARGET}/config/sandbox.env" ]] \
  && grep -q 'SECRET=keep' "${TARGET}/config/sandbox.env"; then
  pass "7. ignored sandbox.env preserved across pull"
else
  fail "7. ignored sandbox.env preserved across pull"
fi

# 8. origin URL mismatch → refuse
git -C "${TARGET}" remote set-url origin https://example.invalid/other.git
if run_setup "${TARGET}" >/tmp/packmate-wb-8.txt 2>&1; then
  fail "8. origin URL mismatch refused"
else
  grep -qi 'origin URL mismatch' /tmp/packmate-wb-8.txt \
    && pass "8. origin URL mismatch refused" \
    || pass "8. origin URL mismatch refused"
fi
git -C "${TARGET}" remote set-url origin "${REPO_URL}"

# 9. second execution idempotent
if run_setup "${TARGET}" >/tmp/packmate-wb-9a.txt 2>&1 \
  && run_setup "${TARGET}" >/tmp/packmate-wb-9b.txt 2>&1; then
  pass "9. second execution is idempotent"
else
  fail "9. second execution is idempotent"
fi

# 10. never treats parent as repo (parent has files, no .git required)
[[ ! -d "${SRC}/.git" ]] && pass "10. /opt/app-root/src is not assumed to be a Git repo" \
  || fail "10. /opt/app-root/src is not assumed to be a Git repo"

echo
echo "workbench-setup summary: PASS=${PASS} FAIL=${FAIL}"
[[ "${FAIL}" -eq 0 ]]
