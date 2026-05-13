# iperf3 Metrics Collector: Integration Design

## Problem

The repository contains two overlapping implementations:

- `iperf3/iperf3-network-metrics-collector.sh` — a 468-line standalone collector
  intended for `oc debug node/` use, with 13 metric streams but no tests, no docs,
  and excluded from static checks.
- `network-validation/lib/iperf3-collector.sh` — a pod-side collector used by
  `ocp-network-validate` during iperf3 tests; collects only CPU and netdev counters.

The standalone script has never been tested or documented and the pod-side collector
misses the richer metrics that are readable from inside a container without any
privileged host mounts.

## Goal

Improve both scripts and connect them in three layers, built bottom-up.

---

## Architecture

```
Layer A  ocp-network-validate (all existing tests)
           │  IPERF_DEEP_METRICS=true → pass --deep to iperf3-collector.sh
           │
Layer B  ocp-network-validate node-metrics subcommand
           │  dedicated run using same pod infra, always --deep
           │
Layer C  iperf3/iperf3-network-metrics-collector.sh  (standalone)
           │  shellcheck, bash -n, smoke test, README
```

---

## Layer C — standalone script: quality and docs

**Changes:**
- Add `iperf3/iperf3-network-metrics-collector.sh` to `scripts/check-static.sh`
  (bash `-n` syntax check + shellcheck).
- Add `tests/iperf3-collector-smoke.sh`: mock `iperf3`, `ethtool`, and `mpstat`
  stubs; run the script in client role for 2 s; assert expected output files exist.
- Add `iperf3/README.md` documenting:
  - Purpose and typical use via `oc debug node/`
  - Role/duration/output-dir arguments
  - How to copy artifacts back with `oc cp` or `oc debug --copy-to`

No functional changes to the standalone script in this layer.

---

## Layer B — `node-metrics` subcommand

A dedicated subcommand that runs the richer collector inside pods on two nodes and
captures all 13 metric streams without requiring SSH or `oc debug`.

**Node selection:**
- Auto-picks the same server/client nodes used for cross-node iperf3 tests.
- Overridable via `IPERF_SERVER_NODE` / `IPERF_CLIENT_NODE` environment variables.

**Execution:**
1. Deploys (or reuses) iperf3-server and iperf3-client pods on the selected nodes,
   using the existing pod infra from `network-validation/lib/iperf.sh`.
2. Runs `iperf3-collector.sh --role server --deep …` in the server pod and
   `--role client --deep …` in the client pod concurrently.
3. Retrieves artifacts into:
   - `$ARTIFACT_DIR/05-node-metrics/server/`
   - `$ARTIFACT_DIR/05-node-metrics/client/`
4. Prints a short summary: throughput, protocol, duration, artifact paths.

**Integration points:**
- CLI subcommand: `ocp-network-validate node-metrics`
- Menu entry: `13) Run node-level metrics collection`
- Included in `all_actions()` after `run_pod_to_service` (step 8 of the sequence).

**Config additions (`config/validation.env.example`):**
```shell
NODE_METRICS_DURATION="120"   # collection duration in seconds
NODE_METRICS_PROTOCOL="tcp"   # iperf3 protocol for the dedicated run
```

**Verdict:** `05-node-metrics/` artifacts are informational only;
`results_compute_verdict()` ignores this directory.

---

## Layer A — `--deep` flag for all iperf3 tests (opt-in)

Extends `network-validation/lib/iperf3-collector.sh` with a `--deep` flag that
enables the additional metric streams from the standalone script.

**Additional streams when `--deep` is active** (all readable inside container, no host mounts):

| File | Source |
|------|--------|
| `03_softirq.log` | continuous `/proc/softirqs` snapshots |
| `04_tcpext.log` | `/proc/net/netstat` TcpExt counters |
| `05_snmp.log` | `/proc/net/snmp` |
| `06_sockstat.log` | `/proc/net/sockstat` |
| `07_memory.log` | `/proc/meminfo` |
| `08_loadavg.log` | `/proc/loadavg` |
| `10_ethtool_stats.log` | `ethtool -S` (skipped if interface absent) |
| `11_ss.log` | `ss -tipn` socket snapshot |
| `12_mpstat.log` | `mpstat -P ALL` per-CPU |
| `13_psi.log` | `/proc/pressure/` PSI (skipped if unavailable) |

**Pass-through in `network-validation/lib/iperf.sh`:**
All `oc exec … iperf3-collector.sh` invocations append `--deep` when
`IPERF_DEEP_METRICS=true`.

**Config (`config/validation.env.example`):**
```shell
IPERF_DEEP_METRICS="false"    # set true to capture extended metrics in all iperf3 tests
```

**Verdict / report:** no impact — extra artifacts are for manual inspection only.

---

## Implementation order

1. **Layer C** — quality baseline: shellcheck, smoke test, README
2. **Layer B** — node-metrics subcommand
3. **Layer A** — --deep flag and IPERF_DEEP_METRICS pass-through

Each layer is independently testable and mergeable.
