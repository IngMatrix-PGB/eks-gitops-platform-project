#!/bin/sh
# Uninstalls only the two scoped controller releases (production, then
# staging - a fixed, deterministic order), and their operator
# namespaces if left clean. Deliberately NEVER touches the 25 CRDs -
# they are owned by no Helm release (see lab/eso/install.sh) and are
# only ever removed by a separate, explicit, destructive step that
# does not exist yet in this phase (Phase 2.6.1 scope is bootstrap
# only). Idempotent: absent releases/namespaces are a no-op. Backs
# `make eso-uninstall`.
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

# production first, staging second (fixed, documented order) - reverse
# of install, matching this project's established sync-wave-style
# "delete in reverse of create" discipline.
for env_name in production staging; do
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
    owner_label="$(pkubectl get namespace "$ns" -o jsonpath="{.metadata.labels.${ESO_NS_OWNER_LABEL_KEY}}" 2>/dev/null || true)"
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
