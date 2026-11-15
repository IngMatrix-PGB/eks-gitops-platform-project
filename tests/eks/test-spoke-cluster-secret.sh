#!/bin/sh
# Phase 3.4.4b: fully offline positive/negative matrix for
# lab/eks/spoke-cluster-secret.sh, plus the selection contract between
# the Secret it renders and the aws-eks profile of gitops/bootstrap.
# No AWS, no cluster, no network, no Terraform state: fixtures are built
# at runtime (fake account IDs via printf, a fake PEM), and fake aws,
# terraform and kubectl binaries first on PATH log any call and fail -
# the log must stay empty. Backs `make eks-test-spoke-secret`.
set -eu

[ -f lab/eks/spoke-cluster-secret.sh ] || { echo "FAIL: run from the repository root" >&2; exit 1; }
HELM_BIN="${HELM_BIN:-$(command -v helm || true)}"
[ -n "$HELM_BIN" ] || { echo "FAIL: helm not found" >&2; exit 1; }

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# --- fake binaries: any call is a test failure ---
mkdir -p "$root/bin"
call_log="$root/calls.log"
: > "$call_log"
for b in aws terraform kubectl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 97\n' "$b" "$call_log" > "$root/bin/$b"
  chmod +x "$root/bin/$b"
done
render() { PATH="$root/bin:$PATH" sh lab/eks/spoke-cluster-secret.sh "$@"; }

# --- fixtures (runtime only; no 12-digit literal in this file) ---
acct="$(printf '%012d' 7)"
ca="$(printf -- '-----BEGIN CERTIFICATE-----\nZmFrZS1jYQ==\n-----END CERTIFICATE-----\n' | base64 | tr -d '\n')"
role() { echo "arn:aws:iam::${acct}:role/eks-gitops-$1-argocd-manager"; }
endpoint="https://ABCDEF0123456789.gr7.us-east-1.eks.amazonaws.com"

# --- positive: one Secret per environment, exact shape, no credential ---
for env in dev uat prod; do
  out="$root/$env.yaml"
  if ! render --env "$env" --cluster-name "eks-gitops-$env" --endpoint "$endpoint" --ca "$ca" --role-arn "$(role "$env")" > "$out" 2> "$root/err"; then
    bad "$env: renderer rejected a valid input: $(cat "$root/err")"
    continue
  fi
  body="$(grep -v '^#' "$out")"
  pos_fail=0
  for want in \
    '^kind: Secret$' \
    "^  name: spoke-${env}$" \
    '^  namespace: argocd$' \
    '^    argocd.argoproj.io/secret-type: cluster$' \
    "^    platform.environment: ${env}$" \
    '^    eks-gitops-lab-lite.local/owner: eks-spoke-registration$' \
    "^  server: ${endpoint}$" \
    "^  namespaces: ${env}$" \
    '^  clusterResources: "false"$' \
    "\"awsAuthConfig\": \\{\"clusterName\": \"eks-gitops-${env}\", \"roleARN\": \"$(role "$env")\"\\}" \
    '"insecure": false'; do
    printf '%s\n' "$body" | grep -qE -- "$want" || { bad "$env: missing /$want/"; pos_fail=1; }
  done
  [ "$(printf '%s\n' "$body" | grep -c '^kind: ')" = "1" ] || { bad "$env: expected exactly one document"; pos_fail=1; }
  if printf '%s\n' "$body" | grep -qiE 'bearerToken|password|username|execProviderConfig|token|"insecure": true|keyData|certData'; then
    bad "$env: the Secret carries a credential-shaped field"; pos_fail=1
  fi
  [ "$pos_fail" -eq 0 ] && ok "$env: Secret spoke-$env with awsAuthConfig (eks-gitops-$env, its own argocd-manager role), CA, namespaces=$env, clusterResources=false, no token"
done

