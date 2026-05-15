# Changelog

All notable changes to the OpenShift network validation automation are documented here.

This project has not been tagged yet, so entries are grouped by commit date.

## Unreleased

### Changed

- Network-validation artifact directories now use unique ordered prefixes: `05-node-metrics`, `06-ovn-diagnostics`, and `07-report`.
- Local `network-validation/config/validation.env` copies are ignored; `validation.env.example` remains the tracked template.

## 2026-05-14

### Added

- The `all` action now runs the full recommended topology sequence: preflight, deploy, cross-node, same-node, host-network, pod-to-service, node-metrics, OVN diagnostics, and report generation.
- `IPERF_PARALLEL` now accepts `auto`, which detects the pod-side iperf3 version and uses four parallel streams for iperf3 versions newer than 3.16 or one stream for older versions.
- Regression coverage now verifies `IPERF_PARALLEL=auto`, invalid parallel values, the new server-side readiness check, and OCP 4.14+ OVN pod/container layouts.

### Changed

- Default `IPERF_PARALLEL` is now `auto`.
- Default `IPERF_SOCKET_BUFFER` is now empty so iperf3 uses its default socket buffer unless a window is configured explicitly.
- iperf3 readiness checks now inspect the server pod listener with `ss` instead of opening a TCP connection from the client pod, avoiding accidental consumption of the single `iperf3 -1` server session.
- OVN diagnostics now discover where `nbdb`/`sbdb` containers live and which ovnkube-node container can run node-level commands, improving compatibility with newer OpenShift releases.

### Fixed

- Same-node validation now restores the original client-node runtime state before subsequent scenarios run.
- OVN diagnostics no longer assume the OVN DB containers are in `ovnkube-control-plane` or that node commands always run through an `ovnkube-node` container.
