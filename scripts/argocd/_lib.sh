#!/bin/sh
# Shared constants and helpers for lab/argocd/*.sh and tests/argocd/*.sh.
# POSIX-compatible shell only - no bashisms. Sourced, never executed
# directly. Assumes the caller's working directory is the repository
# root, and that scripts/lab/_lib.sh (project cluster/kubeconfig
# constants, pkubectl) has already been sourced first.

ARGOCD_NAMESPACE="argocd"
ARGOCD_RELEASE_NAME="argocd"
ARGOCD_CHART_VERSION="10.4.2"
ARGOCD_CHART_APP_VERSION="v3.5.2"
ARGOCD_CHART_URL="https://github.com/argoproj/argo-helm/releases/download/argo-cd-10.4.2/argo-cd-10.4.2.tgz"
ARGOCD_CHART_SHA256="715d2dde423b4a550af9d8b619a02dabfb32421e6a18346c8a40211c3b63663d"
ARGOCD_CHART_TGZ=".tools/charts/argo-cd-10.4.2.tgz"
ARGOCD_VALUES_FILE="lab/argocd/values-lab.yaml"
ARGOCD_NS_OWNER_LABEL_KEY="eks-gitops-lab-lite.local/owner"
ARGOCD_NS_OWNER_LABEL_VALUE="argocd-bootstrap"
HELM_BIN=".tools/bin/helm"

require_argocd_chart() {
  if [ ! -f "$ARGOCD_CHART_TGZ" ]; then
    echo "FAIL: $ARGOCD_CHART_TGZ not found - run 'make argocd-chart-fetch' first" >&2
    exit 1
  fi
  actual_sha="$(shasum -a 256 "$ARGOCD_CHART_TGZ" | awk '{print $1}')"
  if [ "$actual_sha" != "$ARGOCD_CHART_SHA256" ]; then
    echo "FAIL: $ARGOCD_CHART_TGZ does not match the pinned checksum - run 'make argocd-chart-fetch' again" >&2
    exit 1
  fi
}

# require_helm/phelm: shared with scripts/eso/_lib.sh (Phase 3.2.1
# consolidation - the two were byte-identical). HELM_BIN above must stay
# set before this source line.
# shellcheck source=../lib/helm.sh
. scripts/lib/helm.sh

argocd_release_exists() {
  phelm list -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null | grep -q "\"name\":\"${ARGOCD_RELEASE_NAME}\""
}

argocd_values_fingerprint() {
  shasum -a 256 "$ARGOCD_VALUES_FILE" | awk '{print $1}'
}