# --- negatives: each must fail closed with its own reason ---
expect_reject() {
  desc="$1" reason="$2"; shift 2
  if render "$@" > "$root/neg.out" 2> "$root/neg.err"; then
    bad "accepted: $desc"
  elif [ -s "$root/neg.out" ]; then
    bad "$desc: rejected but still printed output"
  elif grep -q -- "$reason" "$root/neg.err"; then
    ok "rejected: $desc"
  else
    bad "$desc: rejected for the wrong reason: $(cat "$root/neg.err")"
  fi
}
valid() { echo --cluster-name eks-gitops-dev --endpoint "$endpoint" --ca "$ca"; }
# shellcheck disable=SC2046
expect_reject "unknown environment qa" "must be one of" --env qa $(valid) --role-arn "$(role qa)"
# shellcheck disable=SC2046
expect_reject "uat role registered as dev" "eks-gitops-dev-argocd-manager" --env dev $(valid) --role-arn "$(role uat)"
expect_reject "11-digit account in role ARN" "eks-gitops-dev-argocd-manager" --env dev --cluster-name eks-gitops-dev --endpoint "$endpoint" --ca "$ca" --role-arn "arn:aws:iam::$(printf '%011d' 7):role/eks-gitops-dev-argocd-manager"
expect_reject "http endpoint" "https://" --env dev --cluster-name eks-gitops-dev --endpoint "http://ABCDEF.eks.amazonaws.com" --ca "$ca" --role-arn "$(role dev)"
expect_reject "endpoint with user info" "https://" --env dev --cluster-name eks-gitops-dev --endpoint "https://user:pw@ABCDEF.eks.amazonaws.com" --ca "$ca" --role-arn "$(role dev)"
expect_reject "endpoint with a path" "https://" --env dev --cluster-name eks-gitops-dev --endpoint "$endpoint/api" --ca "$ca" --role-arn "$(role dev)"
expect_reject "non-base64 CA" "must be base64" --env dev --cluster-name eks-gitops-dev --endpoint "$endpoint" --ca 'not base64!' --role-arn "$(role dev)"
expect_reject "base64 that is not a certificate" "PEM certificate" --env dev --cluster-name eks-gitops-dev --endpoint "$endpoint" --ca "$(printf 'hello' | base64)" --role-arn "$(role dev)"
expect_reject "invalid cluster name" "not a valid EKS cluster name" --env dev --cluster-name '1bad name' --endpoint "$endpoint" --ca "$ca" --role-arn "$(role dev)"
expect_reject "missing role ARN" "--role-arn is required" --env dev --cluster-name eks-gitops-dev --endpoint "$endpoint" --ca "$ca"
expect_reject "unknown argument" "unknown argument" --env dev --token abc

# --- the renderer never shells out to aws, terraform or kubectl ---
if [ -s "$call_log" ]; then
  bad "the renderer invoked an external tool: $(cat "$call_log")"
else
  ok "no aws, terraform or kubectl call across the whole matrix"
fi

# --- contract: the Secret's labels are exactly what the aws-eks profile
# selects, and never what the lab profile selects ---
values="gitops/bootstrap/values.yaml"
aws_block="$(awk '/^awsEks:/{f=1; next} f && /^[^ #]/{exit} f' "$values")"
v_owner="$(printf '%s\n' "$aws_block" | sed -n 's/^  ownerLabelValue: //p')"
v_key="$(printf '%s\n' "$aws_block" | sed -n 's/^  ownerLabelKey: //p')"
v_envkey="$(printf '%s\n' "$aws_block" | sed -n 's/^  environmentLabelKey: //p')"
v_prefix="$(printf '%s\n' "$aws_block" | sed -n 's/^  clusterNamePrefix: //p')"
v_envs="$(printf '%s\n' "$aws_block" | awk '/^  environments:/{f=1; next} f && /^    - /{printf "%s ", $2} f && !/^    - /{f=0}')"
s_get() { sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" lab/eks/spoke-cluster-secret.sh; }
contract_fail=0
[ "$v_owner" = "$(s_get EKS_SPOKE_OWNER_LABEL_VALUE)" ] || { bad "owner label value: values.yaml '$v_owner' vs renderer '$(s_get EKS_SPOKE_OWNER_LABEL_VALUE)'"; contract_fail=1; }
[ "$v_key" = "$(s_get EKS_SPOKE_OWNER_LABEL_KEY)" ] || { bad "owner label key differs between values.yaml and the renderer"; contract_fail=1; }
[ "$v_envkey" = "$(s_get EKS_SPOKE_ENV_LABEL_KEY)" ] || { bad "environment label key differs between values.yaml and the renderer"; contract_fail=1; }
[ "$v_prefix" = "$(s_get EKS_SPOKE_NAME_PREFIX)" ] || { bad "cluster name prefix differs between values.yaml and the renderer"; contract_fail=1; }
[ "$v_envs" = "$(s_get EKS_SPOKE_ENVIRONMENTS) " ] || { bad "environments: values.yaml '$v_envs' vs renderer '$(s_get EKS_SPOKE_ENVIRONMENTS)'"; contract_fail=1; }
lab_owner="$(sed -n 's/^LAB_MC_OWNER_LABEL_VALUE="\(.*\)"$/\1/p' lab/multicluster/_lib.sh)"
[ -n "$lab_owner" ] && [ "$lab_owner" != "$v_owner" ] || { bad "the EKS owner label must differ from the lab's ('$lab_owner')"; contract_fail=1; }
# The rendered selector (not just values.yaml) must match the Secret.
sel="$("$HELM_BIN" template gitops/bootstrap --set profile=aws-eks)"
printf '%s\n' "$sel" | grep -qE "^\s*${v_key}: ${v_owner}$" || { bad "the aws-eks ApplicationSet selector does not select owner '$v_owner'"; contract_fail=1; }
[ "$contract_fail" -eq 0 ] && ok "selection contract: renderer labels = gitops/bootstrap awsEks ($v_key=$v_owner, $v_envkey in ${v_envs% }, names ${v_prefix}<env>), distinct from the lab owner '$lab_owner'"

if [ "$fail" -ne 0 ]; then echo "eks-test-spoke-secret: FAILED"; exit 1; fi
echo "eks-test-spoke-secret: OK"
