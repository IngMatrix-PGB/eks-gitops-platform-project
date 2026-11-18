#!/bin/sh
# Regression tests for scripts/validate/check-spoke-access.sh (Phase 6.3a):
# the checker, unmodified, against throwaway copies of the three places
# the spokes' allowed kinds live (AppProject, spoke Role, Argo CD's
# resource.inclusions), each with one mutation. Backs
# `make check-spoke-access-regression`. Touches nothing outside one
# mktemp -d root.
set -eu

here="$(cd "$(dirname "$0")/../.." && pwd)"
checker="$here/scripts/validate/check-spoke-access.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM
pass=0; fail=0; n=0
run_case() { # $1=description $2=accept|reject $3=setup function
  n=$((n + 1)); fx="$root/case$n"
  mkdir -p "$fx/platform/spoke-access" "$fx/gitops/bootstrap/templates" "$fx/lab/argocd"
  cp "$here/platform/spoke-access/role.yaml" "$fx/platform/spoke-access/"
  cp "$here/gitops/bootstrap/templates/appproject.yaml" "$fx/gitops/bootstrap/templates/"
  cp "$here/lab/argocd/values-lab.yaml" "$fx/lab/argocd/"
  "$3" "$fx"
  if (cd "$fx" && bash "$checker" > "$fx.out" 2>&1); then got=accept; else got=reject; fi
  if [ "$got" = "$2" ]; then echo "OK: $1"; pass=$((pass + 1)); else
    echo "FAIL: $1 (expected $2, got $got)" >&2; sed 's/^/    /' "$fx.out" >&2; fail=$((fail + 1)); fi
}
mutate() { # $1=file $2=sed expression; a mutation that changes nothing fails loudly
  cp "$1" "$1.orig"; sed -i.bak -e "$2" "$1" && rm -f "$1.bak"
  if cmp -s "$1" "$1.orig"; then echo "FAIL: mutation '$2' changed nothing in $1" >&2; exit 1; fi
  rm -f "$1.orig"
}

real() { :; }
run_case "the real AppProject, Role and inclusions are accepted" accept real

role_no_sts() { mutate "$1/platform/spoke-access/role.yaml" 's/\["deployments", "statefulsets"\]/["deployments"]/'; }
run_case "a Role without statefulsets is rejected" reject role_no_sts
role_secrets() { mutate "$1/platform/spoke-access/role.yaml" 's/"persistentvolumeclaims"\]/"persistentvolumeclaims", "secrets"]/'; }
run_case "a Role that grants secrets is rejected" reject role_secrets
incl_no_job() { mutate "$1/lab/argocd/values-lab.yaml" 's/kinds: \["Job", "CronJob"\]/kinds: ["CronJob"]/'; }
run_case "inclusions without Job are rejected" reject incl_no_job
incl_extra() { mutate "$1/lab/argocd/values-lab.yaml" 's/kinds: \["Deployment", "StatefulSet"\]/kinds: ["Deployment", "StatefulSet", "DaemonSet"]/'; }
run_case "inclusions naming a kind the AppProject does not allow are rejected" reject incl_extra
proj_no_pvc() { mutate "$1/gitops/bootstrap/templates/appproject.yaml" '/kind: PersistentVolumeClaim/d'; }
run_case "an AppProject without PersistentVolumeClaim (Role and inclusions still have it) is rejected" reject proj_no_pvc

echo ""
echo "test-spoke-access: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "test-spoke-access: FAILED"; exit 1; }
echo "test-spoke-access: OK"
