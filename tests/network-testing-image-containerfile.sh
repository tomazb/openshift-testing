#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINERFILE="$REPO_ROOT/network-testing-image/Containerfile"

grep -Fxq "FROM registry.access.redhat.com/ubi9/ubi:9.7" "$CONTAINERFILE"
grep -Fq 'org.opencontainers.image.source="https://github.com/tomazb/openshift-testing"' "$CONTAINERFILE"
grep -Eq '^[[:space:]]+unzip[[:space:]]+\\$' "$CONTAINERFILE"

for package in \
  bash-completion \
  bind-utils \
  httpd-tools \
  jq \
  nmap \
  ethtool; do
  if ! grep -Eq "^[[:space:]]+${package}[[:space:]]+\\\\$" "$CONTAINERFILE"; then
    echo "missing expected package in Containerfile: $package" >&2
    exit 1
  fi
done

for deferred_package in whois netperf qperf wireshark-cli s3fs-fuse fio; do
  if grep -Eq "^[[:space:]]+${deferred_package}[[:space:]]+\\\\$" "$CONTAINERFILE"; then
    echo "deferred package must not be installed from UBI package list: $deferred_package" >&2
    exit 1
  fi
done

if grep -Eq '^[[:space:]]+curl[[:space:]]+\\$' "$CONTAINERFILE"; then
  echo "Containerfile must rely on curl-minimal from the UBI base image instead of installing curl" >&2
  exit 1
fi

grep -Fxq "ARG OPENSHIFT_CLIENT_VERSION=4.19.12" "$CONTAINERFILE"
grep -Fxq "ARG STEP_CLI_VERSION=0.30.2" "$CONTAINERFILE"
grep -Fxq "ARG YQ_VERSION=v4.53.2" "$CONTAINERFILE"

grep -Fq 'openshift-client-linux-${OC_ARCH}-rhel9-${OPENSHIFT_CLIENT_VERSION}.tar.gz' "$CONTAINERFILE"
grep -Fq 'https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_CLIENT_VERSION}' "$CONTAINERFILE"
grep -Fq 'https://github.com/smallstep/cli/releases/download/v${STEP_CLI_VERSION}' "$CONTAINERFILE"
grep -Fq 'https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}' "$CONTAINERFILE"

for completion in oc kubectl rclone step yq; do
  grep -Fq "/etc/bash_completion.d/$completion" "$CONTAINERFILE"
done

grep -Eq '^ARG RCLONE_VERSION=v[0-9]+\.[0-9]+\.[0-9]+$' "$CONTAINERFILE"

if grep -Fq "rclone-current" "$CONTAINERFILE"; then
  echo "rclone download must be pinned instead of using rclone-current" >&2
  exit 1
fi

grep -Fq 'SHA256SUMS' "$CONTAINERFILE"
grep -Fq 'sha256sum -c --ignore-missing' "$CONTAINERFILE"
grep -Fq 'awk -v file="${YQ_TARBALL}"' "$CONTAINERFILE"
grep -Fq 'test -s yq.sha256' "$CONTAINERFILE"
# shellcheck disable=SC2016
grep -Fq 'case "${TARGETARCH:-$(uname -m)}" in' "$CONTAINERFILE"
grep -Fq 'Unsupported architecture' "$CONTAINERFILE"
