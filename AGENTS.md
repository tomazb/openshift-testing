# Agent instructions

## Repository overview

OpenShift cluster validation automation. Each validation tool follows a common pattern:

- `bin/` — main entrypoint script with arg parsing, config loading, text menu
- `lib/` — shared helpers and domain-specific functions
- `config/` — env file with documented defaults
- `runs/` — timestamped artifact directories (gitignored)
- `tests/` — smoke tests using fake `oc` stubs

## Validation tools

### dns-validation

DNS-focused post-install validation: openshift-tests DNS conformance, node-level DNS sweep, dnsperf QPS ladder, and structured verdicts.

Entry point: `dns-validation/bin/ocp-dns-validate`

### network-validation

iperf3-based network throughput validation for OpenShift clusters with CoreOS nodes. Deploys server/client pods, runs topology-aware tests (cross-node, same-node, host-network, pod-to-service), collects system metrics from inside pods, captures OVN-Kubernetes diagnostics, and generates markdown reports with verdicts.

Entry point: `network-validation/bin/ocp-network-validate`

### iperf3 standalone

The repository-root `iperf3/iperf3-network-metrics-collector.sh` script is a standalone host-level metric collector for direct SSH or `oc debug node/` use, kept as a fallback. It is separate from the `network-validation/` tool directories and may not be present in every worktree snapshot.

### network-testing-image

UBI9-based container image with networking, storage, and troubleshooting tools. Used as the pod image by network-validation.

## Conventions

- Shell scripts use `set -Eeuo pipefail` and are checked with shellcheck
- All test scripts live in `tests/` and use fake `oc` stubs for offline testing
- `scripts/check-static.sh` runs syntax checks, shellcheck, and all tests
- Artifact directories use numbered prefixes (00-preflight, 01-cross-node, etc.)
- Verdicts are `Accepted`, `Accepted with risks`, or `Blocked` with artifact-linked reasons
- Config values use `${VAR:-default}` pattern for safe defaults
