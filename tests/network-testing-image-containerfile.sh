#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINERFILE="$REPO_ROOT/network-testing-image/Containerfile"

grep -Fxq "FROM registry.access.redhat.com/ubi9/ubi:9.7" "$CONTAINERFILE"
grep -Fq 'org.opencontainers.image.source="https://github.com/tomazb/openshift-testing"' "$CONTAINERFILE"
grep -Eq '^[[:space:]]+unzip[[:space:]]+\\$' "$CONTAINERFILE"
grep -Eq '^ARG RCLONE_VERSION=v[0-9]+\.[0-9]+\.[0-9]+$' "$CONTAINERFILE"

if grep -Fq "rclone-current" "$CONTAINERFILE"; then
  echo "rclone download must be pinned instead of using rclone-current" >&2
  exit 1
fi

grep -Fq 'SHA256SUMS' "$CONTAINERFILE"
grep -Fq 'sha256sum -c --ignore-missing' "$CONTAINERFILE"
# shellcheck disable=SC2016
grep -Fq 'case "${TARGETARCH:-$(uname -m)}" in' "$CONTAINERFILE"
grep -Fq 'Unsupported architecture' "$CONTAINERFILE"
