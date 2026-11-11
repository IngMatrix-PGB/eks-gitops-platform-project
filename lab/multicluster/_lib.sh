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
LAB_MC_TOKEN_DURATION="24h"
LAB_MC_FIELD_MANAGER="eks-gitops-multicluster-registration"

# Per-member memory budget in MiB for the preflight, from the Phase
# 2.7.3 multicluster measurement (Docker view, steady state): hub with
# Argo CD 1.20-1.46 GiB; a registered spoke 0.55-0.83 GiB before ESO and
# workloads (Phase 2.7.4 adds ~0.12 GiB per spoke, measured in lab-lite).
# Each budget is the highest observed value plus headroom - a floor for
# refusing early, not a promise the cluster stays below it.
LAB_MC_HUB_MIB=1600
LAB_MC_SPOKE_MIB=1000

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
