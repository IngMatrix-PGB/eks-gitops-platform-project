#!/usr/bin/env bash
# Phase 5.2a: the one place this repository runs `terraform plan`,
# `terraform apply` and `terraform destroy` - always against a local AWS
# emulator (moto server, pinned by digest), never against AWS.
# ADR-0018; the exception is enforced by check-terraform-offline.
#
#   emulator.sh up                start the emulator container on loopback
#   emulator.sh down              remove it
#   emulator.sh plan  [ROOT...]   plan each root module against the emulator
#   emulator.sh apply [ROOT...]   plan, apply, re-plan (must be empty), destroy
#   emulator.sh coverage [ROOT...] like apply, but records the result of each
#                                 step per root in .tools/out/terraform/
#   emulator.sh ci                coverage for every root, then fails unless
#                                 each root's result equals its row in
#                                 terraform/emulator-coverage.tsv (Phase 5.2c)
#
# ROOT defaults to every root module (scripts/lab/terraform-root-modules.sh).
#
# Layers that keep this away from real AWS (each covered by a mutation):
#   1. the endpoint must be loopback (127.0.0.1 or localhost);
#   2. Terraform runs under `env -i` with only fake credentials and AWS
#      config/credential files pointed at /dev/null - no AWS_* variable,
#      profile or SSO session from the caller survives;
#   3. the generated provider sends every service to the endpoint and
#      pins allowed_account_ids to the emulator's account;
#   4. before any plan, the endpoint must answer the emulator's own API
#      (/moto-api/) and STS must report the emulator's account.
# Each root is copied to a scratch directory; the provider file and the
# state live only there and are deleted on exit. Nothing is uploaded.
set -euo pipefail

[ -f scripts/lab/terraform-root-modules.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }

TF_EMULATOR_IMAGE="docker.io/motoserver/moto:5.2.5@sha256:59a1965d845249b04def37a0e2565f9cc6c44543cb89b68e90f28f344b3b0d1a"
TF_EMULATOR_CONTAINER="${TF_EMULATOR_CONTAINER:-eks-gitops-tf-emulator}"
TF_EMULATOR_ENDPOINT="${TF_EMULATOR_ENDPOINT:-http://localhost:5050}"
TF_EMULATOR_REGION="us-east-1"
TERRAFORM_BIN="${TERRAFORM_BIN:-$(pwd)/.tools/bin/terraform}"
OUT_DIR="$(pwd)/.tools/out/terraform"
FIXTURES_DIR="$(pwd)/terraform/emulator"
COVERAGE_TABLE="$(pwd)/terraform/emulator-coverage.tsv"
# moto's fixed account, built at runtime so no 12-digit literal is
# committed (check-forbidden-terms).
EMULATOR_ACCOUNT="123456789$(printf '%03d' 12)"
# Every service a root module here can call. Anything not listed would
# fall back to the real AWS endpoint, so check-terraform-offline requires
# this list to cover every service the code uses (check 9b maps each
# resource and data source type to its service).
EMULATOR_SERVICES="accessanalyzer budgets cloudtrail cloudwatch configservice ec2 ecr eks events guardduty iam identitystore kms logs organizations s3 s3control secretsmanager securityhub sqs ssm ssoadmin sts"
# A step that has not finished by then is reported as a timeout: an API the
# emulator lacks makes the provider retry instead of failing.
TF_EMULATOR_STEP_TIMEOUT="${TF_EMULATOR_STEP_TIMEOUT:-240}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- layer 1: loopback only ------------------------------------------------
check_endpoint() {
  case "$TF_EMULATOR_ENDPOINT" in
    http://127.0.0.1:[0-9]*|http://localhost:[0-9]*) : ;;
    *) fail "TF_EMULATOR_ENDPOINT must be http://127.0.0.1:<port> or http://localhost:<port>, got '$TF_EMULATOR_ENDPOINT'" ;;
  esac
  case "$TF_EMULATOR_ENDPOINT" in *[!a-z0-9:/.]*) fail "TF_EMULATOR_ENDPOINT has unexpected characters" ;; esac
}

