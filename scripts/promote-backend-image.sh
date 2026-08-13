#!/usr/bin/env bash
# Promote a validated Packmate backend image digest from packmate-lab into the
# PRODUCTION overlay ONLY (deploy/overlays/prod/kustomization.yaml).
#
# Never modifies: deploy/overlays/dev, frontend image, MCP images, application code.
# Never pushes to packmate-v2 directly — always via a promote/backend-<digest> branch.
#
# Modes:
#   scripts/promote-backend-image.sh --pipelinerun <name> --namespace packmate-lab
#   scripts/promote-backend-image.sh --pipelinerun <name> --namespace packmate-lab --create-pr
#   scripts/promote-backend-image.sh --pipelinerun <name> --namespace packmate-lab --create-pr --merge-pr
#   scripts/promote-backend-image.sh sha256:<digest>                # legacy positional (updates PROD, asks to confirm)
#
# Flags:
#   --pipelinerun NAME    Tekton PipelineRun to read results from (packmate-ci)
#   --namespace NS        Namespace of the PipelineRun / ImageStream (default: packmate-lab)
#   --threshold VALUE     Minimum AI quality score (default: 0.90)
#   --create-pr           Open a PR to PROMOTION_BASE_BRANCH in the fork via `gh` after commit+push
#   --merge-pr            Merge the PR immediately — automated Cursor validation ONLY, default off
#   -h|--help             Show usage
#
# Env overrides:
#   IMAGE_NAME             Registry path of the backend image (default derived from --namespace)
#   GIT_REPO_URL           Writable fork URL (required; must not be canonical upstream)
#   PROMOTION_BASE_BRANCH  PR base inside the fork (default: packmate-v2)
#   ALLOW_CANONICAL_REPO_PROMOTION  Instructor-only override (default: false)
#
# Never creates git tags or GitHub Releases. Never opens a PR into Lindagh1/packmate-agent
# unless ALLOW_CANONICAL_REPO_PROMOTION=true.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/fork-safety.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/prod-backend-overlay.sh"
packmate_load_fork_config "${ROOT}"

OVERLAY_REL="deploy/overlays/prod/kustomization.yaml"
OVERLAY="${ROOT}/${OVERLAY_REL}"
TARGET_IMAGE_KEY="quay.io/example/packmate-backend"
BASE_BRANCH="${PROMOTION_BASE_BRANCH:-packmate-v2}"
ALLOW_MANUAL_PROMOTION_COMPLETION="${ALLOW_MANUAL_PROMOTION_COMPLETION:-false}"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Argument parsing (supports legacy positional digest + flag-based mode)
# ---------------------------------------------------------------------------
PIPELINERUN=""
NAMESPACE="${PACKMATE_NAMESPACE:-packmate-lab}"
THRESHOLD="0.90"
CREATE_PR="false"
MERGE_PR="false"
LEGACY_DIGEST=""

if [[ $# -gt 0 && "${1}" != -* ]]; then
  LEGACY_DIGEST="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipelinerun)
      PIPELINERUN="${2:?--pipelinerun requires a value}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:?--namespace requires a value}"
      shift 2
      ;;
    --threshold)
      THRESHOLD="${2:?--threshold requires a value}"
      shift 2
      ;;
    --create-pr)
      CREATE_PR="true"
      shift
      ;;
    --merge-pr)
      MERGE_PR="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1 (see --help)"
      ;;
  esac
done

if [[ -z "${LEGACY_DIGEST}" && -z "${PIPELINERUN}" ]]; then
  usage
  die "Provide --pipelinerun <name> or a legacy sha256 digest as \$1"
fi

IMAGE_NAME="${IMAGE_NAME:-${PACKMATE_PROMOTION_REGISTRY:-ghcr.io}/${PACKMATE_PROMOTION_REGISTRY_OWNER:-Lindagh1}/${PACKMATE_PROMOTION_IMAGE_NAME:-packmate-backend}}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

require_oc() {
  command -v oc >/dev/null 2>&1 || die "oc CLI not found (required for --pipelinerun mode)"
  oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift (oc whoami failed)"
  if [[ "$(oc whoami)" == system:serviceaccount:* ]]; then
    die "BLOCKED_OPENSHIFT_SERVICE_ACCOUNT_IDENTITY — run oc logout, then oc login --web"
  fi
}

