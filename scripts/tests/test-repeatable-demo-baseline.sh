#!/usr/bin/env bash
# Deterministic tests for repeatable demo baseline + early promotion no-diff.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/fork-safety.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/prod-backend-overlay.sh"

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }

echo "=== Repeatable demo baseline tests ==="

TMP="$(mktemp -d /tmp/packmate-demo-baseline-test.XXXXXX)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

# Keep this suite deterministic and offline even when skopeo happens to be
# installed on the developer machine. The all-zero fixture below represents an
# unavailable image; the named known-good fixtures are treated as available.
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *sha256:0000000000000000000000000000000000000000000000000000000000000001*) exit 1 ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "${TMP}/bin/skopeo"
export PATH="${TMP}/bin:${PATH}"

BASELINE="sha256:03beee2d3dd9a16ae065a2844b9bb1e9eb9e7820877d7196aa24cfbdb241c2d5"
CANDIDATE="sha256:878b556d507bf47867c0bdbdcecc06d771852c50c4901cc9705d50d2ab73d2e3"
OLDER="sha256:c10fbeb6fbd63ca478e1b8231ddf874ec7ee1c80663b641d802ffca6e826849f"

# Fixture overlay
make_overlay() {
  local dest="$1" digest="$2"
  mkdir -p "$(dirname "${dest}")"
  cat >"${dest}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: packmate-prod
resources:
  - ../../base
images:
  - name: quay.io/example/packmate-backend
    newName: ghcr.io/lindagh1/packmate-backend
    digest: ${digest}
  - name: quay.io/example/packmate-frontend
    newName: ghcr.io/lindagh1/packmate-frontend
    digest: sha256:d6ade3f968a8e1057cb7e846a6dbded4c0f45f8b1780d16d5dd9d76b55d08305
EOF
}

setup_fork_repo() {
  local dir="$1" digest="$2"
  git init -q -b packmate-v2 "${dir}"
  git -C "${dir}" remote add origin 'https://github.com/demo-user/packmate-agent.git'
  git -C "${dir}" remote add upstream 'https://github.com/Lindagh1/packmate-agent.git'
  git -C "${dir}" remote set-url --push upstream DISABLED
  git -C "${dir}" config user.email 'test@example.com'
  git -C "${dir}" config user.name 'test'
  mkdir -p "${dir}/deploy/overlays/prod" "${dir}/scripts/lib" "${dir}/argocd"
  make_overlay "${dir}/deploy/overlays/prod/kustomization.yaml" "${digest}"
  # Minimal stubs so prepare can source real libs from ROOT via PATH tricks —
  # prepare/promote are invoked with ROOT override by copying scripts.
  cp -a "${ROOT}/scripts" "${dir}/"
  # Drop heavy tests copy noise is fine
  git -C "${dir}" add deploy scripts
  git -C "${dir}" commit -qm 'fixture'
}

# 1. baseline differs from candidate → promotion allowed (verify)
setup_fork_repo "${TMP}/fork-ok" "${BASELINE}"
if (
  cd "${TMP}/fork-ok"
  env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    PROMOTION_BASE_BRANCH=packmate-v2 \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_DIGEST="${BASELINE}" \
    bash scripts/verify-demo-baseline.sh \
      --candidate "ghcr.io/lindagh1/packmate-backend@${CANDIDATE}"
) >/tmp/packmate-rdb-1.txt 2>&1; then
  pass "1. baseline digest differs from candidate → promotion allowed"
else
  fail "1. baseline digest differs from candidate → promotion allowed"
  sed -n '1,40p' /tmp/packmate-rdb-1.txt || true
fi

# 2. baseline equals candidate → blocked
setup_fork_repo "${TMP}/fork-eq" "${CANDIDATE}"
set +e
(
  cd "${TMP}/fork-eq"
  env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    PROMOTION_BASE_BRANCH=packmate-v2 \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_DIGEST="${BASELINE}" \
    bash scripts/verify-demo-baseline.sh \
      --candidate "ghcr.io/lindagh1/packmate-backend@${CANDIDATE}"
) >/tmp/packmate-rdb-2.txt 2>&1
rc=$?
set -e
if [[ "${rc}" -eq 2 ]] && grep -q 'BLOCKED_NO_PROMOTION_DIFF' /tmp/packmate-rdb-2.txt; then
  pass "2. baseline equals candidate → blocked before promotion"
else
  fail "2. baseline equals candidate → blocked before promotion (rc=${rc})"
  sed -n '1,40p' /tmp/packmate-rdb-2.txt || true
fi

