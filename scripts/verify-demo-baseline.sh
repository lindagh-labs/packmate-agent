#!/usr/bin/env bash
# Read-only check: does the configured fork/demo branch have a useful promotion
# difference between current PROD digest and a Pipeline candidate?
#
# Usage:
#   make verify-demo-baseline
#   scripts/verify-demo-baseline.sh [--pipelinerun NAME] [--namespace NS] [--candidate REF]
#
# Exit codes:
#   0  PASS — current PROD digest differs from candidate (promotion can produce a PR)
#   2  BLOCKED_NO_PROMOTION_DIFF — digests identical
#   1  other failure (misconfiguration / missing inputs)
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
PIPELINERUN=""
NAMESPACE="${PACKMATE_NAMESPACE:-packmate-lab}"
CANDIDATE_REF=""

usage() {
  cat <<'EOF'
Usage: verify-demo-baseline.sh [--pipelinerun NAME] [--namespace NS] [--candidate IMAGE@sha256:…]

Read-only. Reports whether PROD overlay digest differs from the Pipeline candidate.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipelinerun) PIPELINERUN="${2:?}"; shift 2 ;;
    --namespace) NAMESPACE="${2:?}"; shift 2 ;;
    --candidate) CANDIDATE_REF="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
done

printf '=== Packmate verify-demo-baseline (read-only) ===\n'

writable="$(packmate_writable_repo_url 2>/dev/null || true)"
origin="$(packmate_remote_url origin)"
writable_norm="$(packmate_normalize_github_owner_repo "${writable}" 2>/dev/null || true)"
origin_norm="$(packmate_normalize_github_owner_repo "${origin}" 2>/dev/null || true)"
base_branch="${PROMOTION_BASE_BRANCH:-${GIT_REVISION:-packmate-v2}}"

printf 'INFO    configured fork=%s\n' "${writable_norm:-unset}"
printf 'INFO    origin=%s\n' "${origin_norm:-unset}"
printf 'INFO    demo/base branch=%s (GIT_REVISION=%s)\n' "${base_branch}" "${GIT_REVISION:-}"

if [[ -n "${writable_norm}" ]] && packmate_is_canonical_owner_repo "${writable_norm}"; then
  packmate_blocked "Writable repository is a participant fork" \
    "GIT_REPO_URL/origin points at Lindagh1/packmate-agent" \
    "Point GIT_REPO_URL and origin at the disposable fork before promotion"
  exit 1
fi

[[ -f "${OVERLAY}" ]] || {
  packmate_fail "PROD overlay present" "missing ${OVERLAY_REL}"
  exit 1
}

