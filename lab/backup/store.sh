#!/bin/sh
# The lab's backup object store (Phase 6.2a, ADR-0022): Versity S3 Gateway
# in one container on the kind docker network. Only the S3 port (7070)
# is exposed, and only to that network (no host port); the admin API
# listens on the container's loopback. Data, object metadata (a sidecar
# directory: the macOS bind mount has no extended attributes) and the
# IAM file live under .local/backups/ (gitignored, mode 700), so backups
# and keys outlive every cluster and the container. Backs
# `make backup-store-up|down|status`.
#
#   up      start it (idempotent). First run: generate the root
#           credential into a mode-600 env file and an empty IAM file, so
#           no S3 user exists until backup-install adds one per cluster.
#   down    stop and remove the container; data, metadata, keys stay
#   status  container running; buckets and their owners
set -eu

if [ ! -f "scripts/lab/_lib.sh" ]; then
  echo "FAIL: must be run from the repository root (scripts/lab/_lib.sh not found)" >&2
  exit 1
fi
. scripts/lab/_lib.sh
require_repo_root
. scripts/backup/_lib.sh
command -v docker >/dev/null || { echo "FAIL: docker not found" >&2; exit 1; }

case "${1:-}" in
  up)
    docker network inspect "$BK_STORE_NETWORK" >/dev/null 2>&1 || { echo "FAIL: docker network '$BK_STORE_NETWORK' not found - create lab-multicluster first" >&2; exit 1; }
    umask 077
    mkdir -p "$BK_STORE_DIR/data" "$BK_STORE_DIR/meta" "$BK_STORE_DIR/iam" "$BK_STORE_DIR/config"
    chmod 700 "$BK_STORE_DIR"
    if [ ! -f "$BK_STORE_ROOT_ENV" ]; then
      rk="$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 20)"
      rs="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)"
      printf 'ROOT_ACCESS_KEY_ID=%s\nROOT_SECRET_ACCESS_KEY=%s\n' "$rk" "$rs" > "$BK_STORE_ROOT_ENV"
      printf 'ADMIN_ACCESS_KEY_ID=%s\nADMIN_SECRET_ACCESS_KEY=%s\nADMIN_ENDPOINT_URL=http://127.0.0.1:7080\n' "$rk" "$rs" > "$BK_STORE_ADMIN_ENV"
      unset rk rs
      echo "OK: store root credential generated into $BK_STORE_DIR/config (mode 600)"
    fi
    [ -f "$BK_STORE_IAM" ] || printf '{"accessAccounts":{}}' > "$BK_STORE_IAM"
    if bk_store_running; then
      echo "OK: store '$BK_STORE_CONTAINER' already running - no-op"
      exit 0
    fi
    docker rm -f "$BK_STORE_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$BK_STORE_CONTAINER" --network "$BK_STORE_NETWORK" --restart unless-stopped \
      --env-file "$BK_STORE_ROOT_ENV" \
      -v "$(pwd)/$BK_STORE_DIR/data:/store" \
      -v "$(pwd)/$BK_STORE_DIR/meta:/meta" \
      -v "$(pwd)/$BK_STORE_DIR/iam:/iam" \
      "$BK_STORE_IMAGE" --port ":${BK_STORE_PORT}" --admin-port 127.0.0.1:7080 \
      --iam-dir /iam --iam-cache-disable posix --sidecar /meta /store >/dev/null
    i=0
    until bk_store_admin list-buckets >/dev/null 2>&1 || [ "$i" -gt 30 ]; do i=$((i + 1)); sleep 1; done
    bk_store_running || { echo "FAIL: store did not start" >&2; docker logs --tail 20 "$BK_STORE_CONTAINER" >&2; exit 1; }
    echo "OK: store '$BK_STORE_CONTAINER' running on network '$BK_STORE_NETWORK' ($BK_STORE_URL); data in $BK_STORE_DIR"
    ;;
  down)
    if docker inspect "$BK_STORE_CONTAINER" >/dev/null 2>&1; then
      docker rm -f "$BK_STORE_CONTAINER" >/dev/null
      echo "OK: store container removed; data, metadata and keys kept in $BK_STORE_DIR"
    else
      echo "OK: store container already absent - no-op"
    fi
    ;;
  status)
    bk_store_running || { echo "FAIL: store '$BK_STORE_CONTAINER' not running" >&2; exit 1; }
    echo "OK: store '$BK_STORE_CONTAINER' running"
    bk_store_admin list-buckets
    ;;
  *)
    echo "usage: $0 up | down | status" >&2; exit 2 ;;
esac
