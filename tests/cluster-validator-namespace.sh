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

if grep -R -n -E '(^[[:space:]]*(name|namespace): openshift-| -n openshift-)' \
  "$REPO_ROOT/cluster-validator/manifests" \
  "$REPO_ROOT/cluster-validator/README.md" \
  >/tmp/cluster-validator-openshift-namespace.txt; then
  cat /tmp/cluster-validator-openshift-namespace.txt >&2
  echo "cluster-validator manifests and docs must not use reserved openshift-* namespaces" >&2
  exit 1
fi

assert_contains "$REPO_ROOT/cluster-validator/manifests/namespace.yaml" "  name: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/serviceaccount.yaml" "  namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/clusterrolebinding.yaml" "    namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/job-dns.yaml" "  namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/job-network.yaml" "  namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/configmap-dns-example.yaml" "  namespace: $NAMESPACE"
assert_contains "$REPO_ROOT/cluster-validator/manifests/configmap-network-example.yaml" "  namespace: $NAMESPACE"

echo "All cluster-validator namespace tests passed."