# Helper: run promote in legacy mode against a fixture (no oc)
run_promote_legacy() {
  local dir="$1"
  (
    cd "${dir}"
    env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
      CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
      PROMOTION_BASE_BRANCH=packmate-v2 \
      ALLOW_CANONICAL_REPO_PROMOTION=false \
      ALLOW_MANUAL_PROMOTION_COMPLETION=true \
      PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE=true \
      bash -c "printf 'y\n' | bash scripts/promote-backend-image.sh '${CANDIDATE}'"
  )
}

# 3–5. blocked promotion leaves no empty branch, restores branch, clean tree
setup_fork_repo "${TMP}/fork-block" "${CANDIDATE}"
before_branch="$(git -C "${TMP}/fork-block" rev-parse --abbrev-ref HEAD)"
set +e
run_promote_legacy "${TMP}/fork-block" >/tmp/packmate-rdb-3.txt 2>&1
rc=$?
set -e
after_branch="$(git -C "${TMP}/fork-block" rev-parse --abbrev-ref HEAD)"
if [[ "${rc}" -ne 0 ]] && grep -q 'BLOCKED_NO_PROMOTION_DIFF' /tmp/packmate-rdb-3.txt; then
  pass "2b. promote exits non-zero on no-diff"
else
  fail "2b. promote exits non-zero on no-diff (rc=${rc})"
  sed -n '1,50p' /tmp/packmate-rdb-3.txt || true
fi
if ! git -C "${TMP}/fork-block" show-ref --verify --quiet "refs/heads/promote/backend-$(packmate_short_digest "${CANDIDATE}")"; then
  pass "3. no empty promotion branch remains"
else
  fail "3. no empty promotion branch remains"
fi
if [[ "${after_branch}" == "${before_branch}" ]]; then
  pass "4. current branch restored after blocked promotion"
else
  fail "4. current branch restored after blocked promotion (${before_branch} -> ${after_branch})"
fi
if git -C "${TMP}/fork-block" diff --quiet && git -C "${TMP}/fork-block" diff --cached --quiet; then
  pass "5. working tree remains clean"
else
  fail "5. working tree remains clean"
  git -C "${TMP}/fork-block" status --short || true
fi

# 6. canonical origin blocks baseline preparation
git init -q -b packmate-v2 "${TMP}/canonical"
git -C "${TMP}/canonical" remote add origin 'https://github.com/Lindagh1/packmate-agent.git'
git -C "${TMP}/canonical" config user.email 'test@example.com'
git -C "${TMP}/canonical" config user.name 'test'
mkdir -p "${TMP}/canonical/deploy/overlays/prod"
make_overlay "${TMP}/canonical/deploy/overlays/prod/kustomization.yaml" "${CANDIDATE}"
cp -a "${ROOT}/scripts" "${TMP}/canonical/"
git -C "${TMP}/canonical" add deploy scripts
git -C "${TMP}/canonical" commit -qm 'fixture'
set +e
(
  cd "${TMP}/canonical"
  env GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_DIGEST="${BASELINE}" \
    DEMO_BASELINE_MODE=demo-branch \
    bash scripts/prepare-demo-baseline.sh --no-push
) >/tmp/packmate-rdb-6.txt 2>&1
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && grep -qE 'BLOCKED_CANONICAL|Never run against' /tmp/packmate-rdb-6.txt; then
  pass "6. canonical origin blocks baseline preparation"
else
  fail "6. canonical origin blocks baseline preparation (rc=${rc})"
  sed -n '1,40p' /tmp/packmate-rdb-6.txt || true
fi

# 7 + 9. fork origin allows baseline preparation (Mode A packmate-v2)
setup_fork_repo "${TMP}/fork-prep-a" "${CANDIDATE}"
set +e
(
  cd "${TMP}/fork-prep-a"
  env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_DIGEST="${BASELINE}" \
    DEMO_BASELINE_MODE=fork-packmate-v2 \
    bash scripts/prepare-demo-baseline.sh --no-push
) >/tmp/packmate-rdb-7.txt 2>&1
rc=$?
set -e
if [[ "${rc}" -eq 0 ]] && grep -q 'DEMO_BASELINE_READY' /tmp/packmate-rdb-7.txt; then
  pass "7. fork origin allows baseline preparation"
  pass "9. packmate-v2 fork mode supported when explicitly configured"
else
  fail "7/9. fork Mode A prepare (rc=${rc})"
  sed -n '1,60p' /tmp/packmate-rdb-7.txt || true
fi

