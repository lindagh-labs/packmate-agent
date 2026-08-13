#!/usr/bin/env bash
# Prepare a disposable demo PROD baseline in the participant fork ONLY.
#
# This command prepares the disposable participant-fork branch. Read-only checks
# remain available separately through `make verify-demo-baseline`.
#
# Modes (DEMO_BASELINE_MODE):
#   demo-branch (default, Mode B) — branch demo/packmate-workshop (or PACKMATE_DEMO_BRANCH)
#   fork-packmate-v2 (Mode A)     — update fork packmate-v2 explicitly
#
# Never modifies Lindagh1/packmate-agent. Never creates release tags. Never force-pushes
# packmate-v2. Prefer normal commits.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/fork-safety.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/report.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/prod-backend-overlay.sh"

packmate_load_fork_config "${ROOT}"

OVERLAY_REL="deploy/overlays/prod/kustomization.yaml"
OVERLAY="${ROOT}/${OVERLAY_REL}"
DEMO_BASELINE_MODE="${DEMO_BASELINE_MODE:-demo-branch}"
PACKMATE_DEMO_BRANCH="${PACKMATE_DEMO_BRANCH:-demo/packmate-workshop}"
PIPELINERUN=""
NAMESPACE="${PACKMATE_NAMESPACE:-packmate-lab}"
CANDIDATE_REF=""
PUSH="true"

usage() {
  cat <<'EOF'
Usage: prepare-demo-baseline.sh [--pipelinerun NAME] [--candidate REF] [--no-push]

Writes only to a validated participant fork. Use `make verify-demo-baseline` for
a read-only check.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipelinerun) PIPELINERUN="${2:?}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?}"; shift 2 ;;
    --candidate) CANDIDATE_REF="${2:?}"; shift 2 ;;
    --no-push) PUSH="false"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

printf '=== Packmate prepare-demo-baseline (WRITE — fork only) ===\n'

# --- Safety gates -----------------------------------------------------------
packmate_assert_origin_not_canonical || exit 1
packmate_assert_promotion_repo_allowed || exit 1

writable_norm="$(packmate_normalize_github_owner_repo "$(packmate_writable_repo_url)")"
origin_norm="$(packmate_normalize_github_owner_repo "$(packmate_remote_url origin)")"
[[ "${writable_norm}" == "${origin_norm}" ]] || {
  packmate_fail "origin matches fork" "origin=${origin_norm} GIT_REPO_URL=${writable_norm}" \
    "git remote set-url origin <fork-url>"
  exit 1
}
if packmate_is_canonical_owner_repo "${writable_norm}"; then
  printf 'BLOCKED_CANONICAL_REPOSITORY_PROMOTION\n' >&2
  packmate_blocked "Never run against Lindagh1/packmate-agent" \
    "origin=${writable_norm}" \
    "Use the participant fork only"
  exit 1
fi

upstream_url="$(packmate_remote_url upstream)"
if [[ -n "${upstream_url}" ]]; then
  if packmate_is_canonical_owner_repo "${upstream_url}"; then
    packmate_pass "upstream is canonical (fetch)"
    upstream_push="$(git config --get remote.upstream.pushurl 2>/dev/null || true)"
    if [[ -n "${upstream_push}" ]] && packmate_is_canonical_owner_repo "${upstream_push}"; then
      packmate_fail "upstream push disabled" "pushurl targets canonical" \
        "git remote set-url --push upstream DISABLED"
      exit 1
    fi
  fi
fi

# Dirty tree: only allow unrelated untracked noise if tracked tree is clean for overlay prep
if ! git diff --quiet || ! git diff --cached --quiet; then
  # Allow if the only tracked change is the prod overlay we are about to rewrite
  dirty="$(git status --porcelain --untracked-files=no)"
  if [[ -n "${dirty}" ]]; then
    only_overlay="$(printf '%s\n' "${dirty}" | awk 'NF{print $2}' | grep -v "^${OVERLAY_REL}$" || true)"
    if [[ -n "${only_overlay}" ]]; then
      packmate_fail "Working tree has no unrelated tracked changes" \
        "$(printf '%s' "${dirty}" | tr '\n' ' ')" \
        "Commit/stash unrelated changes before prepare-demo-baseline"
      exit 1
    fi
  fi
fi

baseline_rc=0
baseline_ref="$(packmate_resolve_demo_baseline_ref)" || baseline_rc=$?
if [[ "${baseline_rc}" -eq 2 ]]; then
  printf 'BLOCKED_INTERNAL_REGISTRY_BASELINE\n' >&2
  exit 1