# Preflight identity comparison. Sets ARGOCD_INSTALL_CASE to one of:
#   absent | match | chart_drift | values_drift | manifest_drift | bad_status
# Returns 0 only for "match".
check_argocd_install_identity() {
  ARGOCD_INSTALL_CASE=""

  if ! argocd_release_exists; then
    ARGOCD_INSTALL_CASE="absent"
    return 1
  fi

  list_json="$(phelm list -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)"
  chart_string="$(printf '%s' "$list_json" | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p')"
  app_version="$(printf '%s' "$list_json" | sed -n 's/.*"app_version":"\([^"]*\)".*/\1/p')"

  expected_chart="argo-cd-${ARGOCD_CHART_VERSION}"
  if [ "$chart_string" != "$expected_chart" ] || [ "$app_version" != "$ARGOCD_CHART_APP_VERSION" ]; then
    ARGOCD_INSTALL_CASE="chart_drift"
    return 1
  fi

  # helm status's "notes" field embeds the chart's full NOTES.txt, which
  # itself contains dozens of unrelated "status"/"description"-looking
  # substrings (CRD schema text, sample commands) - a naive greedy sed
  # match against the whole payload picks up the LAST such occurrence,
  # not the real one. "notes" is always the last field of the Info
  # struct (after first_deployed/last_deployed/deleted/description/
  # status - see pkg/release/v1/info.go), so truncating the payload at
  # its start keeps exactly one real "status" and "description" and
  # nothing else that could collide.
  status_json="$(phelm status "$ARGOCD_RELEASE_NAME" -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)"
  status_prefix="$(printf '%s' "$status_json" | sed 's/,"notes":.*//')"
  rel_status="$(printf '%s' "$status_prefix" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
  if [ "$rel_status" != "deployed" ]; then
    ARGOCD_INSTALL_CASE="bad_status"
    return 1
  fi

  description="$(printf '%s' "$status_prefix" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')"
  expected_description="values-sha256:$(argocd_values_fingerprint)"
  if [ "$description" != "$expected_description" ]; then
    ARGOCD_INSTALL_CASE="values_drift"
    return 1
  fi

  if ! compare_desired_vs_live_manifest; then
    ARGOCD_INSTALL_CASE="manifest_drift"
    return 1
  fi

  ARGOCD_INSTALL_CASE="match"
  return 0
}

# Compares the offline-rendered desired manifest against the live
# release's tracked manifest. Returns 0 on match, 1 on drift, 2 on any
# render/read/comparison error (fail closed - never silently proceeds).
compare_desired_vs_live_manifest() {
  desired_raw="$(mktemp)" || return 2
  desired_norm="$(mktemp)" || { rm -f "$desired_raw"; return 2; }
  live_raw="$(mktemp)" || { rm -f "$desired_raw" "$desired_norm"; return 2; }
  live_norm="$(mktemp)" || { rm -f "$desired_raw" "$desired_norm" "$live_raw"; return 2; }

  if ! phelm template "$ARGOCD_RELEASE_NAME" "$ARGOCD_CHART_TGZ" \
        --namespace "$ARGOCD_NAMESPACE" -f "$ARGOCD_VALUES_FILE" --no-hooks \
        > "$desired_raw" 2>&1; then
    echo "FAIL: could not render the desired manifest offline" >&2
    rm -f "$desired_raw" "$desired_norm" "$live_raw" "$live_norm"
    return 2
  fi

  if ! phelm get manifest "$ARGOCD_RELEASE_NAME" -n "$ARGOCD_NAMESPACE" \
        > "$live_raw" 2>&1; then
    echo "FAIL: could not read the live release manifest" >&2
    rm -f "$desired_raw" "$desired_norm" "$live_raw" "$live_norm"
    return 2
  fi

  sed -e 's/[[:space:]]*$//' "$desired_raw" > "${desired_norm}.tmp" \
    && printf '%s\n' "$(cat "${desired_norm}.tmp")" > "$desired_norm" \
    && rm -f "${desired_norm}.tmp"
  sed -e 's/[[:space:]]*$//' "$live_raw" > "${live_norm}.tmp" \
    && printf '%s\n' "$(cat "${live_norm}.tmp")" > "$live_norm" \
    && rm -f "${live_norm}.tmp"

  desired_sha="$(shasum -a 256 "$desired_norm" | awk '{print $1}')"
  live_sha="$(shasum -a 256 "$live_norm" | awk '{print $1}')"
  rm -f "$desired_raw" "$desired_norm" "$live_raw" "$live_norm"

  if [ "$desired_sha" = "$live_sha" ]; then
    echo "OK: manifest match (sha256 $desired_sha)"
    return 0
  else
    echo "FAIL: manifest drift - desired sha256 $desired_sha != live sha256 $live_sha" >&2
    return 1
  fi
}

# Full structural CRD compatibility check via kubectl diff (covers
# group/names/scope/versions/schemas/subresources/conversion/printer
# columns - a full-object diff, not a single-field comparison).
# Returns 0 exact match, 1 semantic difference, 2 command/auth error.
check_crd_compatibility() {
  crd_tmp="$(mktemp)" || return 2

  if ! phelm template "$ARGOCD_RELEASE_NAME" "$ARGOCD_CHART_TGZ" \
        --namespace "$ARGOCD_NAMESPACE" -f "$ARGOCD_VALUES_FILE" \
        --show-only templates/crds/crd-application.yaml \
        --show-only templates/crds/crd-applicationset.yaml \
        --show-only templates/crds/crd-appproject.yaml \
        > "$crd_tmp" 2>&1; then
    echo "FAIL: could not render the pinned CRDs offline" >&2
    rm -f "$crd_tmp"
    return 2
  fi

  diff_out="$(mktemp)" || { rm -f "$crd_tmp"; return 2; }
  pkubectl diff -f "$crd_tmp" >"$diff_out" 2>&1
  rc=$?
  case "$rc" in
    0) echo "OK: retained CRDs exactly match the pinned chart"; rc_final=0 ;;
    1) echo "FAIL: CRD drift detected:"; cat "$diff_out" >&2; rc_final=1 ;;
    *) echo "FAIL: kubectl diff command/authorization error (exit $rc)" >&2; rc_final=2 ;;
  esac
  rm -f "$crd_tmp" "$diff_out"
  return "$rc_final"
}

# Sets CRD_STATE to absent|retained|partial. Returns 1 on partial.
detect_crd_state() {
  present=0
  for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
    if pkubectl get crd "$crd" >/dev/null 2>&1; then
      present=$((present + 1))
    fi
  done
  case "$present" in
    0) CRD_STATE="absent" ;;
    3) CRD_STATE="retained" ;;
    *) CRD_STATE="partial"; return 1 ;;
  esac
  return 0
}

check_no_unexpected_argoproj_crds() {
  unexpected="$(pkubectl get crd -o name 2>/dev/null | grep '\.argoproj\.io$' \
    | grep -vE '^customresourcedefinition\.apiextensions\.k8s\.io/(applications|applicationsets|appprojects)\.argoproj\.io$' || true)"
  if [ -n "$unexpected" ]; then
    echo "FAIL: unexpected argoproj.io CRD(s) present:" >&2
    printf '%s\n' "$unexpected" >&2
    return 1
  fi
  return 0
}