normalize_digest() {
  # Strip any accidental duplicate "sha256:" prefix and lower-case the hex.
  local d="$1"
  d="${d#sha256:}"
  d="$(printf '%s' "${d}" | tr 'A-F' 'a-f')"
  printf 'sha256:%s' "${d}"
}

short_digest() {
  local d="${1#sha256:}"
  printf '%s' "${d:0:12}"
}

# Best-effort ImageStream verification. Never fails the run — offline/RBAC
# gaps only produce a warning.
verify_image_exists() {
  local ns="$1" digest="$2"
  if ! command -v oc >/dev/null 2>&1; then
    warn "oc CLI not found; skipping ImageStream verification (offline)"
    return 0
  fi
  if ! oc get imagestream packmate-backend -n "${ns}" >/dev/null 2>&1; then
    warn "could not read imagestream/packmate-backend in ${ns} (offline, RBAC, or not yet built) — continuing"
    return 0
  fi
  if oc get imagestream packmate-backend -n "${ns}" -o json 2>/dev/null | grep -q "${digest#sha256:}"; then
    log "OK: digest ${digest} present in imagestream/packmate-backend (${ns})"
  else
    warn "digest ${digest} not found in imagestream/packmate-backend status (${ns}) — continuing"
  fi
}

# Extract PipelineRun status + TaskRun results (ai-quality-gate, build-backend)
# via a single python3/oc round-trip. Emits shell-safe KEY=VALUE lines on
# stdout for `eval`; diagnostics go to stderr.
extract_pipeline_data() {
  local ns="$1" name="$2"
  python3 - "${ns}" "${name}" <<'PY'
import json
import shlex
import subprocess
import sys

ns, name = sys.argv[1], sys.argv[2]


def oc_json(*args):
    r = subprocess.run(["oc", *args, "-o", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        return None, r.stderr.strip()
    try:
        return json.loads(r.stdout), None
    except json.JSONDecodeError as exc:
        return None, str(exc)


def emit(key, value):
    print(f"{key}={shlex.quote('' if value is None else str(value))}")


pr, err = oc_json("get", "pipelinerun", name, "-n", ns)
if pr is None:
    print(f"ERROR: cannot read PipelineRun {name} in {ns}: {err}", file=sys.stderr)
    emit("PR_SUCCEEDED", "Unknown")
    sys.exit(0)

status = pr.get("status", {}) or {}
conditions = status.get("conditions", []) or []
succeeded = next((c for c in conditions if c.get("type") == "Succeeded"), None)
emit("PR_SUCCEEDED", (succeeded or {}).get("status", "Unknown"))
emit("PR_REASON", (succeeded or {}).get("reason", ""))
emit("PR_MESSAGE", (succeeded or {}).get("message", ""))


def result_value(v):
    if isinstance(v, dict):
        return v.get("stringVal", v)
    return v


# Pipeline-level results (only present if the Pipeline spec declares top-level
# `results:` that surface task results). Preferred when present.
pipeline_results = {}
for item in status.get("results", []) or []:
    n = item.get("name")
    if n:
        pipeline_results[n] = result_value(item.get("value"))


def find_taskrun_name(pipeline_task_name):
    for ref in status.get("childReferences", []) or []:
        if ref.get("pipelineTaskName") == pipeline_task_name:
            return ref.get("name")
    # Older Tekton versions without childReferences (v1beta1 status.taskRuns map).
    for tr_name, tr in (status.get("taskRuns") or {}).items():
        if tr.get("pipelineTaskName") == pipeline_task_name:
            return tr_name
    return None


def task_results(pipeline_task_name):
    tr_name = find_taskrun_name(pipeline_task_name)
    if not tr_name:
        return {}, f"no TaskRun found for pipelineTask {pipeline_task_name}"
    tr, terr = oc_json("get", "taskrun", tr_name, "-n", ns)
    if tr is None:
        return {}, terr
    out = {}
    for item in (tr.get("status", {}) or {}).get("results", []) or []:
        n = item.get("name")
        if n:
            out[n] = result_value(item.get("value"))
    return out, None


gate_results, gate_err = task_results("ai-quality-gate")
build_results, build_err = task_results("build-backend")
pub_results, pub_err = task_results("publish-candidate")

score = pipeline_results.get("score", gate_results.get("score", ""))
status_val = pipeline_results.get("status", gate_results.get("status", ""))
digest = pipeline_results.get("digest", build_results.get("digest", ""))
promo_ref = (
    pipeline_results.get("PROMOTION_IMAGE_REFERENCE")
    or pub_results.get("PROMOTION_IMAGE_REFERENCE")
    or ""
)
promo_digest = pub_results.get("PROMOTION_IMAGE_DIGEST", "")
promo_verified = pub_results.get("PROMOTION_REGISTRY_VERIFIED", "")
internal_ref = (
    pub_results.get("INTERNAL_IMAGE_REFERENCE")
    or build_results.get("IMAGE_REFERENCE")
    or ""
)

emit("QUALITY_SCORE", score)
emit("QUALITY_STATUS", status_val)
emit("BUILD_DIGEST", digest)
emit("PROMOTION_IMAGE_REFERENCE", promo_ref)
emit("PROMOTION_IMAGE_DIGEST", promo_digest)
emit("PROMOTION_REGISTRY_VERIFIED", promo_verified)
emit("INTERNAL_IMAGE_REFERENCE", internal_ref)

if gate_err:
    print(f"WARN: ai-quality-gate TaskRun lookup: {gate_err}", file=sys.stderr)
if build_err:
    print(f"WARN: build-backend TaskRun lookup: {build_err}", file=sys.stderr)
if pub_err:
    print(f"WARN: publish-candidate TaskRun lookup: {pub_err}", file=sys.stderr)
PY
}

# Edit deploy/overlays/prod/kustomization.yaml — packmate-backend image entry
# ONLY (newName + digest). Never touches other images or dev overlay.
edit_prod_overlay() {
  packmate_set_prod_backend_ref "$1" "$2" "$3"
}

block_no_promotion_diff() {
  local current="$1" candidate="$2"
  printf 'BLOCKED_NO_PROMOTION_DIFF\n' >&2
  cat >&2 <<EOF
DETAIL  PROD already uses candidate ${candidate}
DETAIL  current PROD digest=${current}
ACTION  Prepare the disposable fork/demo branch with the known-good baseline
        before starting the Pipeline exercise.
ACTION  make verify-demo-baseline
ACTION  make prepare-demo-baseline
EOF
  exit 1
}

assert_github_write_ready_or_manual() {
  if [[ "${ALLOW_MANUAL_PROMOTION_COMPLETION}" == "true" ]]; then
    warn "ALLOW_MANUAL_PROMOTION_COMPLETION=true — skipping authenticated push pre-check"
    return 0
  fi
  local origin_url probe_log
  origin_url="$(packmate_remote_url origin)"
  # Fail early on known broken VS Code askpass before creating a promote branch
  if [[ -n "${GIT_ASKPASS:-}" ]] && { [[ "${GIT_ASKPASS}" == *".cursor-server"* ]] || [[ "${GIT_ASKPASS}" == *"askpass"* ]]; }; then
    if [[ -n "${VSCODE_GIT_IPC_HANDLE:-}" ]]; then
      warn "VS Code/Cursor askpass detected — HTTPS git push often fails with ECONNREFUSED"
      warn "Unset GIT_ASKPASS SSH_ASKPASS in a system terminal, or set ALLOW_MANUAL_PROMOTION_COMPLETION=true"
    fi
  fi
  # Prefer gh API permission when available
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    local fork_repo perm
    fork_repo="$(packmate_normalize_github_owner_repo "$(packmate_writable_repo_url)")"
    perm="$(gh api "repos/${fork_repo}" --jq '.permissions.push // .permissions.admin // false' 2>/dev/null || true)"
    if [[ "${perm}" == "true" ]]; then
      log "OK: authenticated GitHub write permission verified via API"
      return 0
    fi
  fi
  # Lightweight dry-run: does not create a lasting remote ref
  probe_log="$(mktemp)"
  if git push --dry-run origin "HEAD:refs/heads/packmate-write-probe-dryrun" \
      >"${probe_log}" 2>&1; then
    rm -f "${probe_log}"
    log "OK: git push --dry-run to fork succeeded"
    return 0
  fi
  if grep -qiE 'ECONNREFUSED|askpass|403|Authentication failed|could not read Username' "${probe_log}"; then
    printf 'BLOCKED_GITHUB_WRITE_UNAVAILABLE\n' >&2
    warn "Authenticated push to the fork is not available (see dry-run log excerpt)"
    sed -n '1,12p' "${probe_log}" >&2 || true
    rm -f "${probe_log}"
    cat >&2 <<'EOF'
ACTION  make verify-github-write-readiness
ACTION  Supported options (never store tokens in Git or sandbox.env):
        A) Fine-grained GitHub token at the interactive HTTPS password prompt
        B) Organization-approved git credential helper (user-configured)
        C) SSH remote when a valid SSH key is already available