# --- layer 2: a clean environment for every terraform call -----------------
tf() {
  env -i \
    PATH="/usr/bin:/bin" HOME="$SCRATCH_HOME" \
    TF_IN_AUTOMATION=1 TF_INPUT=0 \
    TF_PLUGIN_CACHE_DIR="$(pwd)/.tools/cache/terraform-plugins" \
    TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=0 \
    AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
    AWS_ACCESS_KEY_ID=emulator AWS_SECRET_ACCESS_KEY=emulator \
    AWS_REGION="$TF_EMULATOR_REGION" AWS_EC2_METADATA_DISABLED=true \
    "$TERRAFORM_BIN" "$@"
}

# Runs "$@" with a time limit (no coreutils timeout on macOS). Returns 124
# on timeout.
with_timeout() {
  "$@" &
  pid=$!
  ( sleep "$TF_EMULATOR_STEP_TIMEOUT"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) &
  watcher=$!
  rc=0; wait "$pid" || rc=$?
  if kill -0 "$watcher" 2>/dev/null; then kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null || true; else rc=124; fi
  return "$rc"
}

# --- layer 4: the endpoint is the emulator, with the emulator's account ----
check_identity() {
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$TF_EMULATOR_ENDPOINT/moto-api/" || true)"
  [ "$code" = "200" ] || fail "no emulator at $TF_EMULATOR_ENDPOINT (GET /moto-api/ returned '$code') - run 'make tf-emulator-up'"
  acct="$(curl -s --max-time 5 -X POST "$TF_EMULATOR_ENDPOINT/" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H "Authorization: AWS4-HMAC-SHA256 Credential=emulator/20260101/$TF_EMULATOR_REGION/sts/aws4_request, SignedHeaders=host, Signature=0" \
    --data 'Action=GetCallerIdentity&Version=2011-06-15' | sed -n 's:.*<Account>\([0-9]*\)</Account>.*:\1:p')"
  [ "$acct" = "$EMULATOR_ACCOUNT" ] || fail "STS at $TF_EMULATOR_ENDPOINT reports account '$acct', not the emulator's - refusing"
}

# --- layer 3: the provider, generated into the scratch copy only -----------
write_provider() {
  {
    echo '# Generated by scripts/terraform/emulator.sh in a scratch copy. Never committed.'
    echo 'provider "aws" {'
    echo "  region                      = \"$TF_EMULATOR_REGION\""
    echo '  access_key                  = "emulator"'
    echo '  secret_key                  = "emulator"'
    echo "  allowed_account_ids         = [\"$EMULATOR_ACCOUNT\"]"
    echo '  s3_use_path_style           = true'
    echo '  skip_credentials_validation = true'
    echo '  skip_metadata_api_check     = true'
    echo '  skip_region_validation      = true'
    echo '  max_retries                 = 2'
    echo '  endpoints {'
    for s in $EMULATOR_SERVICES; do printf '    %-14s = "%s"\n' "$s" "$TF_EMULATOR_ENDPOINT"; done
    echo '  }'
    echo '}'
  } > "$1/zz_emulator_provider.tf"
}

# Fixture variables: terraform/emulator/<name>.tfvars, where <name> is the
# root's path with '/' replaced by '-'. __EMULATOR_ACCOUNT__(n) placeholders
# become 12-digit IDs at runtime (n=0 is the emulator's own account).
write_tfvars() {
  root="$1" dest="$2"
  name="$(printf '%s' "$root" | tr '/' '-')"
  src="$FIXTURES_DIR/$name.tfvars"
  [ -f "$src" ] || fail "no emulator fixture $src for root '$root'"
  awk -v acct="$EMULATOR_ACCOUNT" '{
    while (match($0, /__EMULATOR_ACCOUNT_[0-9]+__/)) {
      n = substr($0, RSTART + 19, RLENGTH - 21) + 0
      id = (n == 0) ? acct : sprintf("%012d", n)
      $0 = substr($0, 1, RSTART - 1) id substr($0, RSTART + RLENGTH)
    }
    print
  }' "$src" > "$dest"
}

