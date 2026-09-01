#!/bin/sh
# Fully offline Helm render of the pinned Argo CD chart against the pinned
# values file, plus proof that every rendered image uses an approved,
# digest-pinned reference and that dex/notifications are absent. Never
# touches the cluster, never downloads anything. Backs `make argocd-render`.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
# shellcheck source=../../scripts/lab/_lib.sh
. scripts/lab/_lib.sh
require_repo_root
# shellcheck source=../../scripts/argocd/_lib.sh
. scripts/argocd/_lib.sh
require_helm
require_argocd_chart

render_out="$(mktemp)"
cleanup() {
  rm -f "$render_out"
}
trap cleanup EXIT INT TERM

echo "argocd-render: rendering ${ARGOCD_CHART_TGZ} with ${ARGOCD_VALUES_FILE} ..."
if ! phelm template "$ARGOCD_RELEASE_NAME" "$ARGOCD_CHART_TGZ" \
      --namespace "$ARGOCD_NAMESPACE" -f "$ARGOCD_VALUES_FILE" \
      > "$render_out" 2>&1; then
  echo "FAIL: offline render failed" >&2
  cat "$render_out" >&2
  exit 1
fi
echo "OK: render succeeded"

approved_1="quay.io/argoproj/argocd:v3.5.2@sha256:e2aadfae709d904e87f46ba4aa49601d827b3022db22cd4d03aae816a2e7097b"
approved_2="ecr-public.aws.com/docker/library/redis:8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763"

image_lines="$(grep -E '^[[:space:]]*image:[[:space:]]' "$render_out" | sed -E 's/^[[:space:]]*image:[[:space:]]*//' | tr -d '"'"'"'' | sort -u)"
image_count="$(grep -cE '^[[:space:]]*image:[[:space:]]' "$render_out" || true)"

fail=0
while IFS= read -r img; do
  [ -z "$img" ] && continue
  if [ "$img" != "$approved_1" ] && [ "$img" != "$approved_2" ]; then
    echo "FAIL: unapproved image reference rendered: $img" >&2
    fail=1
  fi
done <<EOF
$image_lines
EOF

if grep -E '^[[:space:]]*image:[[:space:]]' "$render_out" | grep -v '@sha256:' >/dev/null 2>&1; then
  echo "FAIL: a tag-only (non-digest-pinned) image was rendered" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "argocd-render: FAILED"
  exit 1
fi

echo "OK: all $image_count rendered image occurrences use an approved, digest-pinned reference"
echo "    distinct images:"
printf '%s\n' "$image_lines" | sed 's/^/      /'

if grep -q 'app.kubernetes.io/name: argocd-dex-server' "$render_out"; then
  echo "FAIL: dex is present in the render but must be disabled" >&2
  exit 1
fi
if grep -q 'app.kubernetes.io/name: argocd-notifications-controller' "$render_out"; then
  echo "FAIL: notifications-controller is present in the render but must be disabled" >&2
  exit 1
fi
echo "OK: dex and notifications-controller are absent from the render"

echo "argocd-render: OK"
