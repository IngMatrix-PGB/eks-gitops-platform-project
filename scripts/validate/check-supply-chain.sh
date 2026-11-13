#!/usr/bin/env bash
# Phase 5.1a: offline guard of the image supply chain's static rules.
# Part of `make validate`. Checks:
#   1. every `uses:` in .github/workflows is a GitHub-owned action
#      (actions/* or github/*) pinned to a 40-hex commit SHA;
#   2. no workflow uses pull_request_target; write permissions exist only
#      on the publish job of image.yml (Phase 5.1b): exactly packages,
#      id-token and attestations, behind
#      `if: github.event_name == 'push' && github.ref == 'refs/heads/main'`
#      and `needs: build-scan-sbom`; never at workflow level;
#   3. every Dockerfile FROM under apps/ is pinned by @sha256 digest, no
#      ADD of a URL, and the final stage runs as a numeric non-root USER;
#   4. scripts/image/image.sh keeps its failing threshold
#      (HIGH,CRITICAL, --exit-code 1) on every trivy scan at that
#      threshold (config, local image, each pushed platform), its pinned
#      BuildKit, and its exact signer identity; no regex identity anywhere;
#   5. every non-comment line of apps/*/.trivyignore has an expiry date
#      not in the past and a justification;
#   6. Dependabot watches each app's Dockerfile (docker) and go.mod (gomod).
set -euo pipefail

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
today="${SUPPLY_CHAIN_TODAY:-$(date -u +%Y-%m-%d)}"

# 1-2 workflows
shopt -s nullglob
wfs=(.github/workflows/*.yml .github/workflows/*.yaml)
[ "${#wfs[@]}" -gt 0 ] || bad "no workflow found"
for wf in "${wfs[@]}"; do
  while IFS= read -r line; do
    ref="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/["'\'']//g')"
    printf '%s' "$ref" | grep -qE '^(actions|github)/[A-Za-z0-9_.-]+(/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}$' \
      || bad "$wf: '$ref' must be a GitHub-owned action pinned to a 40-hex commit SHA"
  done < <(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$wf" || true)
  grep -qE '^[[:space:]]*pull_request_target:' "$wf" && bad "$wf: pull_request_target is not allowed"
  grep -qE 'write-all' "$wf" && bad "$wf: write-all is not allowed"
  # (job, permission) for every write grant; job "-" = workflow level.
  while IFS=' ' read -r job perm; do
    if [ "$wf" = ".github/workflows/image.yml" ] && [ "$job" = "publish" ]; then
      case "$perm" in
        packages|id-token|attestations) : ;;
        *) bad "$wf: job publish may only write packages, id-token and attestations (found $perm)" ;;
      esac
    else
      bad "$wf: '$perm: write' in ${job/#-/workflow level} - writes are allowed only on image.yml job publish"
    fi
  done < <(awk '
    /^jobs:/ { injobs = 1; job = "-"; next }
    injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job) }
    /^[[:space:]]+[a-z-]+:[[:space:]]*write[[:space:]]*$/ { p = $1; sub(/:$/, "", p); print (injobs ? job : "-"), p }
  ' "$wf")
done

pub_wf=".github/workflows/image.yml"
if [ -f "$pub_wf" ] && grep -qE '^  publish:[[:space:]]*$' "$pub_wf"; then
  pub_block="$(awk '/^  publish:[[:space:]]*$/{f=1; next} f && /^  [A-Za-z0-9_-]+:[[:space:]]*$/{exit} f' "$pub_wf")"
  printf '%s\n' "$pub_block" | grep -qxF "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'" \
    || bad "$pub_wf: job publish must be guarded by exactly: if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
  printf '%s\n' "$pub_block" | grep -qxF "    needs: build-scan-sbom" \
    || bad "$pub_wf: job publish must need build-scan-sbom (no push without the PR-time scan)"
  for step in image-publish image-scan-remote image-sign image-verify; do
    printf '%s\n' "$pub_block" | grep -qE "run: make ${step}\$" || bad "$pub_wf: job publish must run make $step"
  done
fi
grep -rnE --exclude=check-supply-chain.sh -- '--certificate-identity-regexp|--certificate-oidc-issuer-regexp' scripts .github Makefile tests >/dev/null 2>&1 \
  && bad "a regex signer identity is used somewhere - only the exact identity in scripts/image/image.sh is trusted"

# 3 Dockerfiles
dfs=(apps/*/Dockerfile)
[ "${#dfs[@]}" -gt 0 ] || bad "no apps/*/Dockerfile found"
for df in "${dfs[@]}"; do
  while IFS= read -r from; do
    img="$(printf '%s' "$from" | awk '{print $2}')"
    case "$img" in --platform=*) img="$(printf '%s' "$from" | awk '{print $3}')";; esac
    printf '%s' "$img" | grep -qE '@sha256:[0-9a-f]{64}$' || bad "$df: base image '$img' is not pinned by digest"
  done < <(grep -E '^FROM[[:space:]]' "$df")
  grep -qiE '^ADD[[:space:]]+https?://' "$df" && bad "$df: ADD of a URL is not allowed"
  grep -E '^#[[:space:]]*syntax=' "$df" | grep -vqE '@sha256:[0-9a-f]{64}$' && bad "$df: a '# syntax=' frontend must be pinned by digest (or omitted)"
  last_user="$(awk '/^FROM[[:space:]]/{u=""} /^USER[[:space:]]/{u=$2} END{print u}' "$df")"
  printf '%s' "$last_user" | grep -qE '^[1-9][0-9]*(:[1-9][0-9]*)?$' \
    || bad "$df: the final stage must set a numeric non-root USER (got '${last_user:-none}')"
  app_dir="$(dirname "$df")"
  grep -qE "directory: \"?/${app_dir}\"?" .github/dependabot.yml || bad ".github/dependabot.yml does not watch /$app_dir"
  for eco in docker gomod; do
    [ "$eco" = gomod ] && [ ! -f "$app_dir/go.mod" ] && continue
    awk -v e="$eco" -v d="/$app_dir" '/package-ecosystem:/{eco=$0} /directory:/{ if (index(eco, "\"" e "\"") && index($0, d)) found=1 } END{exit !found}' .github/dependabot.yml \
      || bad ".github/dependabot.yml has no '$eco' update for /$app_dir"
  done
  # 5 trivyignore
  ign="$app_dir/.trivyignore"
  [ -f "$ign" ] || { bad "$ign missing (an empty, commented file is fine)"; continue; }
  while IFS= read -r l; do
    if ! printf '%s' "$l" | grep -qE '^[A-Z]+-[0-9A-Za-z-]+[[:space:]]+exp:[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+#[[:space:]]*[^[:space:]].*$'; then
      bad "$ign: '$l' needs 'ID exp:YYYY-MM-DD # justification'"
      continue
    fi
    exp="$(printf '%s' "$l" | sed -E 's/.*exp:([0-9-]{10}).*/\1/')"
    [[ "$exp" < "$today" ]] && bad "$ign: '$l' expired on $exp"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$ign" || true)