ACTION  Or set ALLOW_MANUAL_PROMOTION_COMPLETION=true to create the branch locally
        and finish push/PR in a browser/terminal yourself
EOF
    exit 1
  fi
  rm -f "${probe_log}"
  warn "Could not positively verify push auth — continuing; push may still fail"
}

github_compare_url() {
  local branch="$1"
  local remote_url repo_path
  remote_url="$(packmate_writable_repo_url 2>/dev/null || git config --get remote.origin.url || true)"
  [[ -n "${remote_url}" ]] || return 0
  repo_path="$(packmate_normalize_github_owner_repo "${remote_url}" 2>/dev/null || true)"
  [[ -n "${repo_path}" ]] || return 0
  printf 'https://github.com/%s/compare/%s...%s?expand=1\n' "${repo_path}" "${BASE_BRANCH}" "${branch}"
}

assert_fork_promotion_safe() {
  log "=== Fork-first promotion safety ==="
  packmate_assert_origin_not_canonical || exit 1
  packmate_assert_promotion_repo_allowed || exit 1
  packmate_assert_pr_base_in_fork "${BASE_BRANCH}" || exit 1
  local writable_norm
  writable_norm="$(packmate_normalize_github_owner_repo "$(packmate_writable_repo_url)")"
  log "OK: promotion target fork=${writable_norm} base=${BASE_BRANCH}"
  log "OK: PR will be fork branch → fork ${BASE_BRANCH} (not canonical upstream)"
}

