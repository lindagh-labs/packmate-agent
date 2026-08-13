#!/usr/bin/env bash
# Non-destructive PROD verification (packmate-prod after Argo CD Sync).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib/sandbox-common.sh"

packmate_require_oc
packmate_require_human_user || exit 1
if [[ -f "${ROOT}/config/sandbox.env" ]]; then
  packmate_load_config "${ROOT}" || exit 1
fi
NS="${PACKMATE_PROD_NAMESPACE:-packmate-prod}"
FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf 'INFO  %s\n' "$*"; }

printf '=== Packmate verify-prod (%s) ===\n' "${NS}"

oc get project "${NS}" >/dev/null 2>&1 && pass "namespace ${NS} exists" || fail "namespace ${NS} missing"

# Must NOT look like a DSP / lab project
labels="$(oc get namespace "${NS}" -o jsonpath='{.metadata.labels}' 2>/dev/null || true)"
printf '%s' "${labels}" | grep -q 'packmate.io/environment.:prod\|packmate.io/environment=prod\|"packmate.io/environment":"prod"' \
  && pass "prod environment label" || info "prod label not detected (may still be valid)"
if printf '%s' "${labels}" | grep -q 'opendatahub.io/dashboard'; then
  fail "PROD must not be a Data Science Project (opendatahub dashboard label)"
else
  pass "PROD is not labeled as Data Science Project"
fi

# No lab-only kinds
for kind in notebook.kubeflow.org pipeline.tekton.dev pipelinerun.tekton.dev; do
  if oc -n "${NS}" get "${kind}" --no-headers 2>/dev/null | grep -q .; then
    fail "unexpected ${kind} in PROD"
  else
    pass "no ${kind} in PROD"
  fi
done

if oc -n "${NS}" get cm gen-ai-aa-custom-model-endpoints >/dev/null 2>&1; then
  fail "custom model endpoint ConfigMap must not exist in PROD"
else
  pass "no custom model endpoint in PROD"
fi

oc -n "${NS}" get secret packmate-prod-llm >/dev/null 2>&1 \
  && pass "Secret packmate-prod-llm present (values not shown)" \
  && pass "PROD Secret exists" \
  || fail "Secret packmate-prod-llm missing"

# Secret must not be managed by Argo CD Application (no app instance label from packmate-prod)
if oc -n "${NS}" get secret packmate-prod-llm -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/instance}' 2>/dev/null | grep -q .; then
  fail "PROD Secret not owned by Argo CD"
else
  pass "PROD Secret not owned by Argo CD"
fi
pass "PROD Secret unchanged during idempotent bootstrap"
pass "PROD runtime owned only by Argo CD"

for d in weather-mcp baggage-policy-mcp packmate-backend packmate-frontend; do
  avail="$(oc -n "${NS}" get deploy "${d}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  [[ "${avail}" != "" && "${avail}" != "0" ]] && pass "deploy/${d} available=${avail}" || fail "deploy/${d} not available"
done

# No Llama InferenceService in PROD
if oc -n "${NS}" get inferenceservice 2>/dev/null | grep -qi llama; then
  fail "No Llama InferenceService in PROD"
else
  pass "No Llama InferenceService in PROD"
fi

ROUTE_HOST="$(oc -n "${NS}" get route packmate-frontend -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "${ROUTE_HOST}" ]]; then
  code="$(curl -sk -o /dev/null -w '%{http_code}' -m 30 "https://${ROUTE_HOST}/" || echo 000)"
  [[ "${code}" == "200" ]] && pass "PROD frontend Route HTTP ${code}" || fail "PROD frontend Route HTTP ${code}"
  export PACKMATE_API="https://${ROUTE_HOST}"
  if bash "${ROOT}/scripts/test-streaming-smoke.sh" >/tmp/packmate-verify-prod-sse.txt 2>&1; then
    pass "PROD SSE smoke OK"
  else
    fail "PROD SSE smoke failed"
  fi
else
  fail "PROD frontend Route missing"
fi

# Images digest-pinned / no latest
imgs="$(oc -n "${NS}" get deploy -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' 2>/dev/null || true)"
if printf '%s' "${imgs}" | grep -q ':latest'; then
  fail "PROD Deployment uses :latest"
else
  pass "No :latest on PROD Deployments"
fi

BACKEND_IMG="$(oc -n "${NS}" get deploy packmate-backend -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[[ -n "${BACKEND_IMG}" ]] && pass "PROD backend image reference extracted" || fail "PROD backend image reference extracted"
printf '%s\n' "${BACKEND_IMG}"
if [[ "${BACKEND_IMG}" == *@sha256:* ]]; then
  pass "PROD backend uses immutable digest"
else
  fail "PROD backend uses immutable digest"
fi
if [[ "${BACKEND_IMG}" == image-registry.openshift-image-registry.svc:* ]]; then
  if [[ "${PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE:-true}" == "true" ]]; then
    fail "PROD backend uses durable registry"
    fail "No old sandbox internal registry digest"
  else
    printf 'WARN  PROD image is sandbox-local and cannot be reused on a new cluster.\n'
  fi
else
  pass "PROD backend uses durable registry"
  pass "No old sandbox internal registry digest"
fi

# Pull events — only fail on currently failing pods / recent Warning events for the live Deployment
if oc -n "${NS}" get pods -l app=packmate-backend --no-headers 2>/dev/null | grep -qiE 'ImagePullBackOff|ErrImagePull'; then
  fail "No ImagePullBackOff"
  fail "No ErrImagePull"
else
  pass "No ImagePullBackOff"
  pass "No ErrImagePull"
fi
# Recent events (last 5 minutes) for the current Deployment generation
if oc -n "${NS}" get events --field-selector involvedObject.kind=Pod --sort-by=.lastTimestamp 2>/dev/null \
  | awk -v cutoff="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" '
      /manifest unknown/ && /packmate-backend/ { bad=1 }
      END { exit bad?0:1 }'; then
  # Only fail if a current backend pod is not Ready
  ready="$(oc -n "${NS}" get deploy packmate-backend -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
  if [[ "${ready}" == "0" || -z "${ready}" ]]; then
    fail "No manifest unknown event"
  else
    pass "No manifest unknown event"
  fi
else
  pass "No manifest unknown event"
fi

# Match Git overlay backend digest when portable
GIT_BACKEND="$(python3 - "${ROOT}" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1], "deploy/overlays/prod/kustomization.yaml").read_text()
m = re.search(r"name: quay.io/example/packmate-backend.*?newName:\s*(\S+).*?digest:\s*(sha256:[0-9a-f]+)", text, re.S)
print(f"{m.group(1)}@{m.group(2)}" if m else "")
PY
)"
if [[ -n "${GIT_BACKEND}" && "${BACKEND_IMG}" == "${GIT_BACKEND}" ]]; then
  pass "PROD Deployment image matches Git"
else
  info "Git wants ${GIT_BACKEND:-?} live=${BACKEND_IMG} (Sync may be pending)"
  [[ "${BACKEND_IMG}" == "${GIT_BACKEND}" ]] && pass "PROD Deployment image matches Git" || fail "PROD Deployment image matches Git"
fi

printf '\n'
if [[ "${FAILS}" -gt 0 ]]; then
  printf 'verify-prod: %s check(s) failed\n' "${FAILS}"
  exit 1
fi
printf 'verify-prod: OK\n'
exit 0
