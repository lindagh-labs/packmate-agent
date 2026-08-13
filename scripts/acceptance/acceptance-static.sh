#!/usr/bin/env bash
# Static acceptance (no cluster required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${ROOT}/.generated/acceptance"
mkdir -p "${OUT}"
REPORT="${OUT}/static-$(date +%Y%m%dT%H%M%S).txt"
FAIL=0
{
  echo "=== acceptance-static ==="
  echo "root=${ROOT}"
  bash -n "${ROOT}/scripts/verify-demo-fork.sh"
  bash -n "${ROOT}/scripts/verify-demo-fork-live.sh"
  bash -n "${ROOT}/scripts/verify-github-write-readiness.sh"
  bash -n "${ROOT}/scripts/discover-packmate-resources.sh"
  bash -n "${ROOT}/scripts/reset-packmate-lab.sh"
  bash -n "${ROOT}/scripts/lib/fork-safety.sh"
  bash -n "${ROOT}/scripts/configure-participant.sh"
  make -C "${ROOT}" render
  make -C "${ROOT}" validate-prod
  make -C "${ROOT}" security-check
  make -C "${ROOT}" verify-resource-ownership
  bash "${ROOT}/scripts/tests/test-fork-first-workshop.sh"
  bash "${ROOT}/scripts/tests/test-deep-audit-hardening.sh"
  bash "${ROOT}/scripts/tests/test-participant-configuration.sh"
  bash "${ROOT}/scripts/tests/test-repeatable-demo-baseline.sh"
  bash "${ROOT}/scripts/validate-participant-guide.sh"
  echo "acceptance-static: OK"
} 2>&1 | tee "${REPORT}" || FAIL=1
[[ "${FAIL}" -eq 0 ]]