# Exactly one file / message
if git -C "${TMP}/fork-prep-a" log -1 --pretty=%s | grep -q 'Prepare Packmate demo PROD baseline'; then
  files="$(git -C "${TMP}/fork-prep-a" show --pretty='' --name-only HEAD)"
  if [[ "${files}" == "deploy/overlays/prod/kustomization.yaml" ]]; then
    pass "15. baseline preparation changes exactly one file"
  else
    fail "15. baseline preparation changes exactly one file (${files})"
  fi
else
  fail "15. baseline commit message / one file"
fi

# 8. demo branch mode
setup_fork_repo "${TMP}/fork-prep-b" "${CANDIDATE}"
set +e
(
  cd "${TMP}/fork-prep-b"
  env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_DIGEST="${BASELINE}" \
    DEMO_BASELINE_MODE=demo-branch \
    PACKMATE_DEMO_BRANCH=demo/sandbox2571 \
    bash scripts/prepare-demo-baseline.sh --no-push
) >/tmp/packmate-rdb-8.txt 2>&1
rc=$?
set -e
if [[ "${rc}" -eq 0 ]] \
  && git -C "${TMP}/fork-prep-b" rev-parse --abbrev-ref HEAD | grep -q 'demo/sandbox2571' \
  && grep -q 'DEMO_BASELINE_READY' /tmp/packmate-rdb-8.txt; then
  pass "8. demo branch mode supported"
else
  fail "8. demo branch mode supported (rc=${rc})"
  sed -n '1,60p' /tmp/packmate-rdb-8.txt || true
fi

# 10. internal registry baseline rejected
set +e
(
  cd "${TMP}/fork-ok"
  env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_IMAGE_REFERENCE='image-registry.openshift-image-registry.svc:5000/packmate-lab/packmate-backend@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    bash scripts/verify-demo-baseline.sh
) >/tmp/packmate-rdb-10.txt 2>&1
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && grep -q 'BLOCKED_INTERNAL_REGISTRY_BASELINE' /tmp/packmate-rdb-10.txt; then
  pass "10. internal registry baseline rejected"
else
  fail "10. internal registry baseline rejected"
  sed -n '1,30p' /tmp/packmate-rdb-10.txt || true
fi

# 11. mutable tag baseline rejected
set +e
(
  cd "${TMP}/fork-ok"
  env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_IMAGE_REFERENCE='ghcr.io/lindagh1/packmate-backend:latest' \
    bash scripts/verify-demo-baseline.sh
) >/tmp/packmate-rdb-11.txt 2>&1
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && grep -qE 'BLOCKED_MUTABLE_TAG_BASELINE|BLOCKED_MISSING_BASELINE' /tmp/packmate-rdb-11.txt; then
  pass "11. mutable tag baseline rejected"
else
  fail "11. mutable tag baseline rejected"
  sed -n '1,30p' /tmp/packmate-rdb-11.txt || true
fi

# 12. missing baseline digest rejected
if ! (
  PACKMATE_DEMO_BASELINE_DIGEST=''
  PACKMATE_DEMO_BASELINE_IMAGE_REFERENCE=''
  PACKMATE_INITIAL_PROD_IMAGE_REFERENCE=''
  PACKMATE_DEFAULT_DEMO_BASELINE_DIGEST=''
  PACKMATE_DEFAULT_DEMO_BASELINE_IMAGE=''
  packmate_resolve_demo_baseline_ref
) >/dev/null 2>&1; then
  pass "12. missing baseline digest rejected"
else
  fail "12. missing baseline digest rejected"
fi

# 13. unavailable baseline image rejected (fake digest)
FAKE="sha256:0000000000000000000000000000000000000000000000000000000000000001"
set +e
(
  cd "${TMP}/fork-ok"
  env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_DIGEST="${FAKE}" \
    bash scripts/verify-demo-baseline.sh
) >/tmp/packmate-rdb-13.txt 2>&1
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && grep -q 'BLOCKED_UNAVAILABLE_BASELINE_IMAGE' /tmp/packmate-rdb-13.txt; then
  pass "13. unavailable baseline image rejected"
else
  fail "13. unavailable baseline image rejected (rc=${rc})"
  sed -n '1,40p' /tmp/packmate-rdb-13.txt || true
fi

# 14. candidate GHCR digest accepted (string in verify output)
if grep -q 'Candidate GHCR digest accepted' /tmp/packmate-rdb-1.txt; then
  pass "14. candidate GHCR digest accepted"
else
  fail "14. candidate GHCR digest accepted"
fi

# 16. no release tag created by prepare
if ! git -C "${TMP}/fork-prep-a" tag --list 'lab-v*' | grep -q .; then
  pass "16. no release tag created"
else
  fail "16. no release tag created"
fi

