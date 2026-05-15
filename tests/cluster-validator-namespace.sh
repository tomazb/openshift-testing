#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="cluster-validator"

assert_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq "$expected" "$file"; then
    echo "missing expected namespace reference in $file: $expected" >&2
    exit 1
  fi
}

if grep -R -n -E '^[[:space:]]*name: openshift-' \
  "$REPO_ROOT/cluster-validator/manifests/namespace.yaml" \
  "$REPO_ROOT/cluster-validator/manifests/namespace-dns-validation.yaml" \
  "$REPO_ROOT/cluster-validator/manifests/namespace-network-validation.yaml" \
  >/tmp/cluster-validator-openshift-namespace.txt; then
  cat /tmp/cluster-validator-openshift-namespace.txt >&2
  echo "cluster-validator must not create reserved openshift-* namespaces" >&2
  exit 1
fi

assert_contains "$REPO_ROOT/cluster-validator/manifests/namespace.yaml" "  name: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/namespace-dns-validation.yaml" "  name: dns-validation"
assert_contains "$REPO_ROOT/cluster-validator/manifests/namespace-network-validation.yaml" "  name: network-validation"
assert_contains "$REPO_ROOT/cluster-validator/manifests/serviceaccount.yaml" "  namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/clusterrolebinding.yaml" "    namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/job-dns.yaml" "  namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/job-network.yaml" "  namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/configmap-dns-example.yaml" "  namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/configmap-network-example.yaml" "  namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/README.md" "namespace-dns-validation.yaml"
assert_contains "$REPO_ROOT/cluster-validator/README.md" "role-openshift-config-pull-secret.yaml"
assert_contains "$REPO_ROOT/cluster-validator/manifests/configmap-dns-example.yaml" "openshift-config/pull-secret"

echo "All cluster-validator namespace tests passed."
