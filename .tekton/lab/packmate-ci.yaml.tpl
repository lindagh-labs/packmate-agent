# Lab-facing Tekton Pipeline TEMPLATE: packmate-ci
# DO NOT apply this file directly. Bootstrap renders it with the current sandbox
# Python digest via scripts/render-packmate-pipeline.sh.
# Placeholder: __PACKMATE_PIPELINE_PYTHON_IMAGE__
# Placeholder: __PACKMATE_PIPELINE_CLI_IMAGE__
# Participant settings are rendered from config/sandbox.env as well.
# Participant: OpenShift Console → Pipelines → packmate-ci → Start
# IMPORTANT: workspace "source" MUST use a VolumeClaimTemplate (shared PVC).
#            Empty Directory does NOT persist between tasks — clone output is lost.
# Visual path: clone → test → ai-quality-gate → validate-manifests → build-backend → publish-candidate → publish-result
# Namespace-scoped only. Does not deploy production.
# Start a run: oc create -n packmate-lab -f .tekton/lab/packmate-ci-run.yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: packmate-pipeline
  labels:
    app.kubernetes.io/part-of: packmate
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: packmate-pipeline
  labels:
    app.kubernetes.io/part-of: packmate
rules:
  - apiGroups: ["build.openshift.io"]
    resources: ["buildconfigs", "builds", "buildconfigs/instantiate", "buildconfigs/instantiatebinary"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: ["image.openshift.io"]
    resources: ["imagestreams", "imagestreamtags", "imagestreamimages"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods", "pods/log", "configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: packmate-pipeline
  labels:
    app.kubernetes.io/part-of: packmate
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: packmate-pipeline
subjects:
  - kind: ServiceAccount
    name: packmate-pipeline
---
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: packmate-ci
  labels:
    app.kubernetes.io/part-of: packmate
    app.kubernetes.io/component: lab-pipeline
spec:
  description: >
    Packmate lab CI — clone, backend tests, deterministic AI quality gate,
    validate manifests, build backend via BuildConfig, publish digest.
    Workspace "source" requires a VolumeClaimTemplate (not Empty Directory).
  taskRunTemplate:
    serviceAccountName: packmate-pipeline
  params:
    - name: git-url
      type: string
      # Writable fork URL injected by bootstrap; canonical upstream is blocked.
      default: __PACKMATE_GIT_REPO_URL__
    - name: git-revision
      type: string
      default: __PACKMATE_GIT_REVISION__
    - name: quality-threshold
      type: string
      default: "0.90"
    - name: python-image
      type: string
      description: Immutable openshift/python digest resolved at bootstrap
      default: __PACKMATE_PIPELINE_PYTHON_IMAGE__
    - name: cli-image
      type: string
      description: Immutable openshift/cli digest resolved at bootstrap
      default: __PACKMATE_PIPELINE_CLI_IMAGE__
  workspaces:
    - name: source
      description: >
        Shared PVC for the cloned repository across all tasks.
        Use a VolumeClaimTemplate when starting the PipelineRun.
        Do not use Empty Directory — clone output will not be visible to later tasks.
  tasks:
    - name: clone
      params:
        - name: python-image
          value: $(params.python-image)
        - name: url
          value: $(params.git-url)
        - name: revision
          value: $(params.git-revision)
      workspaces:
        - name: source
          workspace: source
      taskSpec:
        params:
          - name: python-image
          - name: url
          - name: revision
        workspaces:
          - name: source
        steps:
          - name: clone
            image: $(params.python-image)
            workingDir: $(workspaces.source.path)
            env:
              - name: URL
                value: $(params.url)
              - name: REVISION
                value: $(params.revision)
              - name: HOME
                value: /workspace
            script: |
              #!/usr/bin/env bash
              set -euo pipefail
              # Avoid microdnf under restricted SCC: fetch branch tarball via curl.
              find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +
              ARCHIVE_URL="${URL%.git}/archive/refs/heads/${REVISION}.tar.gz"
              curl -fsSL -o /tmp/packmate-src.tgz "${ARCHIVE_URL}"
              tar -xzf /tmp/packmate-src.tgz --strip-components=1
              echo "WORKDIR=$(pwd)"
              echo "TOP_LEVEL=$(ls -1 | head -40)"
              if [[ ! -f backend/requirements-dev.txt ]]; then
                echo "ERROR: expected backend/requirements-dev.txt after clone"
                echo "WORKDIR=$(pwd)"
                ls -la
                exit 1
              fi
              if [[ ! -f backend/Containerfile ]]; then
                echo "ERROR: expected backend/Containerfile after clone"
                echo "WORKDIR=$(pwd)"
                ls -la backend || true
                exit 1
              fi
              # Resolve exact commit for the branch tip (best-effort; never fail clone).
              REPO_PATH="${URL#https://github.com/}"
              REPO_PATH="${REPO_PATH%.git}"
              COMMIT="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
                "https://api.github.com/repos/${REPO_PATH}/commits/${REVISION}" \
                | sed -n 's/.*"sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -1 || true)"
              [[ -n "${COMMIT}" ]] || COMMIT="unknown-${REVISION}"
              printf '%s\n' "${COMMIT}" > .git-commit
              echo "CLONE_OK revision=${REVISION} commit=${COMMIT}"

    - name: test
      runAfter: [clone]
      workspaces:
        - name: source
          workspace: source
      params:
        - name: python-image
          value: $(params.python-image)
      taskSpec:
        params:
          - name: python-image
        workspaces:
          - name: source
        steps:
          - name: backend-pytest
            image: $(params.python-image)
            workingDir: $(workspaces.source.path)/backend
            script: |
              #!/usr/bin/env bash
              set -euo pipefail
              echo "WORKDIR=$(pwd)"
              echo "WS_ROOT=$(ls -la .. 2>/dev/null | head -40 || true)"
              echo "BACKEND_LS=$(ls -la | head -40)"
              if [[ ! -f requirements-dev.txt ]]; then
                echo "ERROR: requirements-dev.txt missing in backend workspace"
                echo "WORKDIR=$(pwd)"
                echo "Expected file: $(pwd)/requirements-dev.txt"
                echo "Present files:"
                ls -la || true
                echo "Parent (repo root) files:"
                ls -la .. || true
                echo "HINT: PipelineRun workspace 'source' must use a VolumeClaimTemplate,"
                echo "      not Empty Directory (emptyDir does not share clone output across tasks)."
                exit 1
              fi
              python -m venv /tmp/venv
              # shellcheck disable=SC1091
              source /tmp/venv/bin/activate
              # RHOAI 3.4 mirror only — never fall back to public PyPI.
              export PIP_INDEX_URL="${RHOAI_PYPI_INDEX_URL:-https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple}"
              unset PIP_EXTRA_INDEX_URL || true
              python -m pip install -q -U pip
              python -m pip install -q -r requirements-dev.txt
              python -m pytest -q --maxfail=1
              echo "BACKEND_TESTS_OK"

    - name: ai-quality-gate
      runAfter: [test]
      params:
        - name: python-image
          value: $(params.python-image)
        - name: threshold
          value: $(params.quality-threshold)
      workspaces:
        - name: source
          workspace: source
      taskSpec:
        params:
          - name: python-image
          - name: threshold
        workspaces:
          - name: source
        results:
          - name: score
          - name: status
          - name: scenarios
        steps:
          - name: gate
            image: $(params.python-image)
            workingDir: $(workspaces.source.path)/backend
            env:
              - name: THRESHOLD
                value: $(params.threshold)
            script: |
              #!/usr/bin/env bash
              set -euo pipefail
              echo "WORKDIR=$(pwd)"
              if [[ ! -f requirements-dev.txt ]]; then
                echo "ERROR: requirements-dev.txt missing for quality gate"
                echo "WORKDIR=$(pwd)"
                ls -la || true
                ls -la .. || true
                echo "HINT: use VolumeClaimTemplate for workspace 'source' (not Empty Directory)."
                exit 1
              fi
              if [[ ! -d evals ]]; then
                echo "ERROR: backend/evals missing (deterministic quality gate package)"
                echo "WORKDIR=$(pwd)"
                ls -la || true
                exit 1
              fi
              python -m venv /tmp/venv
              # shellcheck disable=SC1091
              source /tmp/venv/bin/activate
              # RHOAI 3.4 mirror only — never fall back to public PyPI.
              export PIP_INDEX_URL="${RHOAI_PYPI_INDEX_URL:-https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple}"
              unset PIP_EXTRA_INDEX_URL || true
              python -m pip install -q -U pip
              python -m pip install -q -r requirements-dev.txt
              set +e
              OUT="$(python -m evals.runner --mode deterministic --threshold "${THRESHOLD}" 2>&1)"
              RC=$?
              set -e
              echo "${OUT}"
              SCORE="$(echo "${OUT}" | grep -Eo 'Overall score:[[:space:]]*[0-9]+\.[0-9]+' | grep -Eo '[0-9]+\.[0-9]+' | head -1 || true)"
              if [[ -z "${SCORE}" ]]; then
                SCORE="$(echo "${OUT}" | grep -Eo '0\.[0-9]{2,}' | head -1 || true)"
              fi
              SCEN="$(echo "${OUT}" | grep -cE '^\[PASS\]|^\[FAIL\]' || true)"
              [[ -n "${SCORE}" ]] || SCORE="0"
              [[ -n "${SCEN}" ]] || SCEN="0"
              if [[ "${RC}" -eq 0 ]]; then STATUS=PASS; else STATUS=FAIL; fi
              printf '%s' "${SCORE}" > "$(results.score.path)"
              printf '%s' "${STATUS}" > "$(results.status.path)"
              printf '%s' "${SCEN}" > "$(results.scenarios.path)"
              echo "AI_QUALITY_GATE status=${STATUS} score=${SCORE} threshold=${THRESHOLD}"
              [[ "${STATUS}" == "PASS" ]]

    - name: validate-manifests
      runAfter: [ai-quality-gate]
      workspaces:
        - name: source
          workspace: source
      params:
        - name: python-image
          value: $(params.python-image)
      taskSpec:
        params:
          - name: python-image
        workspaces:
          - name: source
        steps:
          - name: check
            image: $(params.python-image)
            workingDir: $(workspaces.source.path)
            script: |
              #!/usr/bin/env bash
              set -euo pipefail
              echo "WORKDIR=$(pwd)"
              for ov in deploy/overlays/dev deploy/overlays/prod; do
                if [[ ! -f "${ov}/kustomization.yaml" ]]; then
                  echo "ERROR: ${ov}/kustomization.yaml missing"
                  echo "WORKDIR=$(pwd)"
                  ls -la || true
                  echo "HINT: use VolumeClaimTemplate for workspace 'source' (not Empty Directory)."
                  exit 1
                fi
              done
              if grep -R --include='*.yaml' -nE 'image:.*:latest([[:space:]]|$)|newTag:[[:space:]]*latest' \
                   deploy/overlays/dev deploy/overlays/prod; then
                echo "FORBIDDEN :latest tag in overlay"
                exit 1
              fi
              # PROD must not embed DEV namespace or instructor-only lab resources.
              if grep -R --include='*.yaml' -nE 'namespace:[[:space:]]*packmate-lab' deploy/overlays/prod; then
                echo "FORBIDDEN: packmate-lab namespace in PROD overlay"
                exit 1
              fi
              if grep -R --include='*.yaml' -nEi 'kind:[[:space:]]*(Notebook|Pipeline|PipelineRun|Workbench)' \
                   deploy/overlays/prod; then
                echo "FORBIDDEN: Notebook/Pipeline/Workbench in PROD overlay"
                exit 1
              fi
              # Render both overlays when kustomize/oc available in image (best-effort).
              if command -v oc >/dev/null 2>&1; then
                oc kustomize deploy/overlays/dev >/tmp/dev.yaml
                oc kustomize deploy/overlays/prod >/tmp/prod.yaml
                grep -q 'namespace: packmate-prod' /tmp/prod.yaml
                ! grep -qE 'image:.*:latest([[:space:]]|$)' /tmp/prod.yaml
                grep -q packmate-prod-llm /tmp/prod.yaml
                echo "KUSTOMIZE_DEV_PROD_OK"
              else
                echo "KUSTOMIZE_SKIPPED (oc not in image)"
              fi
              # Guard: Pipeline scripts must never deploy to PROD (ignore comments).
              if grep -R --include='*.yaml' -nE '^[[:space:]]+(oc apply.*packmate-prod|oc set image|argocd app sync|argocd sync)' \
                   .tekton/lab 2>/dev/null | grep -vE 'echo |#|FORBIDDEN|Never deploy|must not'; then
                echo "FORBIDDEN: CI must not deploy PROD directly"
                exit 1
              fi
              echo "MANIFESTS_OK"

    - name: build-backend
      runAfter: [validate-manifests]
      workspaces:
        - name: source
          workspace: source
      params:
        - name: cli-image
          value: $(params.cli-image)
      taskSpec:
        params:
          - name: cli-image
        workspaces:
          - name: source
        results:
          - name: imagestream
          - name: digest
          - name: IMAGE_URL
          - name: IMAGE_DIGEST
          - name: IMAGE_REFERENCE
          - name: GIT_COMMIT
        steps:
          - name: start-build
            image: $(params.cli-image)
            workingDir: $(workspaces.source.path)
            env:
              - name: NAMESPACE
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.namespace
            script: |
              #!/usr/bin/env bash
              set -euo pipefail
              echo "WORKDIR=$(pwd)"
              if [[ ! -f backend/Containerfile ]]; then
                echo "ERROR: backend/Containerfile missing"
                echo "WORKDIR=$(pwd)"
                ls -la || true
                ls -la backend || true
                echo "HINT: use VolumeClaimTemplate for workspace 'source' (not Empty Directory)."
                exit 1
              fi
              if ! oc -n "${NAMESPACE}" get bc packmate-backend >/dev/null 2>&1; then
                echo "BuildConfig/packmate-backend missing in ${NAMESPACE}"
                echo "Instructor must ensure BC exists once; see docs/INSTRUCTOR_GUIDE.md"
                exit 1
              fi
              # Never deploy: no oc apply / oc set image / argocd sync here.
              BUILD="$(oc -n "${NAMESPACE}" start-build packmate-backend --from-dir=backend -o name)"
              echo "Started ${BUILD}"
              oc -n "${NAMESPACE}" logs -f "${BUILD}" || true
              for _ in $(seq 1 180); do
                phase="$(oc -n "${NAMESPACE}" get "${BUILD}" -o jsonpath='{.status.phase}')"
                case "${phase}" in
                  Complete|Failed|Error|Cancelled) break ;;
                esac
                sleep 2
              done
              phase="$(oc -n "${NAMESPACE}" get "${BUILD}" -o jsonpath='{.status.phase}')"
              [[ "${phase}" == "Complete" ]] || { echo "Build phase=${phase}"; exit 1; }
              SHA="$(oc -n "${NAMESPACE}" get "${BUILD}" -o jsonpath='{.status.output.to.imageDigest}')"
              [[ -n "${SHA}" ]] || SHA="$(oc -n "${NAMESPACE}" get is packmate-backend -o jsonpath='{.status.tags[?(@.tag=="pipeline")].items[0].image}')"
              [[ -n "${SHA}" ]] || { echo "Unable to resolve image digest"; exit 1; }
              GIT_COMMIT="$(cat .git-commit 2>/dev/null || echo unknown)"
              GIT_SHORT="$(printf '%s' "${GIT_COMMIT}" | cut -c1-7)"
              POD_NAME="$(cat /etc/hostname 2>/dev/null || true)"
              PR_HINT="$(printf '%s' "${POD_NAME}" | sed -E 's/-build-backend.*//;s/-start-build.*//;s/-pod$//')"
              CANDIDATE_TAG="${GIT_SHORT}-${PR_HINT:-pipeline}"
              # Retain a unique ImageStreamTag (never :latest) until external publication completes.
              oc -n "${NAMESPACE}" tag "packmate-backend@${SHA}" "packmate-backend:${CANDIDATE_TAG}" >/dev/null
              IMAGE_URL="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/packmate-backend"
              IMAGE_REF="${IMAGE_URL}@${SHA}"
              printf '%s' "packmate-backend" > "$(results.imagestream.path)"
              printf '%s' "${SHA}" > "$(results.digest.path)"
              printf '%s' "${IMAGE_URL}" > "$(results.IMAGE_URL.path)"
              printf '%s' "${SHA}" > "$(results.IMAGE_DIGEST.path)"
              printf '%s' "${IMAGE_REF}" > "$(results.IMAGE_REFERENCE.path)"
              printf '%s' "${GIT_COMMIT}" > "$(results.GIT_COMMIT.path)"
              echo "INTERNAL imagestream=packmate-backend tag=${CANDIDATE_TAG} digest=${SHA} ref=${IMAGE_REF}"

    - name: publish-candidate
      runAfter: [build-backend]
      workspaces:
        - name: source
          workspace: source
      params:
        - name: cli-image
          value: $(params.cli-image)
        - name: internal_reference
          value: $(tasks.build-backend.results.IMAGE_REFERENCE)
        - name: git_commit
          value: $(tasks.build-backend.results.GIT_COMMIT)
      taskSpec:
        params:
          - name: cli-image
          - name: internal_reference
          - name: git_commit
        workspaces:
          - name: source
        results:
          - name: INTERNAL_IMAGE_REFERENCE
          - name: PROMOTION_IMAGE_URL
          - name: PROMOTION_IMAGE_TAG
          - name: PROMOTION_IMAGE_DIGEST
          - name: PROMOTION_IMAGE_REFERENCE
          - name: PROMOTION_REGISTRY_MODE
          - name: PROMOTION_REGISTRY_VERIFIED
        steps:
          - name: publish
            image: quay.io/skopeo/stable@sha256:be15097a3e99a1fe72838b3d626d1c283db38626536fff5e04ab6bbb814baeca
            workingDir: $(workspaces.source.path)
            env:
              - name: NAMESPACE
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.namespace
              - name: POD_NAME
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.name
              - name: PACKMATE_PROMOTION_REGISTRY
                value: __PACKMATE_PROMOTION_REGISTRY__
              - name: PACKMATE_PROMOTION_REGISTRY_OWNER
                value: __PACKMATE_PROMOTION_REGISTRY_OWNER__
              - name: PACKMATE_PROMOTION_IMAGE_NAME
                value: __PACKMATE_PROMOTION_IMAGE_NAME__
              - name: PACKMATE_PROMOTION_REGISTRY_MODE
                value: external
              - name: PACKMATE_REQUIRE_PORTABLE_PROD_IMAGE
                value: "true"
            volumeMounts:
              - name: ghcr-push
                mountPath: /var/run/secrets/packmate-ghcr-push
                readOnly: true
            script: |
              #!/usr/bin/env bash
              set -euo pipefail
              INTERNAL="$(params.internal_reference)"
              GIT_COMMIT="$(params.git_commit)"
              GIT_SHORT="$(printf '%s' "${GIT_COMMIT}" | cut -c1-7)"
              PR_NAME="$(printf '%s' "${POD_NAME}" | sed -E 's/-publish-candidate.*//;s/-pod$//')"
              EXT_TAG="${GIT_SHORT}-${PR_NAME}"
              EXT_REPO="$(printf '%s/%s/%s' \
                "${PACKMATE_PROMOTION_REGISTRY}" \
                "$(printf '%s' "${PACKMATE_PROMOTION_REGISTRY_OWNER}" | tr '[:upper:]' '[:lower:]')" \
                "${PACKMATE_PROMOTION_IMAGE_NAME}")"
              AUTHFILE="$(mktemp)"
              cleanup() { rm -f "${AUTHFILE}"; }
              trap cleanup EXIT
              if [[ ! -f /var/run/secrets/packmate-ghcr-push/.dockerconfigjson ]]; then
                echo "ERROR: push Secret packmate-ghcr-push not mounted"
                echo "ACTION: make configure-promotion-registry"
                exit 1
              fi
              cp /var/run/secrets/packmate-ghcr-push/.dockerconfigjson "${AUTHFILE}"
              chmod 600 "${AUTHFILE}"
              # Authenticate to the internal OpenShift registry with the Pipeline SA token.
              SRC_TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
              SRC_CA="/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt"
              [[ -f "${SRC_CA}" ]] || SRC_CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
              echo "Copying ${INTERNAL} -> ${EXT_REPO}:${EXT_TAG}"
              skopeo copy \
                --src-creds "pipeline:${SRC_TOKEN}" \
                --src-cert-dir /var/run/secrets/kubernetes.io/serviceaccount \
                --dest-authfile "${AUTHFILE}" \
                --all \
                "docker://${INTERNAL}" "docker://${EXT_REPO}:${EXT_TAG}"
              unset SRC_TOKEN
              DIGEST="$(skopeo inspect --authfile "${AUTHFILE}" "docker://${EXT_REPO}:${EXT_TAG}" --format '{{.Digest}}')"
              [[ "${DIGEST}" == sha256:* ]] || { echo "Missing destination digest"; exit 1; }
              EXT_REF="${EXT_REPO}@${DIGEST}"
              skopeo inspect --authfile "${AUTHFILE}" "docker://${EXT_REF}" >/dev/null
              case "${EXT_REF}" in
                image-registry.openshift-image-registry.svc:*|*.svc:*|172.30.*)
                  echo "ERROR: promotion reference must be external"; exit 1 ;;
              esac
              printf '%s' "${INTERNAL}" > "$(results.INTERNAL_IMAGE_REFERENCE.path)"
              printf '%s' "${EXT_REPO}" > "$(results.PROMOTION_IMAGE_URL.path)"
              printf '%s' "${EXT_TAG}" > "$(results.PROMOTION_IMAGE_TAG.path)"
              printf '%s' "${DIGEST}" > "$(results.PROMOTION_IMAGE_DIGEST.path)"
              printf '%s' "${EXT_REF}" > "$(results.PROMOTION_IMAGE_REFERENCE.path)"
              printf '%s' "${PACKMATE_PROMOTION_REGISTRY_MODE}" > "$(results.PROMOTION_REGISTRY_MODE.path)"
              printf '%s' "true" > "$(results.PROMOTION_REGISTRY_VERIFIED.path)"
              echo "PROMOTION_IMAGE_REFERENCE=${EXT_REF}"
        volumes:
          - name: ghcr-push
            secret:
              secretName: packmate-ghcr-push
              optional: false

    - name: publish-result
      runAfter: [publish-candidate]
      params:
        - name: python-image
          value: $(params.python-image)
        - name: digest
          value: $(tasks.publish-candidate.results.PROMOTION_IMAGE_DIGEST)
        - name: image_url
          value: $(tasks.publish-candidate.results.PROMOTION_IMAGE_URL)
        - name: image_reference
          value: $(tasks.publish-candidate.results.PROMOTION_IMAGE_REFERENCE)
        - name: internal_reference
          value: $(tasks.publish-candidate.results.INTERNAL_IMAGE_REFERENCE)
        - name: git_commit
          value: $(tasks.build-backend.results.GIT_COMMIT)
        - name: score
          value: $(tasks.ai-quality-gate.results.score)
        - name: status
          value: $(tasks.ai-quality-gate.results.status)
        - name: scenarios
          value: $(tasks.ai-quality-gate.results.scenarios)
      taskSpec:
        params:
          - name: python-image
          - name: digest
          - name: image_url
          - name: image_reference
          - name: internal_reference
          - name: git_commit
          - name: score
          - name: status
          - name: scenarios
        results:
          - name: IMAGE_URL
          - name: IMAGE_DIGEST
          - name: IMAGE_REFERENCE
          - name: INTERNAL_IMAGE_REFERENCE
          - name: PROMOTION_IMAGE_REFERENCE
          - name: GIT_COMMIT
          - name: QUALITY_SCORE
          - name: QUALITY_RESULT
          - name: PIPELINERUN_NAME
        steps:
          - name: summary
            image: $(params.python-image)
            env:
              - name: POD_NAME
                valueFrom:
                  fieldRef:
                    fieldPath: metadata.name
            script: |
              #!/usr/bin/env bash
              set -euo pipefail
              PR_NAME="$(printf '%s' "${POD_NAME}" | sed -E 's/-publish-result.*//;s/-pod$//')"
              printf '%s' "$(params.image_url)" > "$(results.IMAGE_URL.path)"
              printf '%s' "$(params.digest)" > "$(results.IMAGE_DIGEST.path)"
              printf '%s' "$(params.image_reference)" > "$(results.IMAGE_REFERENCE.path)"
              printf '%s' "$(params.internal_reference)" > "$(results.INTERNAL_IMAGE_REFERENCE.path)"
              printf '%s' "$(params.image_reference)" > "$(results.PROMOTION_IMAGE_REFERENCE.path)"
              printf '%s' "$(params.git_commit)" > "$(results.GIT_COMMIT.path)"
              printf '%s' "$(params.score)" > "$(results.QUALITY_SCORE.path)"
              printf '%s' "$(params.status)" > "$(results.QUALITY_RESULT.path)"
              printf '%s' "${PR_NAME}" > "$(results.PIPELINERUN_NAME.path)"
              cat <<EOF
              ========== Packmate CI result ==========
              AI quality gate: $(params.status)
              Scenarios:       $(params.scenarios)
              Score:           $(params.score)
              Threshold:       0.90
              INTERNAL_IMAGE_REFERENCE: $(params.internal_reference)
              PROMOTION_IMAGE_REFERENCE: $(params.image_reference)
              GIT_COMMIT:      $(params.git_commit)
              PIPELINERUN:     ${PR_NAME}
              Promote (PROD):  scripts/promote-backend-image.sh --pipelinerun ${PR_NAME} --namespace packmate-lab --create-pr
              NOTE: CI never deploys to packmate-prod — Argo CD Sync only.
              ========================================
              EOF
