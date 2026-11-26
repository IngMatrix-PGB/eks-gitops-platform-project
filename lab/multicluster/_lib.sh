#!/bin/sh
# Shared helpers for the lab-multicluster profile (Phase 2.7.3,
# ADR-0015): one kind cluster for the `management` hub plus one per
# spoke. POSIX shell, sourced only, from the repository root, after
# scripts/lab/_lib.sh. Every cluster is reached only through its own
# project-local kubeconfig (.local/kubeconfig-<cluster>) - never the
# global one, never a shared one.

LAB_MC_HUB="hub"
LAB_MC_DEFAULT_SPOKES="dev uat"
LAB_MC_ACCESS_NS="argocd-access"
LAB_MC_ACCESS_SA="argocd-manager"
LAB_MC_OWNER_LABEL_KEY="eks-gitops-lab-lite.local/owner"
LAB_MC_OWNER_LABEL_VALUE="multicluster-registration"
LAB_MC_ENV_LABEL_KEY="platform.environment"
# 24h by default (D2 of 2.7.3). LAB_MC_TOKEN_DURATION may shorten it, for
# the rotation tests only: spoke-register.sh refuses anything outside
# 10m (the TokenRequest minimum) to 24h.
LAB_MC_TOKEN_DURATION="${LAB_MC_TOKEN_DURATION:-24h}"
LAB_MC_FIELD_MANAGER="eks-gitops-multicluster-registration"

# Per-member memory budget in MiB for the preflight, from the Phase
# 2.7.3/2.7.4 multicluster measurements (Docker view, steady state):
# hub with Argo CD 1.20-1.46 GiB; a spoke with registration, its ESO
# release and the workload 1.10-1.17 GiB (Phase 2.7.4 - more than the
# ~0.12 GiB lab-lite suggested: a spoke's single ESO release also runs
# its own webhook and cert-controller). Each budget is the highest
# observed value plus headroom - a floor for refusing early, not a
# promise the cluster stays below it.
LAB_MC_HUB_MIB=1600
LAB_MC_SPOKE_MIB=1300

# lab_mc_spokes - prints the selected spokes, space separated, from
# SPOKES (comma or space separated; default "dev,uat"). Fails closed on
# an unknown spoke or a duplicate, before anything is created.
lab_mc_spokes() {
  raw="${SPOKES:-$LAB_MC_DEFAULT_SPOKES}"
  list="$(printf '%s' "$raw" | tr ',' ' ')"
  out=""
  for s in $list; do
    case " $LAB_MC_ALL_SPOKES " in
      *" $s "*) : ;;
      *) echo "FAIL: unknown spoke '$s' in SPOKES - expected only: $LAB_MC_ALL_SPOKES" >&2; return 1 ;;
    esac
    case " $out " in
      *" $s "*) echo "FAIL: spoke '$s' listed twice in SPOKES" >&2; return 1 ;;
    esac
    out="${out:+$out }$s"
  done
  [ -n "$out" ] || { echo "FAIL: SPOKES selects no spoke" >&2; return 1; }
  printf '%s\n' "$out"
}

# lab_mc_require_spoke <name> - fails closed unless <name> is one of
# dev/uat/prod.
lab_mc_require_spoke() {
  case " $LAB_MC_ALL_SPOKES " in
    *" $1 "*) return 0 ;;
  esac
  echo "FAIL: SPOKE must be exactly one of: $LAB_MC_ALL_SPOKES (got '$1')" >&2
  return 1
}

# lab_mc_kubeconfig <cluster> - the project-local kubeconfig path for a
# multicluster member.
lab_mc_kubeconfig() {
  printf '.local/kubeconfig-%s\n' "$1"
}

# ckubectl <cluster> <args...> - kubectl against exactly one
# multicluster member's own kubeconfig, never an ambient KUBECONFIG.
ckubectl() {
  ck_cluster="$1"; shift
  ck_kc="$(lab_mc_kubeconfig "$ck_cluster")"
  KUBECONFIG="$ck_kc" "$KUBECTL_BIN" --kubeconfig "$ck_kc" "$@"
}

# lab_mc_identity <cluster> - runs the pinned six-point identity check
# against that member in a subshell (so LAB_CLUSTER never leaks into the
# caller). Sets LAB_MC_IDENTITY_CASE. Returns 0 only on "match".
lab_mc_identity() {
  LAB_MC_IDENTITY_CASE="$(LAB_CLUSTER="$1" sh -c '. scripts/lab/_lib.sh; check_cluster_identity >/dev/null 2>&1 || true; printf "%s" "$IDENTITY_CASE"')"
  [ "$LAB_MC_IDENTITY_CASE" = "match" ]
}

# lab_mc_internal_server <cluster> - the API server URL as seen from
# inside the Docker "kind" network (container name, port 6443) - the
# address the hub's Argo CD uses. Verified in Phase 2.7.3: the API
# server certificate's SAN includes the container name.
lab_mc_internal_server() {
  printf 'https://eks-gitops-%s-control-plane:6443\n' "$1"
}

