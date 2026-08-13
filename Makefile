# Packmate v2 lab Makefile — OpenShift AI DEV → CI → PR → Argo CD PROD

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SHELL := /bin/bash

.PHONY: help configure-participant preflight bootstrap verify verify-dev verify-prod verify-gitops \
	prepare-prod configure-argocd-rbac cleanup test render promote validate-prod \
	verify-python-deps resolve-pipeline-python-image render-pipeline validate-pipeline \
	configure-git setup-workbench-repository security-check \
	check-gitops-prerequisites install-gitops-operator wait-for-gitops instructor-setup \
	configure-promotion-registry verify-promotion-registry \
	verify-resource-ownership rotate-prod-llm-secret verify-demo-fork \
	verify-demo-fork-live verify-github-write-readiness verify-demo-baseline \
	prepare-demo-baseline discover-packmate-resources \
	reset-lab acceptance-static acceptance-prebootstrap acceptance-postbootstrap \
	diagnose-latest-pipelinerun guide validate-guide

help:
	@echo "Packmate lab targets:"
	@echo "  make setup-workbench-repository  Safe clone/update into packmate-agent/"
	@echo "  make configure-participant  Configure fork, branch, GHCR owner, and upstream safety"
	@echo "  make configure-git          Repository-local Git user.name / user.email"
	@echo "  make preflight              Cluster, repo, mirror, and image checks"
	@echo "  make bootstrap              Prerequisites + Argo CD DEV reconcile + PROD prep"
	@echo "  make instructor-setup       Instructor: GitOps + SSO/RBAC + both Applications"
	@echo "  make check-gitops-prerequisites  Verify Red Hat OpenShift GitOps readiness"
	@echo "  make install-gitops-operator     Instructor-only Operator install"
	@echo "  make wait-for-gitops        Wait until GitOps check passes"
	@echo "  make configure-promotion-registry  Safely prompt for GHCR access (never stores tokens in Git)"
	@echo "  make verify-promotion-registry     Verify promotion registry config"
	@echo "  make verify-resource-ownership     Fail on DEV/PROD dual ownership"
	@echo "  make rotate-prod-llm-secret Instructor-only Secret rotation"
	@echo "  make prepare-prod           Create packmate-prod + Secret + Argo (no workload apply)"
	@echo "  make configure-argocd-rbac  SSO group + AppProject participant role"
	@echo "  make verify / verify-dev    DEV readiness (compat)"
	@echo "  make verify-prod            PROD readiness after Argo Sync"
	@echo "  make diagnose-latest-pipelinerun  Inspect latest PipelineRun Pending/FailedMount causes"
	@echo "  make verify-demo-fork       Pre-bootstrap fork remotes/config (Argo INFO only)"
	@echo "  make verify-demo-fork-live  Post-bootstrap: Applications must follow the fork"
	@echo "  make verify-github-write-readiness  GitHub read vs write readiness"
	@echo "  make verify-demo-baseline   Read-only: PROD digest vs Pipeline candidate"
	@echo "  make prepare-demo-baseline  Prepare disposable fork branch and save matching config"
	@echo "  make discover-packmate-resources  Read-only residue discovery"
	@echo "  make reset-lab              Dry-run Packmate reset (needs CONFIRM_… to delete)"
	@echo "  make acceptance-static      Offline clean-room acceptance"
	@echo "  make verify-gitops          AppProject/Applications/RBAC + live fork checks"
	@echo "  make validate-prod          Static PROD overlay checks"
	@echo "  make verify-python-deps     RHOAI mirror dependency compatibility (in-cluster)"
	@echo "  make resolve-pipeline-python-image  Resolve openshift/python:3.12-ubi9 digest"
	@echo "  make render-pipeline        Render packmate-ci from template"
	@echo "  make validate-pipeline      Validate rendered Pipeline YAML"
	@echo "  make cleanup                Interactive packmate-lab cleanup"
	@echo "  make test                   Unit tests + quality gate + security-check"
	@echo "  make render                 Render Kustomize DEV + PROD overlays"
	@echo "  make promote                Promote backend digest (see script --help)"
	@echo "  make guide                  Generate participant HTML, DOCX, and PDF"
	@echo "  make validate-guide         Validate guide structure and generated outputs"

setup-workbench-repository:
	@bash "$(ROOT)/scripts/setup-workbench-repository.sh"

configure-participant:
	@bash "$(ROOT)/scripts/configure-participant.sh"

configure-git:
	@bash "$(ROOT)/scripts/configure-git-identity.sh"

preflight:
	@bash "$(ROOT)/scripts/preflight-sandbox.sh"

bootstrap:
	@bash "$(ROOT)/scripts/bootstrap-sandbox.sh"

prepare-prod:
	@bash "$(ROOT)/scripts/prepare-prod.sh"

configure-argocd-rbac:
	@bash "$(ROOT)/scripts/configure-argocd-lab-rbac.sh"

verify verify-dev:
	@bash "$(ROOT)/scripts/verify-sandbox.sh"

verify-prod:
	@bash "$(ROOT)/scripts/verify-prod.sh"

verify-demo-fork:
	@bash "$(ROOT)/scripts/verify-demo-fork.sh"

verify-demo-fork-live:
	@bash "$(ROOT)/scripts/verify-demo-fork-live.sh"

verify-github-write-readiness:
	@bash "$(ROOT)/scripts/verify-github-write-readiness.sh"

verify-demo-baseline:
	@bash "$(ROOT)/scripts/verify-demo-baseline.sh" $(if $(PIPELINERUN),--pipelinerun "$(PIPELINERUN)",)

prepare-demo-baseline:
	@bash "$(ROOT)/scripts/prepare-demo-baseline.sh"

