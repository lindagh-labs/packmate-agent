#!/usr/bin/env bash
# Configure the local Packmate checkout from its participant-owned GitHub fork.
# No credential or token is requested, read, printed, or stored by this command.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/fork-safety.sh"

CONFIG="${PACKMATE_CONFIG:-${ROOT}/config/sandbox.env}"
EXAMPLE="${ROOT}/config/sandbox.env.example"
CANONICAL_URL="${CANONICAL_GIT_REPO_URL:-${PACKMATE_CANONICAL_GIT_REPO_URL_DEFAULT}}"

pass() { printf 'PASS  %s\n' "$*"; }
die() {
  printf 'FAIL  %s\n' "$1" >&2
  [[ -n "${2:-}" ]] && printf 'ACTION  %s\n' "$2" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "git is not available"
command -v python3 >/dev/null 2>&1 || die "python3 is not available"
[[ -d "${ROOT}/.git" ]] || die "Run this command inside the cloned packmate-agent repository"

origin_url="$(git remote get-url origin 2>/dev/null || true)"
[[ -n "${origin_url}" ]] \
  || die "origin is not configured" "git remote add origin https://github.com/YOUR_USERNAME/packmate-agent.git"
origin_repo="$(packmate_normalize_github_owner_repo "${origin_url}" 2>/dev/null || true)"
[[ -n "${origin_repo}" ]] \
  || die "origin is not a supported GitHub repository URL (${origin_url})" \
    "git remote set-url origin https://github.com/YOUR_USERNAME/packmate-agent.git"
if packmate_is_canonical_owner_repo "${origin_repo}"; then
  printf 'BLOCKED_CANONICAL_REPOSITORY_PROMOTION\n' >&2
  die "origin points to the read-only canonical repository" \
    "Fork Lindagh1/packmate-agent, then set origin to your fork before continuing"
fi
pass "origin is a participant fork (${origin_repo})"

branch="$(git branch --show-current 2>/dev/null || true)"
[[ -n "${branch}" ]] || die "Git is in detached HEAD state" "git switch packmate-v2"
git check-ref-format --branch "${branch}" >/dev/null 2>&1 \
  || die "current branch name is invalid (${branch})"
pass "current workshop branch is ${branch}"

upstream_url="$(git remote get-url upstream 2>/dev/null || true)"
if [[ -z "${upstream_url}" ]]; then
  git remote add upstream "${CANONICAL_URL}"
  pass "added canonical upstream as a fetch remote"
elif packmate_is_canonical_owner_repo "${upstream_url}"; then
  pass "upstream points to the canonical repository"
else
  die "upstream points somewhere unexpected (${upstream_url})" \
    "Rename that remote, then re-run make configure-participant"
fi
git remote set-url --push upstream DISABLED
pass "pushes to canonical upstream are disabled"

if [[ ! -f "${CONFIG}" ]]; then
  [[ -f "${EXAMPLE}" ]] || die "missing ${EXAMPLE}"
  install -m 600 "${EXAMPLE}" "${CONFIG}"
  pass "created gitignored config/sandbox.env"
else
  chmod 600 "${CONFIG}" 2>/dev/null || true
  pass "preserving existing config/sandbox.env values"
fi

fork_url="$(packmate_github_https_url "${origin_repo}")"
github_owner="${origin_repo%%/*}"
settings=(
  --set "GIT_REPO_URL=${fork_url}"
  --set "GIT_REVISION=${branch}"
  --set "PROMOTION_BASE_BRANCH=${branch}"
  --set "PACKMATE_PROMOTION_REGISTRY_OWNER=${github_owner}"
)
if [[ "${branch}" == demo/* ]]; then
  settings+=(--set "PACKMATE_DEMO_BRANCH=${branch}")
fi
python3 "${ROOT}/scripts/update-sandbox-config.py" --file "${CONFIG}" "${settings[@]}"

# Re-load only the values we just wrote, then assert the coordinated state.
# shellcheck disable=SC1090
source "${CONFIG}"
[[ "$(packmate_normalize_github_owner_repo "${GIT_REPO_URL}")" == "${origin_repo}" ]] \
  || die "saved GIT_REPO_URL does not match origin"
[[ "${GIT_REVISION}" == "${branch}" && "${PROMOTION_BASE_BRANCH}" == "${branch}" ]] \
  || die "saved branch settings do not match the current branch"

cat <<EOF

=== Participant workspace configured ===
fork:        ${fork_url}
branch:      ${branch}
GHCR owner:  ${github_owner}
config:      config/sandbox.env (mode 600, gitignored)

No GitHub token was requested or stored.
Next: make verify-demo-fork
EOF