done

# 4 threshold
img_sh="scripts/image/image.sh"
grep -qE '^IMAGE_SCAN_SEVERITY="HIGH,CRITICAL"$' "$img_sh" || bad "$img_sh: the scan threshold must stay HIGH,CRITICAL"
sev_lines="$(grep -cE -- '--severity "\$IMAGE_SCAN_SEVERITY"' "$img_sh" || true)"
fail_lines="$(grep -cE -- '--exit-code 1 --severity "\$IMAGE_SCAN_SEVERITY"' "$img_sh" || true)"
{ [ "$sev_lines" -ge 3 ] && [ "$sev_lines" = "$fail_lines" ]; } \
  || bad "$img_sh: every trivy scan at the threshold (config, image, each pushed platform) must fail with --exit-code 1 ($fail_lines of $sev_lines)"
grep -qE '^IMAGE_BUILDKIT="moby/buildkit:v[0-9.]+@sha256:[0-9a-f]{64}"$' "$img_sh" || bad "$img_sh: BuildKit must be pinned by digest"
grep -qxF 'IMAGE_SIGNER_IDENTITY="https://github.com/IngMatrix-PGB/eks-gitops-platform-project/.github/workflows/image.yml@refs/heads/main"' "$img_sh" \
  || bad "$img_sh: the signer identity must be exactly the image workflow on main"
grep -qxF 'IMAGE_SIGNER_ISSUER="https://token.actions.githubusercontent.com"' "$img_sh" || bad "$img_sh: the signer issuer must be GitHub OIDC"

if [ "$fail" -ne 0 ]; then echo "check-supply-chain: FAILED"; exit 1; fi
echo "OK: ${#wfs[@]} workflow(s) use only SHA-pinned GitHub-owned actions, no pull_request_target; writes only on image.yml publish (main push, after the scan)"
echo "OK: ${#dfs[@]} Dockerfile(s) digest-pinned, non-root final USER, watched by Dependabot; .trivyignore entries dated and justified"
echo "OK: scan threshold HIGH,CRITICAL with --exit-code 1 on all $sev_lines scans; BuildKit pinned; exact signer identity, no regex"
echo "check-supply-chain: OK"
