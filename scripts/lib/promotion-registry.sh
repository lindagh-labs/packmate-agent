#!/usr/bin/env bash
# Copy registry credentials between Packmate namespaces without printing or
# placing credential data on a command line.
# shellcheck shell=bash

packmate_copy_registry_secret() (
  set -euo pipefail
  local source_namespace="$1" source_name="$2" target_namespace="$3" target_name="$4"
  local temporary
  temporary="$(mktemp -d)"
  trap 'rm -rf "${temporary}"' EXIT
  chmod 700 "${temporary}"
  oc -n "${source_namespace}" get secret "${source_name}" \
    -o jsonpath='{.data.\.dockerconfigjson}' >"${temporary}/dockerconfig.b64"
  base64 -d <"${temporary}/dockerconfig.b64" >"${temporary}/.dockerconfigjson" 2>/dev/null
  chmod 600 "${temporary}/.dockerconfigjson"
  oc -n "${target_namespace}" create secret generic "${target_name}" \
      --type=kubernetes.io/dockerconfigjson \
      --from-file=".dockerconfigjson=${temporary}/.dockerconfigjson" \
      --dry-run=client -o yaml \
    | oc -n "${target_namespace}" apply -f - >/dev/null
)