discover-packmate-resources:
	@bash "$(ROOT)/scripts/discover-packmate-resources.sh"

reset-lab:
	@bash "$(ROOT)/scripts/reset-packmate-lab.sh"

acceptance-static:
	@bash "$(ROOT)/scripts/acceptance/acceptance-static.sh"

acceptance-prebootstrap:
	@bash "$(ROOT)/scripts/acceptance/acceptance-prebootstrap.sh"

acceptance-postbootstrap:
	@bash "$(ROOT)/scripts/acceptance/acceptance-postbootstrap.sh"

diagnose-latest-pipelinerun:
	@bash "$(ROOT)/scripts/diagnose-latest-pipelinerun.sh"

verify-gitops:
	@bash "$(ROOT)/scripts/verify-gitops.sh"
	@bash "$(ROOT)/scripts/verify-demo-fork-live.sh"

validate-prod:
	@bash "$(ROOT)/scripts/validate-prod-overlay.sh"

verify-python-deps:
	@bash "$(ROOT)/scripts/check-rhoai-python-dependencies.sh"

resolve-pipeline-python-image:
	@bash "$(ROOT)/scripts/resolve-pipeline-python-image.sh"

render-pipeline:
	@bash "$(ROOT)/scripts/render-packmate-pipeline.sh"

validate-pipeline:
	@bash "$(ROOT)/scripts/validate-packmate-pipeline.sh"

cleanup:
	@bash "$(ROOT)/scripts/cleanup-packmate-lab.sh"

test:
	@set -euo pipefail; \
	  INDEX_URL="$${RHOAI_PYPI_INDEX_URL:-https://console.redhat.com/api/pypi/public-rhai/rhoai/3.4/cpu-ubi9/simple}"; \
	  cd "$(ROOT)/backend" && (test -x .venv/bin/pytest || python3.12 -m venv .venv); \
	  .venv/bin/pip -q install -U pip --index-url "$${INDEX_URL}"; \
	  .venv/bin/pip -q install -r requirements-dev.txt --index-url "$${INDEX_URL}"; \
	  .venv/bin/pytest -q; \
	  cd "$(ROOT)/frontend" && npm ci --silent && npm run lint && npm run test -- --run && npm run build; \
	  cd "$(ROOT)/mcp-servers/weather" && (test -x .venv/bin/pytest || python3.12 -m venv .venv); \
	  .venv/bin/pip -q install -r requirements-dev.txt --index-url "$${INDEX_URL}"; \
	  .venv/bin/pytest -q; \
	  cd "$(ROOT)/mcp-servers/baggage-policy" && (test -x .venv/bin/pytest || python3.12 -m venv .venv); \
	  .venv/bin/pip -q install -r requirements-dev.txt --index-url "$${INDEX_URL}"; \
	  .venv/bin/pytest -q; \
	  bash "$(ROOT)/evaluations/scripts/run_deterministic_gate.sh"; \
	  bash "$(ROOT)/scripts/security-check.sh"; \
	  bash "$(ROOT)/scripts/tests/test-pipeline-portability.sh"; \
	  bash "$(ROOT)/scripts/tests/test-workbench-repository-setup.sh"; \
	  bash "$(ROOT)/scripts/tests/test-participant-configuration.sh"; \
	bash "$(ROOT)/scripts/tests/test-gitops-portable-prod.sh"; \
	bash "$(ROOT)/scripts/tests/test-bootstrap-ownership-secrets.sh"; \
	bash "$(ROOT)/scripts/tests/test-kustomize-replicas-recovery.sh"; \
	bash "$(ROOT)/scripts/tests/test-fork-first-workshop.sh"; \
	bash "$(ROOT)/scripts/tests/test-deep-audit-hardening.sh"; \
	bash "$(ROOT)/scripts/tests/test-repeatable-demo-baseline.sh"

render:
	@bash "$(ROOT)/scripts/render-manifests.sh"

promote:
	@test -n "$(PIPELINERUN)" || { echo "ERROR: PipelineRun name required"; echo "ACTION: make promote PIPELINERUN=<pipelinerun-name>"; exit 1; }
	@bash "$(ROOT)/scripts/promote-backend-image.sh" --pipelinerun "$(PIPELINERUN)" --create-pr

security-check:
	@bash "$(ROOT)/scripts/security-check.sh"

check-gitops-prerequisites:
	@bash "$(ROOT)/scripts/check-openshift-gitops.sh"

install-gitops-operator:
	@INSTALL_OPENSHIFT_GITOPS_OPERATOR=true bash "$(ROOT)/scripts/install-openshift-gitops-operator.sh"

wait-for-gitops:
	@bash -c 'for i in $$(seq 1 90); do bash "$(ROOT)/scripts/check-openshift-gitops.sh" && exit 0; sleep 10; done; echo "Timed out waiting for GitOps"; exit 1'

instructor-setup:
	@bash "$(ROOT)/scripts/instructor-setup.sh"

configure-promotion-registry:
	@bash "$(ROOT)/scripts/configure-promotion-registry.sh"

verify-promotion-registry:
	@bash "$(ROOT)/scripts/verify-promotion-registry.sh"

verify-resource-ownership:
	@bash "$(ROOT)/scripts/check-resource-ownership.sh"

rotate-prod-llm-secret:
	@ROTATE_PACKMATE_PROD_LLM_SECRET=true bash "$(ROOT)/scripts/rotate-prod-llm-secret.sh"

guide:
	@bash "$(ROOT)/scripts/generate-participant-guide.sh"

validate-guide:
	@bash "$(ROOT)/scripts/validate-participant-guide.sh"