current_ref="$(packmate_read_prod_backend_ref "${OVERLAY}")" || {
  packmate_fail "Readable PROD backend digest" "could not parse ${OVERLAY_REL}"
  exit 1
}
current_digest="$(packmate_normalize_digest "${current_ref##*@}")"
printf 'INFO    current PROD backend=%s\n' "${current_ref}"

baseline_rc=0
baseline_ref="$(packmate_resolve_demo_baseline_ref)" || baseline_rc=$?
if [[ "${baseline_rc}" -eq 2 ]]; then
  printf 'BLOCKED_INTERNAL_REGISTRY_BASELINE\n' >&2
  packmate_blocked "Demo baseline is durable GHCR" \
    "Configured baseline uses OpenShift internal registry" \
    "Set PACKMATE_DEMO_BASELINE_IMAGE_REFERENCE to a ghcr.io/...@sha256:… digest"
  exit 1
fi
if [[ "${baseline_rc}" -ne 0 || -z "${baseline_ref}" ]]; then
  # Distinguish mutable tag vs missing
  if [[ "${PACKMATE_DEMO_BASELINE_IMAGE_REFERENCE:-}" == *:latest* ]] \
    || [[ "${PACKMATE_INITIAL_PROD_IMAGE_REFERENCE:-}" == *:latest* ]]; then
    printf 'BLOCKED_MUTABLE_TAG_BASELINE\n' >&2
    packmate_blocked "Demo baseline is digest-pinned" \
      "baseline reference uses a mutable tag" \
      "Use an immutable @sha256:… reference"
    exit 1
  fi
  printf 'BLOCKED_MISSING_BASELINE_DIGEST\n' >&2
  packmate_blocked "Demo baseline digest configured" \
    "No PACKMATE_DEMO_BASELINE_* / PACKMATE_INITIAL_PROD_IMAGE_REFERENCE" \
    "Set PACKMATE_DEMO_BASELINE_DIGEST to a known-good sha256 from lab history (do not invent digests)"
  exit 1
fi
baseline_digest="$(packmate_normalize_digest "${baseline_ref##*@}")"
printf 'INFO    configured known-good baseline=%s\n' "${baseline_ref}"

# Reject mutable tags in baseline
if [[ "${baseline_ref}" != *@sha256:* ]] || [[ "${baseline_ref}" == *:latest* ]]; then
  printf 'BLOCKED_MUTABLE_TAG_BASELINE\n' >&2
  packmate_blocked "Demo baseline is digest-pinned" \
    "baseline=${baseline_ref}" \
    "Use an immutable @sha256:… reference"
  exit 1
fi

pull_rc=0
packmate_verify_image_ref_pullable "${baseline_ref}" || pull_rc=$?
if [[ "${pull_rc}" -eq 0 ]]; then
  packmate_pass "Baseline image is pullable"
elif [[ "${pull_rc}" -eq 2 ]]; then
  printf 'INFO    skopeo not installed — skipping live baseline pull check\n'
else
  printf 'BLOCKED_UNAVAILABLE_BASELINE_IMAGE\n' >&2
  packmate_blocked "Baseline image is available" \
    "skopeo inspect failed for configured baseline" \
    "Choose a durable GHCR digest from lab history that still exists in the registry"
  exit 1
fi

# Resolve candidate
candidate_ref="${CANDIDATE_REF}"
if [[ -z "${candidate_ref}" && -n "${PIPELINERUN}" ]]; then
  command -v oc >/dev/null 2>&1 || {
    packmate_fail "oc available for PipelineRun lookup"
    exit 1
  }
  candidate_ref="$(oc get taskrun "${PIPELINERUN}-publish-candidate" -n "${NAMESPACE}" \
    -o jsonpath='{.status.results[?(@.name=="PROMOTION_IMAGE_REFERENCE")].value}' 2>/dev/null || true)"
  if [[ -z "${candidate_ref}" ]]; then
    candidate_ref="$(oc get pipelinerun "${PIPELINERUN}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.results[?(@.name=="PROMOTION_IMAGE_REFERENCE")].value}' 2>/dev/null || true)"
  fi
fi
if [[ -z "${candidate_ref}" && -n "${PACKMATE_CANDIDATE_IMAGE_REFERENCE:-}" ]]; then
  candidate_ref="${PACKMATE_CANDIDATE_IMAGE_REFERENCE}"
fi

if [[ -z "${candidate_ref}" ]]; then
  printf 'INFO    No candidate supplied — comparing current PROD to configured baseline only\n'
  if [[ "${current_digest}" == "${baseline_digest}" ]]; then
    packmate_pass "Current PROD already matches configured demo baseline"
    printf 'RESULT  READY_FOR_PIPELINE (set baseline before Pipeline if last promo left candidate in PROD)\n'
    exit 0
  fi
  printf 'INFO    Current PROD (%s) differs from baseline (%s)\n' \
    "$(packmate_short_digest "${current_digest}")" \
    "$(packmate_short_digest "${baseline_digest}")"
  printf 'ACTION  Run: make prepare-demo-baseline\n'
  printf 'RESULT  BASELINE_DRIFT\n'
  exit 0
fi

[[ "${candidate_ref}" == *@sha256:* ]] || {
  packmate_fail "Candidate is digest-pinned" "got ${candidate_ref}"
  exit 1
}
if [[ "${candidate_ref}" == image-registry.openshift-image-registry.svc:* ]] \
  || [[ "${candidate_ref}" == *.svc:* ]]; then
  printf 'BLOCKED_NON_PORTABLE_PROD_IMAGE_REFERENCE\n' >&2
  packmate_blocked "Candidate is portable GHCR" "candidate=${candidate_ref}" \
    "Use publish-candidate PROMOTION_IMAGE_REFERENCE"
  exit 1
fi
candidate_digest="$(packmate_normalize_digest "${candidate_ref##*@}")"
printf 'INFO    Pipeline candidate=%s\n' "${candidate_ref}"

if [[ "${candidate_ref}" == ghcr.io/*@sha256:* ]]; then
  packmate_pass "Candidate GHCR digest accepted"
fi

if [[ "${current_digest}" == "${candidate_digest}" ]]; then
  printf 'BLOCKED_NO_PROMOTION_DIFF\n' >&2
  packmate_blocked "Promotion difference exists" \
    "PROD already uses candidate ${candidate_digest}" \
    "Prepare the disposable fork/demo branch with the known-good baseline before starting the Pipeline exercise (make prepare-demo-baseline)"
  printf 'RESULT  BLOCKED\n'
  exit 2
fi

packmate_pass "Current PROD digest differs from candidate digest"
printf 'RESULT  PASS (promotion can produce a PR)\n'
exit 0