# lab_mc_docker_free_mib - Docker's total memory minus every running
# container's current usage, in MiB. Prints an integer.
lab_mc_docker_free_mib() {
  total_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null)" || return 1
  used_mib="$(docker stats --no-stream --format '{{.MemUsage}}' 2>/dev/null | awk '
    {
      split($1, a, /[A-Za-z]+/); v = a[1]; u = $1; gsub(/[0-9.]/, "", u)
      if (u == "GiB") v = v * 1024; else if (u == "KiB" || u == "kB") v = v / 1024; else if (u == "B") v = v / 1048576
      s += v
    }
    END { printf "%d", s }')"
  awk -v t="$total_bytes" -v u="${used_mib:-0}" 'BEGIN { printf "%d\n", t / 1048576 - u }'
}

# lab_mc_spoke_ready <env> - read-only Phase 2.7.4 readiness of one
# registered spoke for the hub bootstrap: its own ESO release's
# controller and webhook are Available and its source Secret exists (so
# the first sync of platform-smoke-<env> neither races the ESO CRDs/
# webhook nor waits on missing source material). Never reads the
# Secret's data. Prints the reason and returns 1 on the first gap.
lab_mc_spoke_ready() {
  msr_env="$1"
  for msr_dep in "eso-${msr_env}-external-secrets" "eso-${msr_env}-external-secrets-webhook"; do
    msr_av="$(ckubectl "$msr_env" -n "eso-${msr_env}" get deployment "$msr_dep" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    if [ "${msr_av:-0}" -lt 1 ] 2>/dev/null || [ -z "$msr_av" ]; then
      echo "spoke '$msr_env': Deployment eso-${msr_env}/${msr_dep} not Available - run 'make mc-spoke-eso-install SPOKE=${msr_env}'"
      return 1
    fi
  done
  # Phase 2.8.2: an HPA without metrics-server reports no metrics and
  # Argo CD marks its Application Degraded.
  msr_ms="$(ckubectl "$msr_env" get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [ "$msr_ms" != "True" ]; then
    echo "spoke '$msr_env': metrics-server APIService not Available - run 'make mc-spoke-metrics-server SPOKE=${msr_env}'"
    return 1
  fi
  if ! ckubectl "$msr_env" -n "eso-source-${msr_env}" get secret "local-backend-${msr_env}" -o name >/dev/null 2>&1; then
    echo "spoke '$msr_env': source Secret eso-source-${msr_env}/local-backend-${msr_env} absent - run 'make mc-spoke-source-secret SPOKE=${msr_env}'"
    return 1
  fi
  return 0
}

# lab_mc_spoke_role <spoke> - prints platform/spoke-access/role.yaml for
# that spoke's namespace (Phase 3.4.4a: the one Role definition shared
# with EKS). Fails closed if the file's name or owner label no longer
# match this registration's constants, which deregistration relies on.
lab_mc_spoke_role() {
  msr_file="platform/spoke-access/role.yaml"
  grep -qE "^  name: ${LAB_MC_ACCESS_SA}$" "$msr_file" \
    && grep -qE "^    ${LAB_MC_OWNER_LABEL_KEY}: ${LAB_MC_OWNER_LABEL_VALUE}$" "$msr_file" \
    || { echo "FAIL: $msr_file name/owner label no longer match the registration constants" >&2; return 1; }
  sed "s/SPOKE_NAMESPACE/$1/" "$msr_file" | grep -v '^#'
}

# lab_mc_token_needs_rotation <expires> <hours> - succeeds (rotate) when
# the recorded expiry (the token-expires annotation, UTC, ...Z) is empty,
# unreadable, or less than <hours> away; fails (keep) otherwise.
# SPOKE_TOKEN_NOW (UTC, ...Z) overrides the clock, for the tests only.
lab_mc_token_needs_rotation() {
  python3 -I - "$1" "$2" "${SPOKE_TOKEN_NOW:-}" <<'PY'
import datetime as dt, sys
exp_s, hours_s, now_s = sys.argv[1], sys.argv[2], sys.argv[3]
fmt = "%Y-%m-%dT%H:%M:%SZ"
utc = dt.timezone.utc
try:
    hours = float(hours_s)
except ValueError:
    sys.exit(2)
now = dt.datetime.strptime(now_s, fmt).replace(tzinfo=utc) if now_s else dt.datetime.now(utc)
try:
    exp = dt.datetime.strptime(exp_s, fmt).replace(tzinfo=utc)
except ValueError:
    sys.exit(0)  # missing or unreadable: rotate
sys.exit(0 if exp - now < dt.timedelta(hours=hours) else 1)
PY
}

# lab_mc_token_expiry <spoke> - prints the hub Secret's recorded expiry,
# empty when the Secret or the annotation is missing.
lab_mc_token_expiry() {
  ckubectl "$LAB_MC_HUB" -n argocd get secret "spoke-$1" -o jsonpath='{.metadata.annotations.eks-gitops-lab-lite\.local/token-expires}' 2>/dev/null || true
}

# lab_mc_token_duration_ok <duration> - 10m to 24h, the only token
# lifetimes spoke-register.sh issues (10m is the TokenRequest minimum).
lab_mc_token_duration_ok() {
  case "$1" in
    24h|1[0-9]h|2[0-3]h|[1-9]h|[1-5][0-9]m) return 0 ;;
    *) return 1 ;;
  esac
}