print_manual_push_instructions() {
  local branch="$1"
  cat <<EOF

Manual push required (no gh auth / push not completed automatically):
  git push -u origin ${branch}

Then open a PR to ${BASE_BRANCH}:
$(github_compare_url "${branch}")
EOF
}

# ---------------------------------------------------------------------------
# Gather promotion data (pipeline mode or legacy mode)
# ---------------------------------------------------------------------------
QUALITY_SCORE=""
QUALITY_STATUS=""
BUILD_DIGEST=""
PROMOTION_IMAGE_REFERENCE="${PROMOTION_IMAGE_REFERENCE:-}"
PROMOTION_IMAGE_DIGEST="${PROMOTION_IMAGE_DIGEST:-}"
PROMOTION_REGISTRY_VERIFIED="${PROMOTION_REGISTRY_VERIFIED:-}"
INTERNAL_IMAGE_REFERENCE="${INTERNAL_IMAGE_REFERENCE:-}"
PROMO_KIND=""
PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE="${PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE:-true}"
PACKMATE_PROMOTION_REGISTRY="${PACKMATE_PROMOTION_REGISTRY:-ghcr.io}"
PACKMATE_PROMOTION_REGISTRY_OWNER="${PACKMATE_PROMOTION_REGISTRY_OWNER:-Lindagh1}"
PACKMATE_PROMOTION_IMAGE_NAME="${PACKMATE_PROMOTION_IMAGE_NAME:-packmate-backend}"

is_non_portable_ref() {
  local r="$1"
  [[ "${r}" == image-registry.openshift-image-registry.svc:* ]] \
    || [[ "${r}" == *default-route-openshift-image-registry* ]] \
    || [[ "${r}" == 172.30.* ]] \
    || [[ "${r}" == *.svc:* ]] \
    || [[ "${r}" == *.svc.cluster.local:* ]]
}

