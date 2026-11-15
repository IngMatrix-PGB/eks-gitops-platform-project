#!/usr/bin/env bash
# Phase 5.1a: offline guard of the image supply chain's static rules.
# Part of `make validate`. Checks:
#   1. every `uses:` in .github/workflows is a GitHub-owned action
#      (actions/* or github/*) pinned to a 40-hex commit SHA;
#   2. no workflow uses pull_request_target, and no workflow grants a
#      write permission (5.1a pushes and signs nothing);
#   3. every Dockerfile FROM under apps/ is pinned by @sha256 digest, no
#      ADD of a URL, and the final stage runs as a numeric non-root USER;
#   4. scripts/image/image.sh keeps its failing threshold
#      (HIGH,CRITICAL, --exit-code 1) for both trivy scans;
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
  grep -qE '^[[:space:]]+[a-z-]+:[[:space:]]*write[[:space:]]*$|permissions:[[:space:]]*write-all' "$wf" \
    && bad "$wf: grants a write permission (nothing is pushed or signed in Phase 5.1a)"
done

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
[ "$(grep -cE -- '--exit-code 1 --severity "\$IMAGE_SCAN_SEVERITY"' "$img_sh")" = "2" ] \
  || bad "$img_sh: both trivy scans (config and image) must fail with --exit-code 1 at the threshold"

if [ "$fail" -ne 0 ]; then echo "check-supply-chain: FAILED"; exit 1; fi
echo "OK: ${#wfs[@]} workflow(s) use only SHA-pinned GitHub-owned actions, no write permission, no pull_request_target"
echo "OK: ${#dfs[@]} Dockerfile(s) digest-pinned, non-root final USER, watched by Dependabot; .trivyignore entries dated and justified"
echo "OK: scan threshold HIGH,CRITICAL with --exit-code 1"
echo "check-supply-chain: OK"
