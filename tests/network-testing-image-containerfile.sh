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
  ethtool \
  netperf \
  qperf \
  s3fs-fuse; do
  if ! grep -Eq "^[[:space:]]+${package}[[:space:]]+\\\\$" "$CONTAINERFILE"; then
    echo "missing expected package in Containerfile: $package" >&2
    exit 1
  fi
done

grep -Fq "https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/e/epel-release-9-10.el9.noarch.rpm" "$CONTAINERFILE"

for deferred_package in whois wireshark-cli tshark; do
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
grep -Fxq "ARG FIO_VERSION=3.42" "$CONTAINERFILE"
grep -Fxq "ARG FIO_SHA256=9128d0c81bd7bffab0dd06cbfb755a05ef92f3b8a0b0c61f1b3538df6750f1e0" "$CONTAINERFILE"

grep -Fq "openshift-client-linux-\${OC_ARCH}-rhel9-\${OPENSHIFT_CLIENT_VERSION}.tar.gz" "$CONTAINERFILE"
grep -Fq "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/\${OPENSHIFT_CLIENT_VERSION}" "$CONTAINERFILE"
grep -Fq "https://github.com/smallstep/cli/releases/download/v\${STEP_CLI_VERSION}" "$CONTAINERFILE"
grep -Fq "https://github.com/mikefarah/yq/releases/download/\${YQ_VERSION}" "$CONTAINERFILE"
grep -Fq "https://brick.kernel.dk/snaps/\${FIO_TARBALL}" "$CONTAINERFILE"
grep -Fq "sha256sum -c -" "$CONTAINERFILE"
grep -Fq "./configure --prefix=/usr/local --disable-native" "$CONTAINERFILE"
grep -Fq "COPY --from=fio-builder /tmp/fio-out/usr/local/bin/fio /usr/local/bin/fio" "$CONTAINERFILE"
# libaio-devel is intentionally omitted because it is unavailable in UBI 9
# repositories; fio falls back to POSIX AIO and builds fine without it.
grep -Fq "tar -xzf \"\${YQ_TARBALL}\"" "$CONTAINERFILE"
grep -Fq "install -m 0755 \"./\${YQ_BINARY}\" /usr/local/bin/yq" "$CONTAINERFILE"

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
grep -Fq 'checksums-bsd' "$CONTAINERFILE"
# shellcheck disable=SC2016
grep -Fq 'grep "SHA256 (${YQ_TARBALL})" checksums-bsd' "$CONTAINERFILE"
grep -Fq 'test -s yq.sha256' "$CONTAINERFILE"
grep -Fq 'env -u RCLONE_VERSION rclone genautocomplete bash /etc/bash_completion.d/rclone' "$CONTAINERFILE"
# shellcheck disable=SC2016
grep -Fq 'case "${TARGETARCH:-$(uname -m)}" in' "$CONTAINERFILE"
grep -Fq 'Unsupported architecture' "$CONTAINERFILE"
