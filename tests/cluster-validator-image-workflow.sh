#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/cluster-validator-image.yml"

if [[ ! -f "$WORKFLOW" ]]; then
  echo "missing cluster-validator-image workflow" >&2
  exit 1
fi

assert_contains() {
  local expected="$1"
  if ! grep -Fq "$expected" "$WORKFLOW"; then
    echo "workflow expectation missing in $WORKFLOW: $expected" >&2
    exit 1
  fi
}

assert_contains "REGISTRY: ghcr.io"
# shellcheck disable=SC2016
assert_contains 'IMAGE_NAME: ${{ github.repository }}/cluster-validator'
assert_contains "docker/build-push-action@v7"
assert_contains "file: cluster-validator/Containerfile"
assert_contains "tags: cluster-validator:test"
assert_contains "docker run --rm --entrypoint bash cluster-validator:test -Eeuo pipefail -c"
assert_contains "command -v validator"
assert_contains "test -f /opt/openshift-testing/dns-validation/bin/ocp-dns-validate"
assert_contains "test -f /opt/openshift-testing/network-validation/bin/ocp-network-validate"
assert_contains "test -d /artifacts"
assert_contains "test -d /config"
assert_contains "push: true"
assert_contains "if: github.event_name == 'push'"
assert_contains "platforms: linux/amd64,linux/arm64"
