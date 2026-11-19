#!/bin/sh
# Phase 5.1c-1: shared by scripts/promote/promote.sh,
# scripts/promote/verify-overlays.sh and scripts/validate/check-promotion.sh.
# Reads the image an environment's overlays point at, and knows the
# promotion order.
#
# Phase 6.3c (ADR-0023): one promotion flow per first-party app, each with
# its own overlays, ledger and image repository. promote_use_app <app>
# selects one; smoke stays the default so existing callers keep working.
#   - smoke: charts/standard-workload/values-<env>.yaml and -aws.yaml
#     (local and aws must agree), ledger gitops/promotions/smoke.tsv;
#   - notes: charts/standard-workload/values-notes-<env>.yaml only (notes
#     is lab-only until 6.4), ledger gitops/promotions/notes.tsv. An
#     environment without that overlay does not run notes yet.
PROMOTE_CHART_DIR="charts/standard-workload"
PROMOTE_ENVS="dev uat prod"
PROMOTE_APPS="smoke notes"

# promote_use_app <app>: sets PROMOTE_APP, PROMOTE_LEDGER and IMAGE_REPO
# (read from scripts/image/image.sh, the one place the repository is
# named). Unknown app -> non-zero.
promote_use_app() {
  case "$1" in smoke|notes) : ;; *) return 1 ;; esac
  PROMOTE_APP="$1"
  PROMOTE_LEDGER="gitops/promotions/$1.tsv"
  IMAGE_REPO="$(sed -n 's/^IMAGE_REPO="\(.*\)"$/\1/p' scripts/image/image.sh | sed "s/\\\$IMAGE_APP\$/$1/")"
  [ -n "$IMAGE_REPO" ] && [ "${IMAGE_REPO#*\$}" = "$IMAGE_REPO" ]
}

# promote_overlays <env>: the overlays of one environment for the current
# app (one or two paths).
promote_overlays() {
  case "${PROMOTE_APP:-smoke}" in
    smoke) echo "$PROMOTE_CHART_DIR/values-$1.yaml $PROMOTE_CHART_DIR/values-$1-aws.yaml" ;;
    *) echo "$PROMOTE_CHART_DIR/values-${PROMOTE_APP}-$1.yaml" ;;
  esac
}

# promote_source_env <env>: where <env> may be promoted from.
promote_source_env() {
  case "$1" in
    dev) echo main ;;
    uat) echo dev ;;
    prod) echo uat ;;
    *) return 1 ;;
  esac
}

# overlay_image_ref <file>: "repository@digest" from the file's top-level
# image block, or nothing if the file or block is missing or incomplete.
overlay_image_ref() {
  [ -f "$1" ] || return 0
  awk '
    /^image:[[:space:]]*$/ { inimg = 1; next }
    inimg && /^[^[:space:]#]/ { inimg = 0 }
    inimg && /^  repository:/ { r = $2 }
    inimg && /^  digest:/ { d = $2; gsub(/"/, "", d) }
    END { if (r != "" && d != "") print r "@" d }
  ' "$1"
}

# overlays_ref <env>: the one reference every overlay of <env> holds, or
# "MISMATCH" if they disagree, or nothing if none exists (notes only).
overlays_ref() {
  ref=""; first=1
  for f in $(promote_overlays "$1"); do
    r="$(overlay_image_ref "$f")"
    if [ "$first" = 1 ]; then ref="$r"; first=0
    elif [ "$r" != "$ref" ]; then echo MISMATCH; return 0; fi
  done
  echo "$ref"
}
