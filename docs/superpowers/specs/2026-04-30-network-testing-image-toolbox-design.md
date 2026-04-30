# Network Testing Image Toolbox Design

Date: 2026-04-30

## Context

The `network-testing-image/` directory defines a UBI9-based helper image for OpenShift network and storage testing. It currently includes core network tools, `iperf3`, `rsync`, pinned `rclone`, and storage utilities. GitHub Actions builds the image, smoke-tests command availability, and publishes it to GitHub Container Registry from `main`.

The next improvement should turn this image into a broader OpenShift and Kubernetes diagnostics toolbox while keeping package sourcing explicit and testable.

## Goals

Expand the image with tools that help troubleshoot cluster connectivity, DNS, routing, packet capture, object storage, file transfer, TLS, HTTP benchmarking, and storage performance.

The image should include:

- OpenShift and Kubernetes clients: `oc`, `kubectl`.
- Shell ergonomics: `bash-completion` and completion support for the major interactive tools.
- DNS and identity lookup tools: `bind-utils`, `whois`.
- Network benchmarking tools: `iperf3`, `netperf`, `qperf`, `ab`.
- Transfer and object storage tools: `rsync`, `rclone`, `s3fs`.
- Data tools: `jq`, `yq`.
- Network inspection tools: `nmap`, `tshark`, `ethtool`, `arping`, existing route and ping tools.
- TLS and certificate tooling: `step-cli`.
- Storage performance tooling: `fio`.

The final image should remain usable from an interactive `bash` session in a troubleshooting pod.

## Non-Goals

This change does not create a custom troubleshooting entrypoint, wrapper CLI, or operator. It should not change the image publishing flow beyond extending smoke tests for the added capabilities.

This change should not add unpinned external binaries. If a requested tool cannot be installed from the configured UBI/RHEL repositories or through a pinned, checksum-verified upstream artifact, it should be deferred rather than added through a weak supply-chain path.

## Package Sourcing

Prefer packages from UBI/RHEL repositories whenever available. Repository packages should be installed in the existing `dnf install` layer and covered by command-presence smoke tests.

External downloads are acceptable only when all of these are true:

- The version is pinned with an `ARG`.
- The artifact source is official for the project.
- The build verifies a checksum or equivalent release integrity metadata.
- The tool works for both `linux/amd64` and `linux/arm64`, or the unsupported architecture is rejected clearly.
- The smoke test verifies the installed version.

The existing pinned `rclone` install is the local pattern for external binaries. `oc`, `kubectl`, `step-cli`, and `yq` may need the same treatment depending on package availability.

`netperf`, `qperf`, `s3fs`, and `tshark` should be added from packages if available in the configured repositories. If they are not available without enabling broader repositories, record them as deferred with the reason.

## Completion Support

Install `bash-completion` and configure interactive shells to load completions from `/etc/bash_completion.d`.

The image should install or generate completions for:

- `oc`
- `kubectl`
- `rclone`
- `rsync`, `iperf3`, and other packaged tools when their packages provide completion files

Generated completion files should be installed under `/etc/bash_completion.d`. The implementation should avoid network access at runtime; all completion generation happens at image build time.

## Tool Categories

### Cluster Clients

Add `oc` and `kubectl` so the same pod can inspect OpenShift and Kubernetes resources without relying on host tooling. These clients should be version-pinned if downloaded externally.

### DNS, HTTP, and TLS

Add `bind-utils`, `whois`, `httpd-tools` for `ab`, and `step-cli`. These cover DNS queries, registration lookups, HTTP load checks, and certificate/TLS inspection.

### Network Diagnostics

Keep existing route, ping, trace, `mtr`, `tcpdump`, and `iperf3` tools. Add `nmap`, `tshark`, `ethtool`, `arping`, `netperf`, and `qperf` when available through acceptable sources.

### Transfer and Object Storage

Keep `rsync` and pinned `rclone`. Add `s3fs` for S3-compatible mount testing. `s3fs` depends on FUSE behavior in the runtime environment, so documentation should make clear that using it may require pod privileges, device access, or security context changes outside the image itself.

### Storage Performance

Add `fio` for block and filesystem performance testing. It complements `rclone`, `rsync`, and `s3fs` by testing local or mounted storage paths inside the troubleshooting pod.

### Data Processing

Add `jq` and `yq` for working with JSON and YAML output from `oc`, `kubectl`, and other tools.

## Testing

Extend the existing GitHub Actions smoke test to check:

- Every expected command is present.
- Pinned external tools report the expected versions.
- Key generated completion files exist.
- An interactive shell can source bash completion without errors.

The static Containerfile test should also check the package list or explicit install blocks for important tools such as `bash-completion`, `s3fs`, `fio`, `oc`, `kubectl`, `jq`, `yq`, and `nmap`.

Smoke tests should avoid privileged operations, packet captures, mounts, or real network benchmarks. They should verify installation integrity, not exercise every runtime use case.

## Documentation

Update the README network-testing-image section with a concise summary of the expanded toolbox and note that some tools, especially `s3fs`, packet capture, and low-level network inspection, may require additional Kubernetes security context permissions.

## Implementation Discovery

During implementation, confirm package availability from the actual build environment. These checks decide how each requested tool is sourced; they do not change the approved scope.

- Is `s3fs-fuse` available from configured UBI/RHEL repositories?
- Are `netperf` and `qperf` available without enabling unsuitable repositories?
- Is `wireshark-cli` packaged under that name, or should the image install the package that provides `tshark`?
- Should `oc` and `kubectl` be downloaded from OpenShift mirror artifacts, Kubernetes release artifacts, or installed from packages if available?
- Is `step-cli` available from package repositories, or should it use a pinned upstream release?

If any requested tool requires a weak or unstable source, defer that specific tool with a documented reason and keep the rest of the toolbox moving.
