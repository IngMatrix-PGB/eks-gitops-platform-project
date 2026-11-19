#!/bin/sh
# Phase 6.3d (ADR-0022 amendment): non-destructive restore check of the
# reference application's database dumps. Backs
# `make db-restore-check ENV=<dev|uat|prod> [LAB_CLUSTER=<env>]`.
#
#   1. takes the newest dump of bucket dumps-<env> straight from the
#      store's directory on this machine (.local/backups/data) and checks
#      it against its .sha256;
#   2. restores it into a throwaway database notes_restorecheck in the
#      environment's postgres (pg_restore through kubectl exec, local
#      superuser), never touching database notes;
#   3. compares the restored rows with the live rows of the same ids
#      (notes are never updated, so they must be identical): row count
#      and an ordered SHA-256 of every column;
#   4. drops the throwaway database, also on failure.
# Prints counts and hash prefixes only, never row content.
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
env_name="${1:-}"
case "$env_name" in dev|uat|prod) : ;; *) echo "usage: $0 <dev|uat|prod>" >&2; exit 2 ;; esac
LAB_CLUSTER="${LAB_CLUSTER:-$env_name}"
export LAB_CLUSTER
. scripts/lab/_lib.sh
require_repo_root
require_tools
. scripts/backup/_lib.sh
check_cluster_identity >/dev/null || { echo "FAIL: cluster '$PROJECT_CLUSTER_NAME' is missing or does not match its expected identity" >&2; exit 1; }

dir="$BK_STORE_DIR/data/dumps-${env_name}"
pod="platform-postgres-${env_name}-0"
db=notes; scratch=notes_restorecheck
[ -d "$dir" ] || { echo "FAIL: no dumps for $env_name ($dir missing) - make db-dump-key ENV=$env_name and let the CronJob run" >&2; exit 1; }
dump="$(ls -1 "$dir" | grep -E "^${db}-[0-9]{8}T[0-9]{6}Z\.dump$" | sort | tail -1)"
[ -n "$dump" ] || { echo "FAIL: no dump file in $dir" >&2; exit 1; }
[ -f "$dir/$dump.sha256" ] || { echo "FAIL: $dump has no .sha256 next to it" >&2; exit 1; }
want="$(cut -d' ' -f1 "$dir/$dump.sha256")"
got="$(shasum -a 256 "$dir/$dump" | cut -d' ' -f1)"
[ "$want" = "$got" ] || { echo "FAIL: $dump does not match its .sha256" >&2; exit 1; }
echo "OK: newest dump $dump ($(wc -c < "$dir/$dump" | tr -d ' ') bytes), SHA-256 matches (${got%"${got#????????????}"})"

psql_c() { pkubectl -n "$env_name" exec -i "$pod" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 -tAq "$@"; }
cleanup() { psql_c -d postgres -c "DROP DATABASE IF EXISTS $scratch" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
psql_c -d postgres -c "CREATE DATABASE $scratch" >/dev/null
pkubectl -n "$env_name" exec -i "$pod" -c postgres -- pg_restore -U postgres -d "$scratch" --no-owner --exit-on-error < "$dir/$dump"
echo "OK: restored into throwaway database $scratch"

# count, highest id and an ordered SHA-256 of every column, of the rows
# with id <= $2 (all rows without it; SQL on stdin, no shell quoting)
digest() {
  psql_c -d "$1" <<SQL
SELECT count(*) || ' ' || coalesce(max(id), 0) || ' ' ||
       encode(sha256(convert_to(coalesce(string_agg(id || E'\\t' || body || E'\\t' || created_at, E'\\n' ORDER BY id), ''), 'UTF8')), 'hex')
FROM notes WHERE id <= ${2:-id};
SQL
}
restored="$(digest "$scratch")"
max_id="$(echo "$restored" | cut -d' ' -f2)"
live="$(digest "$db" "$max_id")"
r_n="${restored%% *}"; l_n="${live%% *}"; r_h="${restored##* }"; l_h="${live##* }"
if [ "$r_n" = "$l_n" ] && [ "$r_h" = "$l_h" ]; then
  echo "OK: restored rows match the live rows with id <= $max_id: $r_n row(s), SHA-256 ${r_h%"${r_h#????????????}"}"
else
  echo "FAIL: restored $r_n row(s) (${r_h%"${r_h#????????????}"}) differ from live $l_n row(s) (${l_h%"${l_h#????????????}"}) for id <= $max_id" >&2
  exit 1
fi
echo "OK: throwaway database dropped; database $db untouched"