fi
if [[ "${baseline_rc}" -ne 0 || -z "${baseline_ref}" ]]; then
  printf 'BLOCKED_MISSING_BASELINE_DIGEST\n' >&2
  packmate_blocked "Baseline digest configured" "" "Set PACKMATE_DEMO_BASELINE_DIGEST"
  exit 1
fi
[[ "${baseline_ref}" == *@sha256:* ]] || {
  printf 'BLOCKED_MUTABLE_TAG_BASELINE\n' >&2
  exit 1
}
baseline_image="${baseline_ref%@*}"
baseline_digest="$(packmate_normalize_digest "${baseline_ref##*@}")"

pull_rc=0
packmate_verify_image_ref_pullable "${baseline_ref}" || pull_rc=$?
if [[ "${pull_rc}" -eq 1 ]]; then
  printf 'BLOCKED_UNAVAILABLE_BASELINE_IMAGE\n' >&2
  packmate_blocked "Baseline image available" "${baseline_ref}" \
    "Pick a durable GHCR digest that still exists"
  exit 1
fi
[[ "${pull_rc}" -eq 0 ]] && packmate_pass "Baseline image pullable"

# Optional candidate must differ from baseline
candidate_ref="${CANDIDATE_REF}"
if [[ -z "${candidate_ref}" && -n "${PIPELINERUN}" ]]; then
  candidate_ref="$(oc get taskrun "${PIPELINERUN}-publish-candidate" -n "${NAMESPACE}" \
    -o jsonpath='{.status.results[?(@.name=="PROMOTION_IMAGE_REFERENCE")].value}' 2>/dev/null || true)"
fi
if [[ -n "${candidate_ref}" ]]; then
  candidate_digest="$(packmate_normalize_digest "${candidate_ref##*@}")"
  if [[ "${candidate_digest}" == "${baseline_digest}" ]]; then
    packmate_blocked "Baseline differs from candidate" \
      "baseline equals candidate ${baseline_digest}" \
      "Choose an older known-good baseline digest from lab history"
    exit 1
  fi
  packmate_pass "Baseline differs from candidate"
fi

# --- Target branch ----------------------------------------------------------
ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "${DEMO_BASELINE_MODE}" in
  demo-branch)
    target_branch="${PACKMATE_DEMO_BRANCH}"
    if [[ "${target_branch}" != demo/* ]]; then
      packmate_fail "Mode B branch begins with demo/" \
        "PACKMATE_DEMO_BRANCH=${target_branch}" \
        "Use e.g. demo/packmate-workshop"
      exit 1
    fi
    packmate_pass "Mode B disposable demo branch (${target_branch})"
    ;;
  fork-packmate-v2)
    target_branch="packmate-v2"
    packmate_pass "Mode A fork packmate-v2 (explicitly configured)"
    ;;
  *)
    packmate_fail "Unknown DEMO_BASELINE_MODE=${DEMO_BASELINE_MODE}" \
      "Use demo-branch or fork-packmate-v2"
    exit 1
    ;;
esac

# Backup tag inside the fork only (local + optional push of backup ref)
backup_ref="backup/demo-baseline-$(date -u +%Y%m%d%H%M%S)"
git tag "${backup_ref}" >/dev/null 2>&1 || true
printf 'INFO    local backup tag %s (fork-only; not a release)\n' "${backup_ref}"

if git show-ref --verify --quiet "refs/heads/${target_branch}"; then
  git checkout "${target_branch}"
elif git show-ref --verify --quiet "refs/remotes/origin/${target_branch}"; then
  git checkout -b "${target_branch}" "origin/${target_branch}"
else
  # Create from current HEAD (expected: workshop commit)
  git checkout -b "${target_branch}"
fi

current_ref="$(packmate_read_prod_backend_ref "${OVERLAY}")" || {
  packmate_fail "Readable PROD overlay" "${OVERLAY_REL}"
  git checkout "${ORIGINAL_BRANCH}" >/dev/null 2>&1 || true
  exit 1
}
current_digest="$(packmate_normalize_digest "${current_ref##*@}")"
printf 'INFO    current PROD on %s: %s\n' "${target_branch}" "${current_ref}"
printf 'INFO    target baseline: %s\n' "${baseline_ref}"

changed="false"
if [[ "${current_digest}" != "${baseline_digest}" || "${current_ref%@*}" != "${baseline_image}" ]]; then
  packmate_set_prod_backend_ref "${OVERLAY}" "${baseline_image}" "${baseline_digest}"
  # Exactly one file may change
  mapfile -t changed_files < <(git diff --name-only -- "${OVERLAY_REL}"; git diff --cached --name-only -- "${OVERLAY_REL}")
  # shellcheck disable=SC2207
  uniq_files=($(printf '%s\n' "${changed_files[@]}" | awk 'NF' | sort -u))
  if [[ "${#uniq_files[@]}" -ne 1 || "${uniq_files[0]}" != "${OVERLAY_REL}" ]]; then
    packmate_fail "Only ${OVERLAY_REL} will change" "unexpected: ${uniq_files[*]-none}"
    git checkout -- "${OVERLAY_REL}" >/dev/null 2>&1 || true
    git checkout "${ORIGINAL_BRANCH}" >/dev/null 2>&1 || true
    exit 1
  fi
  git add -- "${OVERLAY_REL}"
  git commit -m "Prepare Packmate demo PROD baseline"
  changed="true"
  packmate_pass "Baseline commit created (exactly one file)"
else
  printf 'INFO    Already at configured baseline — no overlay commit needed\n'
fi

# Ensure no release tags were created by this script (backup/ is not lab-v*)
if git tag --list 'lab-v*' | grep -q .; then
  printf 'INFO    Existing lab-v* tags untouched\n'
fi

if [[ "${PUSH}" == "true" ]]; then
  if git push -u origin "${target_branch}:${target_branch}"; then
    packmate_pass "Pushed ${target_branch} to fork ${writable_norm}"
  else
    packmate_fail "Push demo baseline branch to fork" \
      "git push failed (often HTTPS 403 / VS Code askpass ECONNREFUSED)" \
      "Unset GIT_ASKPASS; authenticate (gh auth login or HTTPS token at prompt); then: git push -u origin ${target_branch}"
    printf 'ACTION  Authenticate safely, then run: git push -u origin %s\n' "${target_branch}"
    printf 'ACTION  Re-run make prepare-demo-baseline so local configuration is verified and saved\n'
    exit 1
  fi
else
  printf 'INFO    --no-push: branch %s ready locally only\n' "${target_branch}"
fi

# Persist the coordinated local state only after the branch is prepared. The file
# is gitignored and contains no GitHub/registry credentials.
CONFIG="${PACKMATE_CONFIG:-${ROOT}/config/sandbox.env}"
if [[ ! -f "${CONFIG}" && -f "${ROOT}/config/sandbox.env.example" ]]; then
  install -m 600 "${ROOT}/config/sandbox.env.example" "${CONFIG}"
fi
python3 "${ROOT}/scripts/update-sandbox-config.py" \
  --file "${CONFIG}" \
  --set "GIT_REPO_URL=https://github.com/${writable_norm}.git" \
  --set "GIT_REVISION=${target_branch}" \
  --set "PROMOTION_BASE_BRANCH=${target_branch}" \
  --set "PACKMATE_DEMO_BRANCH=${target_branch}"

saved_revision="$(sed -n 's/^GIT_REVISION=//p' "${CONFIG}" | tail -1)"
saved_base="$(sed -n 's/^PROMOTION_BASE_BRANCH=//p' "${CONFIG}" | tail -1)"
saved_demo="$(sed -n 's/^PACKMATE_DEMO_BRANCH=//p' "${CONFIG}" | tail -1)"
[[ "$(git branch --show-current)" == "${target_branch}" \
  && "${saved_revision}" == "${target_branch}" \
  && "${saved_base}" == "${target_branch}" \
  && "${saved_demo}" == "${target_branch}" ]] || {
  packmate_fail "Branch configuration persisted" \
    "current=$(git branch --show-current) revision=${saved_revision} base=${saved_base} demo=${saved_demo}" \
    "Re-run make configure-participant, then make prepare-demo-baseline"
  exit 1
}
packmate_pass "Current branch and local GitOps/promotion settings agree"

printf '\n'
printf 'RESULT  DEMO_BASELINE_READY branch=%s changed=%s baseline=%s\n' \
  "${target_branch}" "${changed}" "${baseline_digest}"
printf 'RESULT  CONFIG_SAVED GIT_REVISION=%s PROMOTION_BASE_BRANCH=%s PACKMATE_DEMO_BRANCH=%s\n' \
  "${saved_revision}" "${saved_base}" "${saved_demo}"
printf 'NEXT    make verify-demo-fork\n'
printf 'ACTION  Then: make verify-demo-baseline PIPELINERUN=<name>\n'
exit 0