prepare_root() {
  root="$1"
  work="$SCRATCH/$(printf '%s' "$root" | tr '/' '-')"
  rm -rf "$work"; mkdir -p "$work/repo"
  # Keep relative module paths valid: copy the root and terraform/modules.
  mkdir -p "$work/repo/$root" "$work/repo/terraform"
  cp "$root"/*.tf "$root"/.terraform.lock.hcl "$work/repo/$root/"
  [ -d terraform/modules ] && cp -R terraform/modules "$work/repo/terraform/"
  write_provider "$work/repo/$root"
  write_tfvars "$root" "$work/emulator.tfvars"
  echo "$work"
}

run_root() {
  mode="$1" root="$2"
  work="$(prepare_root "$root")" || return 1
  dir="$work/repo/$root"
  log="$OUT_DIR/$(printf '%s' "$root" | tr '/' '-').log"
  : > "$log"
  step() { echo "== $*" >> "$log"; }
  result_plan=fail result_apply=skip result_replan=skip result_destroy=skip planned="-"
  step init
  tf -chdir="$dir" init -backend=false -lockfile=readonly >> "$log" 2>&1 || { report "$root" init; return 1; }
  step plan
  if with_timeout tf -chdir="$dir" plan -var-file="$work/emulator.tfvars" -out="$work/plan.out" >> "$log" 2>&1; then
    result_plan=ok
  else
    report "$root" plan; return 1
  fi
  planned="$(tf -chdir="$dir" show -json "$work/plan.out" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(sum(1 for r in d.get("resource_changes",[]) if "create" in r["change"]["actions"]))' 2>/dev/null || echo "?")"
  if [ "$mode" = plan ]; then
    echo "OK: $root plan against the emulator: $planned to create"
    return 0
  fi
  step apply
  rc=0; with_timeout tf -chdir="$dir" apply -auto-approve "$work/plan.out" >> "$log" 2>&1 || rc=$?
  case "$rc" in 0) result_apply=ok ;; 124) result_apply=timeout ;; *) result_apply=fail ;; esac
  if [ "$result_apply" = ok ]; then
    step replan
    rc=0; with_timeout tf -chdir="$dir" plan -detailed-exitcode -var-file="$work/emulator.tfvars" >> "$log" 2>&1 || rc=$?
    case "$rc" in 0) result_replan=ok ;; 2) result_replan=drift ;; 124) result_replan=timeout ;; *) result_replan=fail ;; esac
  fi
  step destroy
  rc=0; with_timeout tf -chdir="$dir" destroy -auto-approve -var-file="$work/emulator.tfvars" >> "$log" 2>&1 || rc=$?
  case "$rc" in 0) result_destroy=ok ;; 124) result_destroy=timeout ;; *) result_destroy=fail ;; esac
  report "$root" done
  [ "$result_apply" = ok ] && [ "$result_replan" = ok ] && [ "$result_destroy" = ok ]
}

report() {
  root="$1" stage="$2"
  line="$root	plan=$result_plan	apply=$result_apply	replan=$result_replan	destroy=$result_destroy	planned=${planned:-?}"
  [ "$stage" = init ] && line="$root	init=fail"
  printf '%s\n' "$line" >> "$OUT_DIR/summary.tsv"
  if [ "$stage" = done ] && [ "$result_apply" = ok ] && [ "$result_replan" = ok ] && [ "$result_destroy" = ok ]; then
    echo "OK: $root plan/apply/re-plan (no changes)/destroy against the emulator ($planned resources)"
  else
    echo "NOTE: $root: $(printf '%s' "$line" | cut -f2- | tr '\t' ' ') - log: $OUT_DIR/$(printf '%s' "$root" | tr '/' '-').log" >&2
  fi
}

# Phase 5.2c: the measured result must equal the committed table, in both
# directions. A root that got worse is a regression; one that got better
# needs its row (and its gaps) updated. A root without a row, or a row
# without a root, also fails. Writes a Markdown table to summary.md.
compare_coverage() {
  awk -F'\t' '
    FNR == NR { if ($0 !~ /^#/ && $1 != "root" && NF >= 5) want[$1] = "plan=" $2 " apply=" $3 " replan=" $4 " destroy=" $5; next }
    { got = $2 " " $3 " " $4 " " $5; seen[$1] = 1
      if (!($1 in want)) { print "FAIL: " $1 " has no row in terraform/emulator-coverage.tsv (measured: " got ")"; bad = 1 }
      else if (want[$1] != got) { print "FAIL: " $1 " measured " got ", table says " want[$1]; bad = 1 }
      else print "OK: " $1 " matches the table (" got ")" }
    END { for (r in want) if (!(r in seen)) { print "FAIL: " r " is in the table but was not measured"; bad = 1 }
          exit bad }
  ' "$COVERAGE_TABLE" "$OUT_DIR/summary.tsv"
}

write_summary_md() {
  {
    echo "### Terraform against the local AWS emulator"
    echo ""
    echo "| Root | plan | apply | re-plan | destroy | to create |"
    echo "|---|---|---|---|---|---|"
    awk -F'\t' '{ for (i = 2; i <= NF; i++) sub(/^[a-z]+=/, "", $i); print "| `" $1 "` | " $2 " | " $3 " | " $4 " | " $5 " | " $6 " |" }' "$OUT_DIR/summary.tsv"
    echo ""
    echo "Expected results and the emulator gaps behind them: \`terraform/emulator-coverage.tsv\`."
  } > "$OUT_DIR/summary.md"
}

cmd="${1:-}"; shift || true
check_endpoint
case "$cmd" in
  up)
    command -v docker >/dev/null || fail "docker is required"
    port="${TF_EMULATOR_ENDPOINT##*:}"
    if ! docker ps --format '{{.Names}}' | grep -qx "$TF_EMULATOR_CONTAINER"; then
      docker rm -f "$TF_EMULATOR_CONTAINER" >/dev/null 2>&1 || true
      docker run -d --name "$TF_EMULATOR_CONTAINER" -p "127.0.0.1:$port:5000" "$TF_EMULATOR_IMAGE" >/dev/null
    fi
    for _ in $(seq 1 30); do
      curl -s -o /dev/null --max-time 2 "$TF_EMULATOR_ENDPOINT/moto-api/" && break; sleep 1
    done
    check_identity
    echo "OK: emulator up at $TF_EMULATOR_ENDPOINT ($TF_EMULATOR_IMAGE)"
    ;;
  down)
    docker rm -f "$TF_EMULATOR_CONTAINER" >/dev/null 2>&1 || true
    echo "OK: emulator removed"
    ;;
  plan|apply|coverage|ci)
    [ "$cmd" = ci ] && [ "$#" -gt 0 ] && fail "ci always measures every root module"
    [ -x "$TERRAFORM_BIN" ] || fail "$TERRAFORM_BIN missing - run 'make tools-install'"
    check_identity
    SCRATCH="$(mktemp -d)"; SCRATCH_HOME="$SCRATCH/home"; mkdir -p "$SCRATCH_HOME"
    trap 'rm -rf "$SCRATCH"' EXIT INT TERM
    mkdir -p "$OUT_DIR" .tools/cache/terraform-plugins
    : > "$OUT_DIR/summary.tsv"
    roots="$*"; [ -n "$roots" ] || roots="$(sh scripts/lab/terraform-root-modules.sh)"
    rc=0
    for r in $roots; do
      [ -d "$r" ] || fail "no root module '$r'"
      # A fresh emulator state per root, so roots never see each other.
      curl -s -o /dev/null -X POST "$TF_EMULATOR_ENDPOINT/moto-api/reset" || true
      if [ "$cmd" = plan ]; then run_root plan "$r" || rc=1; else run_root apply "$r" || rc=1; fi
    done
    [ "$cmd" = coverage ] && rc=0
    if [ "$cmd" = ci ]; then
      write_summary_md
      rc=0; compare_coverage || rc=1
      [ "$rc" -eq 0 ] && echo "OK: every root module matches terraform/emulator-coverage.tsv"
    fi
    exit "$rc"
    ;;
  *) fail "usage: emulator.sh up|down|plan|apply|coverage [ROOT...] | ci" ;;
esac
