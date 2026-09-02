#!/bin/sh
# Fully offline Helm render of gitops/bootstrap, plus proof that it
# renders exactly the authorized shape: one AppProject, one
# ApplicationSet with exactly two generator elements, zero Secrets, no
# wildcard permissions, and correct revision propagation. Never touches
# the cluster. Backs `make gitops-render`. Accepts REVISION=<value>
# (default main) to prove propagation for a non-default revision too.
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
# shellcheck source=../../scripts/gitops/_lib.sh
. scripts/gitops/_lib.sh
require_helm

revision="${REVISION:-$GITOPS_DEFAULT_REVISION}"

echo "gitops-render: helm lint ..."
if ! "$HELM_BIN" lint gitops/bootstrap; then
  echo "FAIL: helm lint failed" >&2
  exit 1
fi
echo "OK: helm lint passed"

render_out="$(mktemp)"
cleanup() { rm -f "$render_out"; }
trap cleanup EXIT INT TERM

echo "gitops-render: rendering with gitRevision=${revision} ..."
if ! "$HELM_BIN" template gitops/bootstrap --set "gitRevision=${revision}" > "$render_out" 2>&1; then
  echo "FAIL: helm template failed" >&2
  cat "$render_out" >&2
  exit 1
fi

fail=0

appproject_count="$(grep -c '^kind: AppProject$' "$render_out" || true)"
if [ "$appproject_count" != "1" ]; then
  echo "FAIL: expected exactly 1 AppProject, found $appproject_count" >&2
  fail=1
else
  echo "OK: exactly 1 AppProject rendered"
fi

appset_count="$(grep -c '^kind: ApplicationSet$' "$render_out" || true)"
if [ "$appset_count" != "1" ]; then
  echo "FAIL: expected exactly 1 ApplicationSet, found $appset_count" >&2
  fail=1
else
  echo "OK: exactly 1 ApplicationSet rendered"
fi

secret_count="$(grep -c '^kind: Secret$' "$render_out" || true)"
if [ "$secret_count" != "0" ]; then
  echo "FAIL: expected 0 Secrets rendered, found $secret_count" >&2
  fail=1
else
  echo "OK: no Secret rendered"
fi

generator_elements="$(grep -c '^\s*- env: ' "$render_out" || true)"
if [ "$generator_elements" != "2" ]; then
  echo "FAIL: expected exactly 2 generator list elements, found $generator_elements" >&2
  fail=1
else
  echo "OK: exactly 2 generator elements (staging, production)"
fi

if grep -qE 'sourceRepos:\s*$' "$render_out" && grep -A1 'sourceRepos:' "$render_out" | grep -q '"\*"'; then
  echo "FAIL: wildcard sourceRepos detected" >&2
  fail=1
fi
if grep -qE 'namespace: "\*"|server: "\*"' "$render_out"; then
  echo "FAIL: wildcard destination detected" >&2
  fail=1
fi
if [ "$fail" -eq 0 ]; then
  echo "OK: no wildcard source/destination permissions found"
fi

if grep -q "targetRevision: ${revision}" "$render_out"; then
  echo "OK: revision '${revision}' propagated into the generated-Application template"
else
  echo "FAIL: revision '${revision}' not found in rendered targetRevision" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "gitops-render: FAILED"
  exit 1
fi
echo "gitops-render: OK"
