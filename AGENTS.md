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

## Smoke test rules

### PULL_SECRET_FILE in dns-validation tests

`dns-validation/lib/cluster.sh` exports `require_pull_secret()`, which returns 1
(and writes a sentinel) when `PULL_SECRET_FILE` does not point to an existing file.
The following `dns-validation` actions guard their work behind this check:

- `extract-tests` / `ensure_tests`
- `discover-dns-tests`
- `run-dns-tests`
- `run-single-test`

Any smoke test in `tests/` that invokes one of these actions **must** create a
zero-byte fake pull-secret file and wire it into the config:

```bash
touch "$TMP_DIR/pull-secret.json"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$TMP_DIR/artifacts"
PULL_SECRET_FILE="$TMP_DIR/pull-secret.json"
...
EOF
```

Without this, the guarded function returns early, no output files are written,
and subsequent `grep`/`test` assertions in the smoke test fail with exit code 2
in CI (where `~/pull-secret.json` does not exist).

Tests that invoke actions which do **not** call `require_pull_secret` (`init`,
`preflight`, `report`, `node-sweep`, `dnsperf`, `perf-tests`) do not need the
fake file.

Always validate new dns-validation smoke tests by running them with
`HOME=/nonexistent` to simulate the CI environment:

```bash
env -u PULL_SECRET_FILE HOME=/nonexistent bash tests/your-new-test.sh
```