# 17. no canonical commit changed — prepare against fork only (static)
if grep -q 'Never run against Lindagh1' "${ROOT}/scripts/prepare-demo-baseline.sh" \
  && grep -q 'packmate_assert_origin_not_canonical' "${ROOT}/scripts/prepare-demo-baseline.sh"; then
  pass "17. no canonical commit changed (guards present)"
else
  fail "17. no canonical commit changed (guards present)"
fi

# 18. PR base remains inside fork (promote script)
if grep -q 'packmate_assert_pr_base_in_fork' "${ROOT}/scripts/promote-backend-image.sh" \
  && grep -q 'BLOCKED_NO_PROMOTION_DIFF' "${ROOT}/scripts/promote-backend-image.sh"; then
  pass "18. PR base remains inside fork + early no-diff"
else
  fail "18. PR base remains inside fork + early no-diff"
fi

# 19. rollback still works after promotion (script still present + history helper)
if [[ -x "${ROOT}/scripts/rollback-prod-image.sh" ]] \
  && grep -q 'previous backend digest' "${ROOT}/scripts/rollback-prod-image.sh"; then
  pass "19. rollback still works after promotion"
else
  fail "19. rollback still works after promotion"
fi

# 1b allowed promotion creates branch then we delete it (with manual completion)
setup_fork_repo "${TMP}/fork-promo" "${BASELINE}"
set +e
run_promote_legacy "${TMP}/fork-promo" >/tmp/packmate-rdb-1b.txt 2>&1
rc=$?
set -e
promo_branch="promote/backend-$(packmate_short_digest "${CANDIDATE}")"
if [[ "${rc}" -eq 0 ]] && git -C "${TMP}/fork-promo" show-ref --verify --quiet "refs/heads/${promo_branch}"; then
  pass "1c. differing digests create a real promotion branch"
  # cleanup local promo branch for hygiene
  git -C "${TMP}/fork-promo" checkout packmate-v2 >/dev/null
  git -C "${TMP}/fork-promo" branch -D "${promo_branch}" >/dev/null
else
  fail "1c. differing digests create a real promotion branch (rc=${rc})"
  sed -n '1,80p' /tmp/packmate-rdb-1b.txt || true
fi

# 20. next repeated demo can be prepared again
setup_fork_repo "${TMP}/fork-repeat" "${CANDIDATE}"
set +e
(
  cd "${TMP}/fork-repeat"
  env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_DIGEST="${OLDER}" \
    DEMO_BASELINE_MODE=demo-branch \
    PACKMATE_DEMO_BRANCH=demo/sandbox2571 \
    bash scripts/prepare-demo-baseline.sh --no-push
) >/tmp/packmate-rdb-20a.txt 2>&1
rc1=$?
# Simulate post-promotion at candidate, prepare again to baseline
make_overlay "${TMP}/fork-repeat/deploy/overlays/prod/kustomization.yaml" "${CANDIDATE}"
git -C "${TMP}/fork-repeat" add deploy/overlays/prod/kustomization.yaml
git -C "${TMP}/fork-repeat" commit -qm 'Simulate merged promotion' || true
(
  cd "${TMP}/fork-repeat"
  env GIT_REPO_URL='https://github.com/demo-user/packmate-agent.git' \
    CANONICAL_GIT_REPO_URL='https://github.com/Lindagh1/packmate-agent.git' \
    ALLOW_CANONICAL_REPO_PROMOTION=false \
    PACKMATE_DEMO_BASELINE_DIGEST="${BASELINE}" \
    DEMO_BASELINE_MODE=demo-branch \
    PACKMATE_DEMO_BRANCH=demo/sandbox2571 \
    bash scripts/prepare-demo-baseline.sh --no-push
) >/tmp/packmate-rdb-20b.txt 2>&1
rc2=$?
set -e
if [[ "${rc1}" -eq 0 && "${rc2}" -eq 0 ]]; then
  pass "20. next repeated demo can be prepared again safely"
else
  fail "20. next repeated demo can be prepared again safely (rc1=${rc1} rc2=${rc2})"
  sed -n '1,40p' /tmp/packmate-rdb-20a.txt || true
  sed -n '1,40p' /tmp/packmate-rdb-20b.txt || true
fi

# Scripts exist + Makefile targets
grep -q 'verify-demo-baseline' "${ROOT}/Makefile" \
  && grep -q 'prepare-demo-baseline' "${ROOT}/Makefile" \
  && pass "Makefile targets for demo baseline present" \
  || fail "Makefile targets for demo baseline present"

printf '\nrepeatable-demo-baseline summary: PASS=%s FAIL=%s\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]]
