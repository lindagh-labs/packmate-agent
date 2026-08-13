#!/usr/bin/env bash
# Safe Workbench repository onboarding for Packmate.
# Never treats /opt/app-root/src itself as the Git repository.
# Never deletes or overwrites files already present in /opt/app-root/src.
set -euo pipefail

# Prefer participant fork URL from env / sandbox config. Canonical upstream is for
# reference only — do not clone Lindagh1/packmate-agent as origin for workshops.
PACKMATE_REPOSITORY_URL="${PACKMATE_REPOSITORY_URL:-${GIT_REPO_URL:-}}"
PACKMATE_REPOSITORY_BRANCH="${PACKMATE_REPOSITORY_BRANCH:-${GIT_REVISION:-packmate-v2}}"
PACKMATE_REPOSITORY_DIRECTORY="${PACKMATE_REPOSITORY_DIRECTORY:-/opt/app-root/src/packmate-agent}"
PACKMATE_CANONICAL_REPOSITORY_URL="${PACKMATE_CANONICAL_REPOSITORY_URL:-${CANONICAL_GIT_REPO_URL:-https://github.com/Lindagh1/packmate-agent.git}}"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -n "${PACKMATE_REPOSITORY_URL}" ]] || die "Set PACKMATE_REPOSITORY_URL or GIT_REPO_URL to your GitHub fork (not Lindagh1/packmate-agent)"

normalize_git_url() {
  local u="$1"
  u="${u%.git}"
  u="${u%/}"
  u="${u#https://}"
  u="${u#http://}"
  u="${u#git@}"
  u="${u/://}"
  printf '%s' "${u,,}"
}

urls_match() {
  local a b
  a="$(normalize_git_url "$1")"
  b="$(normalize_git_url "$2")"
  [[ "${a}" == "${b}" ]]
}

command -v git >/dev/null 2>&1 || die "git is not available in PATH"
USER_NAME="$(id -un 2>/dev/null || printf 'unknown')"
HOME_DIR="${HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)}"
log "user=${USER_NAME} home=${HOME_DIR:-unknown}"
log "target=${PACKMATE_REPOSITORY_DIRECTORY}"
log "url=${PACKMATE_REPOSITORY_URL}"
log "branch=${PACKMATE_REPOSITORY_BRANCH}"

PARENT="$(dirname "${PACKMATE_REPOSITORY_DIRECTORY}")"
# Never assume the parent (e.g. /opt/app-root/src) is a Git repo.
if [[ -d "${PARENT}/.git" ]]; then
  log "NOTE: ${PARENT} contains .git — Packmate still uses ${PACKMATE_REPOSITORY_DIRECTORY}"
fi

if [[ ! -e "${PACKMATE_REPOSITORY_DIRECTORY}" ]]; then
  mkdir -p "${PARENT}"
  log "==> Cloning ${PACKMATE_REPOSITORY_BRANCH} into ${PACKMATE_REPOSITORY_DIRECTORY}"
  git clone --branch "${PACKMATE_REPOSITORY_BRANCH}" --single-branch \
    "${PACKMATE_REPOSITORY_URL}" "${PACKMATE_REPOSITORY_DIRECTORY}"
elif [[ -d "${PACKMATE_REPOSITORY_DIRECTORY}/.git" ]]; then
  cd "${PACKMATE_REPOSITORY_DIRECTORY}"
  ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "${ORIGIN}" ]] || die "Git repository at ${PACKMATE_REPOSITORY_DIRECTORY} has no origin remote"
  if ! urls_match "${ORIGIN}" "${PACKMATE_REPOSITORY_URL}"; then
    die "origin URL mismatch: found '${ORIGIN}', expected '${PACKMATE_REPOSITORY_URL}'"
  fi

  # Tracked modifications block automatic update.
  if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null || true)" ]]; then
    log "ERROR: tracked local modifications present — refusing to update automatically"
    git status --short
    die "Commit, stash, or discard tracked changes, then re-run this script"
  fi

  log "==> Fetching origin and updating ${PACKMATE_REPOSITORY_BRANCH}"
  git fetch origin
  git switch "${PACKMATE_REPOSITORY_BRANCH}"
  git pull --ff-only origin "${PACKMATE_REPOSITORY_BRANCH}"
elif [[ -e "${PACKMATE_REPOSITORY_DIRECTORY}" ]]; then
  die "Path ${PACKMATE_REPOSITORY_DIRECTORY} exists but is not a Git repository. Refusing to delete or overwrite it. Move/rename it, then re-run."
fi

cd "${PACKMATE_REPOSITORY_DIRECTORY}"
CURRENT_BRANCH="$(git branch --show-current)"
ORIGIN="$(git remote get-url origin)"
COMMIT="$(git log -1 --oneline)"
TRACKED_DIRTY="$(git status --porcelain --untracked-files=no || true)"

[[ "${CURRENT_BRANCH}" == "${PACKMATE_REPOSITORY_BRANCH}" ]] \
  || die "Expected branch ${PACKMATE_REPOSITORY_BRANCH}, got ${CURRENT_BRANCH}"
[[ -z "${TRACKED_DIRTY}" ]] || die "Tracked working tree is not clean after update"

cat <<EOF

=== Packmate Workbench repository ready ===
path:    ${PACKMATE_REPOSITORY_DIRECTORY}
branch:  ${CURRENT_BRANCH}
origin:  ${ORIGIN}
commit:  ${COMMIT}
tracked: clean
ignored: preserved (e.g. config/sandbox.env)

Next:
  cd ${PACKMATE_REPOSITORY_DIRECTORY}
  make configure-participant
  make verify-demo-fork
  make preflight
  make bootstrap
  make verify-dev
EOF
