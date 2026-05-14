#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/cluster-validator-image.yml"

if [[ ! -f "$WORKFLOW" ]]; then
  echo "missing cluster-validator-image workflow" >&2
  exit 1
fi

grep -Fq "REGISTRY: ghcr.io" "$WORKFLOW"
# shellcheck disable=SC2016
grep -Fq 'IMAGE_NAME: ${{ github.repository }}/cluster-validator' "$WORKFLOW"
grep -Fq "docker/build-push-action@v7" "$WORKFLOW"
grep -Fq "file: cluster-validator/Containerfile" "$WORKFLOW"
grep -Fq "tags: cluster-validator:test" "$WORKFLOW"
grep -Fq "docker run --rm --entrypoint bash cluster-validator:test -euxo pipefail -c" "$WORKFLOW"
grep -Fq "command -v validator" "$WORKFLOW"
grep -Fq "test -f /opt/openshift-testing/dns-validation/bin/ocp-dns-validate" "$WORKFLOW"
grep -Fq "test -f /opt/openshift-testing/network-validation/bin/ocp-network-validate" "$WORKFLOW"
grep -Fq "test -d /artifacts" "$WORKFLOW"
grep -Fq "test -d /config" "$WORKFLOW"
grep -Fq "push: true" "$WORKFLOW"
grep -Fq "if: github.event_name == 'push'" "$WORKFLOW"
grep -Fq "platforms: linux/amd64,linux/arm64" "$WORKFLOW"
