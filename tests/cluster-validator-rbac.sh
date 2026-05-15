#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTERROLE="$REPO_ROOT/cluster-validator/manifests/clusterrole.yaml"

assert_contains() {
  local expected="$1"
  if ! grep -Fq "$expected" "$CLUSTERROLE"; then
    echo "cluster-validator ClusterRole missing: $expected" >&2
    exit 1
  fi
}

assert_contains "resources: [services, configmaps, endpoints]"
assert_contains "resources: [pods, pods/log, pods/exec]"
assert_contains "resources: [daemonsets, deployments, replicasets]"
assert_contains "verbs: [get, list, create, delete, watch, patch, update]"

echo "All cluster-validator RBAC tests passed."