# Exhaustive namespaced-resource discovery, shared by
# inventory_namespace_contents() below and by
# scripts/gitops/_lib.sh's classifier (Phase 2.6.3a). Appends one
# "<resourcetype-with-group>/<name>" line per discovered object to
# $2 (created if absent). Every listable namespaced API type (including
# CRD-defined ones) is queried - never just `kubectl get all`. Returns
# 0 on success, 2 on any discovery/query error (fail closed).
list_namespace_resource_names() {
  ns="$1"; out_file="$2"
  apires_tmp="$(mktemp)" || return 2
  if ! pkubectl api-resources --verbs=list --namespaced -o name >"$apires_tmp" 2>&1; then
    echo "FAIL: could not discover namespaced API resource types" >&2
    cat "$apires_tmp" >&2
    rm -f "$apires_tmp"
    return 2
  fi

  : > "$out_file"
  while IFS= read -r restype; do
    [ -z "$restype" ] && continue
    if ! pkubectl -n "$ns" get "$restype" -o name >>"$out_file" 2>/tmp/.nsinv-err.$$; then
      echo "FAIL: query failed for resource type '$restype' in namespace '$ns'" >&2
      cat /tmp/.nsinv-err.$$ >&2
      rm -f "$apires_tmp" /tmp/.nsinv-err.$$
      return 2
    fi
    rm -f /tmp/.nsinv-err.$$
  done < "$apires_tmp"
  rm -f "$apires_tmp"
  return 0
}

# Exhaustive namespaced-resource inventory - every listable namespaced
# API type (including CRD-defined ones), not just `kubectl get all`.
# Returns 0 if only the Kubernetes-auto-created allowlist remains.
inventory_namespace_contents() {
  ns="$1"
  nsinv_tmp="$(mktemp)" || return 2
  if ! list_namespace_resource_names "$ns" "$nsinv_tmp"; then
    rm -f "$nsinv_tmp"
    return 2
  fi

  # Allowlist: the two objects Kubernetes itself auto-creates in every
  # namespace, plus Event objects - Kubernetes generates these
  # continuously for any namespace that ever ran a real Pod (scheduling,
  # image pulls, probes, ...) regardless of what Helm/Argo CD did or
  # didn't clean up, and they expire on their own (~1h TTL by default).
  # `kubectl api-resources` lists both the legacy core "events" type and
  # "events.events.k8s.io" for the same underlying objects, so `-o name`
  # can print either "event/..." or "event.events.k8s.io/..." - match
  # both. Gating deletion on their absence would make a namespace that
  # ever had real workload activity effectively never deletable.
  # Additional allowlist entries specific to this Argo CD release: three
  # objects Argo CD creates imperatively at its own runtime, never
  # templated or tracked by the Helm chart, so `helm uninstall` cannot
  # remove them -
  #   secret/argocd-redis          - written by the redis-secret-init
  #                                   hook Job's own `argocd admin
  #                                   redis-initial-password` command.
  #   secret/argocd-initial-admin-secret - generated by the
  #                                   application-controller on first
  #                                   startup. Deliberately NEVER
  #                                   deleted by this script (or any
  #                                   other automated target) - only a
  #                                   human, after verifying a
  #                                   replacement auth method works, per
  #                                   README.md. It is only ever removed
  #                                   as an incidental side effect of
  #                                   deleting the whole namespace below,
  #                                   never by a targeted delete here.
  #   appproject.argoproj.io/default - the default AppProject, created
  #                                   by the application-controller on
  #                                   first startup (no template for it
  #                                   exists anywhere in the chart).
  # All three are recognized, expected content of a healthy Argo CD
  # install, not foreign/unexpected content - the deletion this
  # function gates is namespace deletion, which removes them anyway.
  unexpected_tmp="$(mktemp)" || { rm -f "$nsinv_tmp"; return 2; }
  grep -vE '^(serviceaccount/default|configmap/kube-root-ca\.crt|secret/argocd-redis|secret/argocd-initial-admin-secret|appproject\.argoproj\.io/default)$|^event(\.events\.k8s\.io)?/' "$nsinv_tmp" > "$unexpected_tmp"
  count="$(wc -l < "$unexpected_tmp" | tr -d ' ')"
  if [ "$count" -gt 0 ]; then
    echo "FAIL: $count unexpected object(s) remain in namespace '$ns':" >&2
    cat "$unexpected_tmp" >&2
    rm -f "$nsinv_tmp" "$unexpected_tmp"
    return 1
  fi
  rm -f "$nsinv_tmp" "$unexpected_tmp"
  return 0
}
