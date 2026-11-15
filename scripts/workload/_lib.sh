#!/bin/sh
# Phase 5.1c-1: shared helpers for the lab's workload tests. Sourced
# after scripts/lab/_lib.sh (needs pkubectl).
#
# The tests send traffic and probe the network from a dedicated, pinned
# client image - never from the workload's own image, which may have no
# shell at all (apps/smoke is distroless). curlimages/curl ships sh,
# curl and nslookup and runs as a non-root user; pinned by its
# multi-platform index digest (kind on arm64, CI on amd64).
TEST_CLIENT_IMAGE_TAG="8.23.0"
TEST_CLIENT_IMAGE_DIGEST="sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93"
TEST_CLIENT_IMAGE="docker.io/curlimages/curl:${TEST_CLIENT_IMAGE_TAG}@${TEST_CLIENT_IMAGE_DIGEST}"

# netns_probe <namespace> <pod> <name> <shell script> [timeout-seconds]
# Runs the script in an ephemeral container (test client image,
# restricted profile) that shares <pod>'s network namespace, so the
# pod's NetworkPolicy applies to it exactly as to the workload itself,
# and prints the container's output. Ephemeral containers cannot be
# removed; a terminated one stays in the pod's status until the pod is
# replaced (it holds no resources).
netns_probe() {
  np_ns="$1"; np_pod="$2"; np_name="$3"; np_script="$4"; np_timeout="${5:-60}"
  pkubectl -n "$np_ns" debug "pod/$np_pod" --image="$TEST_CLIENT_IMAGE" \
    --profile=restricted --container="$np_name" --quiet -- sh -c "$np_script" >/dev/null 2>&1 || return 1
  np_i=0
  while [ "$np_i" -lt "$np_timeout" ]; do
    np_state="$(pkubectl -n "$np_ns" get pod "$np_pod" \
      -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$np_name\")].state.terminated.reason}" 2>/dev/null || true)"
    [ -n "$np_state" ] && break
    sleep 2; np_i=$((np_i + 2))
  done
  pkubectl -n "$np_ns" logs "pod/$np_pod" -c "$np_name" 2>/dev/null
}
