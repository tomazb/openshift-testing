#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_DIR="$REPO_ROOT/cluster-validator/manifests"
CLUSTERROLE="$MANIFEST_DIR/clusterrole.yaml"

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -Fq "$expected" "$file"; then
    echo "missing in $file: $expected" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    echo "unexpected in $file: $unexpected" >&2
    exit 1
  fi
}

for file in \
  "$MANIFEST_DIR/namespace-dns-validation.yaml" \
  "$MANIFEST_DIR/namespace-network-validation.yaml" \
  "$MANIFEST_DIR/role-dns-validation.yaml" \
  "$MANIFEST_DIR/rolebinding-dns-validation.yaml" \
  "$MANIFEST_DIR/role-network-validation.yaml" \
  "$MANIFEST_DIR/rolebinding-network-validation.yaml" \
  "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-config-pull-secret.yaml" \
  "$MANIFEST_DIR/role-openshift-dns-read.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-dns-read.yaml" \
  "$MANIFEST_DIR/role-openshift-dns-operator-read.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-dns-operator-read.yaml" \
  "$MANIFEST_DIR/role-openshift-console-read.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-console-read.yaml" \
  "$MANIFEST_DIR/role-openshift-ovn-kubernetes-read.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-ovn-kubernetes-read.yaml"; do
  [[ -f "$file" ]] || { echo "missing manifest: $file" >&2; exit 1; }
done

assert_contains "$CLUSTERROLE" "resources: [nodes]"
assert_contains "$CLUSTERROLE" "resources: [namespaces]"
assert_contains "$CLUSTERROLE" "verbs: [get, list]"
assert_contains "$CLUSTERROLE" "resources: [clusterversions, clusteroperators, networks, ingresses]"
assert_contains "$CLUSTERROLE" "resources: [dnses, networks]"
assert_not_contains "$CLUSTERROLE" "verbs: [get, list, create, delete"
assert_not_contains "$CLUSTERROLE" "resources: [pods, pods/log, pods/exec]"
assert_not_contains "$CLUSTERROLE" "resources: [services, configmaps, endpoints]"
assert_not_contains "$CLUSTERROLE" "resources: [daemonsets, deployments, replicasets]"

assert_contains "$MANIFEST_DIR/namespace-dns-validation.yaml" "name: dns-validation"
assert_contains "$MANIFEST_DIR/namespace-network-validation.yaml" "name: network-validation"

assert_contains "$MANIFEST_DIR/role-dns-validation.yaml" "namespace: dns-validation"
assert_contains "$MANIFEST_DIR/role-dns-validation.yaml" "resources: [pods, pods/log, pods/exec]"
assert_contains "$MANIFEST_DIR/role-dns-validation.yaml" "resources: [services, configmaps, endpoints]"
assert_contains "$MANIFEST_DIR/role-dns-validation.yaml" "resources: [daemonsets, deployments, replicasets]"

assert_contains "$MANIFEST_DIR/role-network-validation.yaml" "namespace: network-validation"
assert_contains "$MANIFEST_DIR/role-network-validation.yaml" "resources: [pods, pods/log, pods/exec]"
assert_contains "$MANIFEST_DIR/role-network-validation.yaml" "resources: [services, configmaps, endpoints]"
assert_contains "$MANIFEST_DIR/role-network-validation.yaml" "resources: [daemonsets, deployments, replicasets]"

assert_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "namespace: openshift-config"
assert_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "resources: [secrets]"
assert_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "resourceNames: [pull-secret]"
assert_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "verbs: [get]"
assert_not_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "list"
assert_not_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "watch"

for binding in "$MANIFEST_DIR"/rolebinding-*.yaml; do
  assert_contains "$binding" "kind: RoleBinding"
  assert_contains "$binding" "name: cluster-validator"
  assert_contains "$binding" "namespace: cluster-validator"
done

echo "All cluster-validator RBAC tests passed."
