#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/network-testing-image.yml"

if [[ ! -f "$WORKFLOW" ]]; then
  echo "missing network-testing-image workflow" >&2
  exit 1
fi

grep -Fq "REGISTRY: ghcr.io" "$WORKFLOW"
# shellcheck disable=SC2016
grep -Fq 'IMAGE_NAME: ${{ github.repository }}/network-testing-image' "$WORKFLOW"
grep -Fq "packages: write" "$WORKFLOW"
grep -Fq "docker/login-action@v3" "$WORKFLOW"
grep -Fq "docker/metadata-action@v5" "$WORKFLOW"
grep -Fq "docker/build-push-action@v6" "$WORKFLOW"
grep -Fq "file: network-testing-image/Containerfile" "$WORKFLOW"
grep -Fq "tags: network-testing-image:test" "$WORKFLOW"
grep -Fq "docker run --rm network-testing-image:test" "$WORKFLOW"
grep -Fq "for cmd in tcpdump ip ss ping tracepath mtr iperf3 rsync curl wget unzip lvs sg_map rclone; do" "$WORKFLOW"
# shellcheck disable=SC2016
grep -Fq 'command -v "$cmd"' "$WORKFLOW"
grep -Fq "push: true" "$WORKFLOW"
grep -Fq "if: github.event_name == 'push'" "$WORKFLOW"
grep -Fq "platforms: linux/amd64,linux/arm64" "$WORKFLOW"
grep -Fq "type=raw,value=latest,enable={{is_default_branch}}" "$WORKFLOW"
