#!/bin/sh
# Phase 5.1c-1: shared by scripts/promote/promote.sh and
# scripts/validate/check-promotion.sh. Reads the image an environment's
# overlays point at, and knows the promotion order.
PROMOTE_CHART_DIR="charts/standard-workload"
PROMOTE_LEDGER="gitops/promotions/smoke.tsv"
PROMOTE_ENVS="dev uat prod"

# promote_overlays <env>: the two overlays of one environment.
promote_overlays() { echo "$PROMOTE_CHART_DIR/values-$1.yaml $PROMOTE_CHART_DIR/values-$1-aws.yaml"; }

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
# image block, or nothing if the block is missing or incomplete.
overlay_image_ref() {
  awk '
    /^image:[[:space:]]*$/ { inimg = 1; next }
    inimg && /^[^[:space:]#]/ { inimg = 0 }
    inimg && /^  repository:/ { r = $2 }
    inimg && /^  digest:/ { d = $2; gsub(/"/, "", d) }
    END { if (r != "" && d != "") print r "@" d }
  ' "$1"
}
