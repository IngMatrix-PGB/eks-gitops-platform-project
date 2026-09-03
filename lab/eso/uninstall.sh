#!/bin/sh
# Uninstalls the two scoped controller releases and their operator
# namespaces if left clean. Deliberately NEVER touches the 25 CRDs -
# they are owned by no Helm release (see lab/eso/install.sh) and are
# only ever removed by a separate, explicit, destructive step that
# does not exist yet in this phase (Phase 2.6.1 scope is bootstrap
# only). Idempotent: absent releases/namespaces are a no-op.
#
# Usage:
#   sh lab/eso/uninstall.sh              # both, in order: production then staging
#   sh lab/eso/uninstall.sh production   # production only - always safe
#   sh lab/eso/uninstall.sh staging      # staging only - REFUSED while
#                                        # production still exists (see
#                                        # the singleton-dependency guard
#                                        # below)
#
# eso-staging is the fixed owner of the cluster-wide webhook/cert-
# controller singletons (scripts/eso/_lib.sh). eso-production has no
# webhook or cert-controller of its own and depends on eso-staging's
# for ExternalSecret/SecretStore admission validation and CA
# management. Removing eso-staging while eso-production still exists
# would silently break admission control for BOTH environments -
# production would keep running with no visible symptom until the next
# ExternalSecret/SecretStore create or update, which would then hang or
# fail validation. This is why production must always be uninstalled
# first when removing both, and why removing staging alone is refused
# outright while production still exists. Backs `make eso-uninstall`
# (optionally `ENV=staging|production`).
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/eso/_lib.sh
. scripts/eso/_lib.sh
require_helm

if ! check_cluster_identity; then
  echo "FAIL: project cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2
  exit 1
fi

target="${1:-}"
case "$target" in
  ""|production|staging) : ;;
  *)
    echo "FAIL: unrecognized target '$target' - expected no argument, 'staging', or 'production'" >&2
    exit 1
    ;;
esac

if [ "$target" = "$ESO_SINGLETON_OWNER_ENV" ]; then
  if eso_release_exists "$ESO_DEPENDENT_NS" "$ESO_DEPENDENT_RELEASE"; then
    echo "FAIL: refusing to uninstall '$ESO_SINGLETON_OWNER_RELEASE' - it owns the cluster-wide webhook/cert-controller that '$ESO_DEPENDENT_RELEASE' depends on for admission validation, and '$ESO_DEPENDENT_RELEASE' still exists. Uninstall '$ESO_DEPENDENT_RELEASE' first (sh lab/eso/uninstall.sh $ESO_DEPENDENT_ENV), or uninstall both together with no argument." >&2
    exit 1
  fi
fi

if [ -z "$target" ]; then
  envs="production staging"
else
  envs="$target"
fi

# production first, staging second when uninstalling both (fixed,
# documented order) - reverse of install, matching this project's
# established sync-wave-style "delete in reverse of create" discipline;
# also exactly satisfies the singleton dependency above without a
# special case, since staging (the dependency) is never touched before
# production (the dependent) is already gone.
for env_name in $envs; do
  ns=""
  release=""
  while IFS='|' read -r e n r wc cc; do
    [ "$e" = "$env_name" ] || continue
    ns="$n"; release="$r"
  done <<EOF
$(eso_environments)
EOF

  if eso_release_exists "$ns" "$release"; then
    echo "eso-uninstall: uninstalling release '$release' from namespace '$ns' ..."
    phelm uninstall "$release" -n "$ns" --wait --timeout 5m
    echo "OK: release '$release' uninstalled"
  else
    echo "OK: release '$release' already absent in namespace '$ns' - no-op"
  fi

  if pkubectl get namespace "$ns" >/dev/null 2>&1; then
    # Bracket-notation jsonpath with every "." in the key backslash-
    # escaped: the label key itself contains a literal "."
    # (eks-gitops-lab-lite.local/owner). Verified empirically that BOTH
    # dotted field access (.metadata.labels.<key>) AND unescaped
    # bracket notation (.metadata.labels['<key>']) silently return
    # empty for this key - kubectl's jsonpath parser treats an
    # unescaped "." as a path separator even inside brackets. Only the
    # backslash-escaped bracket form (.metadata.labels['eks\.gitops...'])
    # actually resolves the field.
    escaped_owner_key="$(printf '%s' "$ESO_NS_OWNER_LABEL_KEY" | sed 's/\./\\./g')"
    owner_label="$(pkubectl get namespace "$ns" -o jsonpath="{.metadata.labels['${escaped_owner_key}']}" 2>/dev/null || true)"
    if [ "$owner_label" != "$ESO_NS_OWNER_LABEL_VALUE" ]; then
      echo "eso-uninstall: namespace '$ns' is not owned by this bootstrap (label mismatch) - leaving it in place" >&2
      continue
    fi
    remaining="$(pkubectl get all -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$remaining" -eq 0 ]; then
      pkubectl delete namespace "$ns" --wait --timeout=60s
      echo "OK: namespace '$ns' was clean and has been deleted"
    else
      echo "eso-uninstall: namespace '$ns' still has $remaining object(s) - leaving it in place for inspection" >&2
    fi
  else
    echo "OK: namespace '$ns' already absent - no-op"
  fi
done

echo "eso-uninstall: OK (CRDs untouched by design - see file header)"
