# Changelog

All notable changes to the network-testing-image are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Added
- `lsof` installed from UBI9 base repos for socket and file-descriptor inspection.

### Changed
- iperf3 is now built from source (3.21) instead of being installed from the
  UBI9 package repository (which provides only 3.9). Compiled in the
  `tools-builder` stage with `--without-openssl --disable-shared` (produces a
  self-contained binary with no shared library runtime dependency). Version
  pinned with a SHA256-verified tarball from the official esnet/iperf GitHub
  release.

---

## [2026-05-02]

### Added
- fio 3.42 compiled from source in a dedicated `tools-builder` multi-stage build.
  Build uses `--disable-native` for portable amd64/arm64 binaries. `libaio-devel`
  is intentionally omitted (unavailable in UBI9 repos); fio falls back to POSIX
  AIO and builds correctly without it.
- EPEL release RPM pinned to `epel-release-9-10.el9.noarch.rpm`.
- yq checksum verification switched to BSD-format `checksums-bsd` file with
  `grep`/`sed`/`awk` parsing for reliable cross-platform extraction.
- `step` and `yq` download flags standardised to `-fsSL -O`.

---

## [2026-04-30]

### Added
- Initial image based on `registry.access.redhat.com/ubi9/ubi:9.7`.
- Core networking packages from UBI9: `tcpdump`, `iproute`, `iputils`, `mtr`,
  `bind-utils`, `httpd-tools`, `jq`, `nmap`, `ethtool`.
- Storage packages from UBI9: `lvm2`, `sg3_utils`, `rsync`.
- EPEL packages: `netperf`, `qperf`, `s3fs-fuse`.
- Source-verified binary downloads: `rclone` (v1.73.5), `oc`/`kubectl`
  (4.19.12, rhel9 variant), `step-cli` (0.30.2), `yq` (v4.53.2).
- All downloaded binaries verified with SHA256 checksums.
- Bash completion for `oc`, `kubectl`, `rclone`, `step`, `yq` installed under
  `/etc/bash_completion.d/` and sourced via
  `/etc/profile.d/network-testing-completion.sh`.
- Multi-arch build (linux/amd64 + linux/arm64) via GitHub Actions with QEMU.
- Build provenance attestation via `actions/attest-build-provenance`.
- Image published to `ghcr.io/tomazb/openshift-testing/network-testing-image`.

### Not included (deferred)
- `whois` and `wireshark-cli`/`tshark` — unavailable in the configured UBI9
  and EPEL9 repositories.