if [[ -n "${PIPELINERUN}" ]]; then
  PROMO_KIND="pipelinerun"
  require_oc

  log "=== Packmate backend promotion (PipelineRun mode) ==="
  log "namespace=${NAMESPACE} pipelinerun=${PIPELINERUN} threshold=${THRESHOLD}"

  eval "$(extract_pipeline_data "${NAMESPACE}" "${PIPELINERUN}")"

  [[ "${PR_SUCCEEDED:-}" == "True" ]] \
    || die "PipelineRun ${PIPELINERUN} did not succeed (Succeeded=${PR_SUCCEEDED:-Unknown}${PR_REASON:+, reason=${PR_REASON}})"
  log "OK: PipelineRun ${PIPELINERUN} Succeeded=True"

  [[ -n "${QUALITY_STATUS}" ]] || die "could not read ai-quality-gate 'status' result"
  [[ -n "${QUALITY_SCORE}" ]] || die "could not read ai-quality-gate 'score' result"

  [[ "${QUALITY_STATUS}" == "PASS" ]] \
    || die "AI quality gate status=${QUALITY_STATUS} (must be PASS)"

  if ! awk -v s="${QUALITY_SCORE}" -v t="${THRESHOLD}" 'BEGIN{exit !(s+0 >= t+0)}'; then
    die "AI quality score ${QUALITY_SCORE} below threshold ${THRESHOLD}"
  fi
  log "OK: quality gate status=${QUALITY_STATUS} score=${QUALITY_SCORE} (threshold ${THRESHOLD})"

  # Prefer durable external promotion reference from publish-candidate.
  if [[ -n "${PROMOTION_IMAGE_REFERENCE}" ]]; then
    IMAGE_REFERENCE="${PROMOTION_IMAGE_REFERENCE}"
  elif [[ -n "${BUILD_DIGEST}" ]]; then
    IMAGE_REFERENCE="${IMAGE_NAME}@$(normalize_digest "${BUILD_DIGEST}")"
  else
    die "could not read PROMOTION_IMAGE_REFERENCE or build-backend digest"
  fi

  if [[ "${PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE}" == "true" ]]; then
    if is_non_portable_ref "${IMAGE_REFERENCE}"; then
      printf 'BLOCKED_NON_PORTABLE_PROD_IMAGE_REFERENCE\n' >&2
      die "Promotion reference is cluster-local (${IMAGE_REFERENCE}). Use publish-candidate external digest."
    fi
    [[ "${PROMOTION_REGISTRY_VERIFIED}" == "true" || "${IMAGE_REFERENCE}" == ghcr.io/*@sha256:* ]] \
      || die "PROMOTION_REGISTRY_VERIFIED is not true"
  fi
else
  PROMO_KIND="legacy"
  DIGEST="$(normalize_digest "${LEGACY_DIGEST}")"
  IMAGE_NAME="${IMAGE_NAME:-${PACKMATE_PROMOTION_REGISTRY}/${PACKMATE_PROMOTION_REGISTRY_OWNER}/${PACKMATE_PROMOTION_IMAGE_NAME}}"
  IMAGE_REFERENCE="${IMAGE_NAME}@${DIGEST}"

  log "=== Packmate backend promotion (legacy digest mode) ==="
  log "namespace=${NAMESPACE}"
  warn "legacy mode skips PipelineRun / AI quality gate verification — promoting on operator confirmation only"
  if [[ "${PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE}" == "true" ]] && is_non_portable_ref "${IMAGE_REFERENCE}"; then
    printf 'BLOCKED_NON_PORTABLE_PROD_IMAGE_REFERENCE\n' >&2
    die "Legacy promotion rejected non-portable internal registry reference"
  fi
fi

[[ "${IMAGE_REFERENCE}" == *@sha256:* ]] || die "image reference must be digest-pinned: ${IMAGE_REFERENCE}"
[[ "${IMAGE_REFERENCE}" != *:latest* ]] || die "Refuse :latest in promotion reference"

IMAGE_NAME="${IMAGE_REFERENCE%@*}"
DIGEST="$(normalize_digest "${IMAGE_REFERENCE##*@}")"
[[ "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid digest format: ${DIGEST}"

SHORT="$(short_digest "${DIGEST}")"
BRANCH="promote/backend-${SHORT}"

log "image_reference=${IMAGE_REFERENCE}"
log "internal_build_reference=${INTERNAL_IMAGE_REFERENCE:-n/a}"

# External digests are not expected in the lab ImageStream.
if is_non_portable_ref "${IMAGE_REFERENCE}"; then
  verify_image_exists "${NAMESPACE}" "${DIGEST}"
fi

# Early no-diff check — BEFORE confirm / branch / file edits
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
CURRENT_PROD_REF=""
CURRENT_PROD_DIGEST=""
if CURRENT_PROD_REF="$(packmate_read_prod_backend_ref "${OVERLAY}")"; then
  CURRENT_PROD_DIGEST="$(packmate_normalize_digest "${CURRENT_PROD_REF##*@}")"
  log "current PROD backend=${CURRENT_PROD_REF}"
  if [[ "${CURRENT_PROD_DIGEST}" == "${DIGEST}" ]]; then
    block_no_promotion_diff "${CURRENT_PROD_DIGEST}" "${DIGEST}"
  fi
else
  die "could not read current PROD backend digest from ${OVERLAY_REL}"
fi

if git show-ref --verify --quiet "refs/heads/${BASE_BRANCH}" \
  || git show-ref --verify --quiet "refs/remotes/origin/${BASE_BRANCH}"; then
  base_blob="$(git show "${BASE_BRANCH}:${OVERLAY_REL}" 2>/dev/null \
    || git show "origin/${BASE_BRANCH}:${OVERLAY_REL}" 2>/dev/null || true)"
  if [[ -n "${base_blob}" ]]; then
    base_digest="$(printf '%s' "${base_blob}" | python3 -c '
import re,sys
t=sys.stdin.read()
m=re.search(r"- name: quay\.io/example/packmate-backend\n(?:.*\n)*?digest:\s*(sha256:[0-9a-f]+)", t)
print(m.group(1) if m else "")
')"
    if [[ -n "${base_digest}" ]]; then
      base_digest="$(normalize_digest "${base_digest}")"
      if [[ "${base_digest}" == "${DIGEST}" ]]; then
        block_no_promotion_diff "${base_digest}" "${DIGEST}"
      fi
    fi
  fi
fi

if [[ "${PROMO_KIND}" == "legacy" ]]; then
  echo
  echo "Will update ${OVERLAY_REL} (PRODUCTION overlay ONLY):"
  echo "  packmate-backend -> ${IMAGE_REFERENCE}"
  echo
  read -r -p "Apply this digest to the PRODUCTION overlay? [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]] || { log "Aborted by user"; exit 0; }
fi

# ---------------------------------------------------------------------------
# Fork safety (before branch / commit / push / PR)
# ---------------------------------------------------------------------------
assert_fork_promotion_safe
assert_github_write_ready_or_manual

# ---------------------------------------------------------------------------
# Branch, edit, diff, commit
# ---------------------------------------------------------------------------
if [[ "${CURRENT_BRANCH}" != "${BASE_BRANCH}" ]]; then
  warn "current branch is '${CURRENT_BRANCH}', expected '${BASE_BRANCH}' — branching from HEAD anyway"
fi

# Refuse to reuse a stale promote branch name
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  die "Local branch ${BRANCH} already exists — delete it only if unused: git branch -D ${BRANCH}"
fi

git checkout -b "${BRANCH}"

edit_prod_overlay "${OVERLAY}" "${IMAGE_NAME}" "${DIGEST}"

echo
echo "--- git diff (${OVERLAY_REL}) ---"
git --no-pager diff -- "${OVERLAY_REL}" || true
echo "--- end diff ---"
echo

if git diff --quiet -- "${OVERLAY_REL}" && git diff --cached --quiet -- "${OVERLAY_REL}"; then
  # Should be unreachable after the early check; clean up defensively.
  printf 'BLOCKED_NO_PROMOTION_DIFF\n' >&2
  warn "No changes after edit — cleaning up empty promote branch"
  git checkout "${CURRENT_BRANCH}" >/dev/null 2>&1 || true
  git branch -D "${BRANCH}" >/dev/null 2>&1 || true
  block_no_promotion_diff "${DIGEST}" "${DIGEST}"
fi

# Guard: only the PROD overlay may be staged
mapfile -t dirty_names < <(git diff --name-only)
if [[ "${#dirty_names[@]}" -ne 1 || "${dirty_names[0]}" != "${OVERLAY_REL}" ]]; then
  warn "unexpected dirty files: ${dirty_names[*]-none}"
  git checkout -- "${OVERLAY_REL}" >/dev/null 2>&1 || true
  git checkout "${CURRENT_BRANCH}" >/dev/null 2>&1 || true
  git branch -D "${BRANCH}" >/dev/null 2>&1 || true
  die "Promotion would change unexpected files — aborted and restored ${CURRENT_BRANCH}"
fi

git add "${OVERLAY_REL}"
git commit -m "Promote validated Packmate backend ${SHORT}"
log "OK: committed on branch ${BRANCH} (no push to ${BASE_BRANCH})"

# ---------------------------------------------------------------------------
# Push + optional PR (never push to packmate-v2 directly)
# ---------------------------------------------------------------------------
PUSHED="false"
if git push -u origin "${BRANCH}:${BRANCH}" 2>/tmp/promote-push.log; then
  PUSHED="true"
  log "OK: pushed ${BRANCH}"
else
  warn "push failed (see below) — commit is safe locally"
  cat /tmp/promote-push.log >&2 || true
fi
rm -f /tmp/promote-push.log

PR_BODY_FILE="$(mktemp)"
trap 'rm -f "${PR_BODY_FILE}"' EXIT
cat > "${PR_BODY_FILE}" <<EOF
## Packmate backend promotion

| Field | Value |
|---|---|
| Source | ${PROMO_KIND} |
| PipelineRun | ${PIPELINERUN:-N/A (legacy digest promotion)} |
| Namespace | ${NAMESPACE} |
| AI quality status | ${QUALITY_STATUS:-N/A} |
| AI quality score | ${QUALITY_SCORE:-N/A} (threshold ${THRESHOLD}) |
| Image reference | \`${IMAGE_REFERENCE}\` |
| Internal build reference | \`${INTERNAL_IMAGE_REFERENCE:-n/a}\` |
| Promotion registry verified | ${PROMOTION_REGISTRY_VERIFIED:-n/a} |
| Target environment | packmate-prod |

This PR updates **only** \`deploy/overlays/prod/kustomization.yaml\` (backend \`newName\`/\`digest\`).
No OpenShift internal-registry references are permitted in the shared PROD overlay.
No changes to the dev overlay, frontend image, MCP images, or application code.

Recovery remains GitOps-owned: correct the desired image in Git through a reviewed change.
Never patch the Git-managed PROD Deployment directly. Argo CD Application \`packmate-prod\`
still requires a manual Sync after an approved merge (prune=false, selfHeal=false).
EOF

FORK_REPO="$(packmate_normalize_github_owner_repo "$(packmate_writable_repo_url)")"

if [[ "${CREATE_PR}" == "true" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if [[ "${PUSHED}" != "true" ]]; then
      warn "cannot create PR: branch was not pushed"
      print_manual_push_instructions "${BRANCH}"
      exit 0
    fi
    # PR must stay inside the fork: head branch → PROMOTION_BASE_BRANCH on the same repo
    packmate_assert_pr_base_in_fork "${BASE_BRANCH}" || exit 1
    PR_URL="$(gh pr create \
      --repo "${FORK_REPO}" \
      --base "${BASE_BRANCH}" \
      --head "${BRANCH}" \
      --title "Promote validated Packmate backend ${SHORT}" \
      --body-file "${PR_BODY_FILE}")"
    log "OK: opened PR ${PR_URL} (fork ${FORK_REPO}: ${BRANCH} → ${BASE_BRANCH})"

    if [[ "${MERGE_PR}" == "true" ]]; then
      warn "--merge-pr set: merging PR automatically (automated Cursor validation mode only)"
      gh pr merge --repo "${FORK_REPO}" "${BRANCH}" --merge --delete-branch=false \
        || warn "automatic PR merge failed — merge manually: ${PR_URL}"
    fi
  else
    warn "gh not authenticated — cannot create PR automatically"
    print_manual_push_instructions "${BRANCH}"
  fi
else
  if [[ "${MERGE_PR}" == "true" ]]; then
    warn "--merge-pr ignored without --create-pr"
  fi
  if [[ "${PUSHED}" != "true" ]]; then
    print_manual_push_instructions "${BRANCH}"
  else
    log "Branch pushed to fork. Open a PR to ${BASE_BRANCH} in ${FORK_REPO} when ready:"
    github_compare_url "${BRANCH}"
  fi
fi

exit 0
