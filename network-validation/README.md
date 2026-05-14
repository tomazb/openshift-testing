# Network validation

Automated iperf3-based network throughput validation for OpenShift clusters with CoreOS nodes.

Deploys iperf3 server and client pods via `oc`, runs topology-aware tests (cross-node, same-node, host-network, pod-to-service), mounts a pod-side collector for server and client artifacts, captures OVN-Kubernetes diagnostics, runs optional deep node-level metrics, and produces a structured markdown report with `Accepted` / `Accepted with risks` / `Blocked` verdicts.

## Prerequisites

- `oc` CLI authenticated to an OpenShift cluster
- `jq` (for result parsing)
- The `network-testing-image` available in GHCR (default) or a custom image with iperf3

## Quick start

```bash
# Interactive menu
bash bin/ocp-network-validate menu

# Run recommended TCP sequence
# preflight → deploy → cross-node → same-node → host-network → pod-to-service
# → OVN diagnostics → node-metrics → report
bash bin/ocp-network-validate --yes all

# Run with custom config
cp config/validation.env.example config/validation.env
# Edit config/validation.env as needed
bash bin/ocp-network-validate --config config/validation.env all
```

## Actions

| Action | Description |
|---|---|
| `init` | Check local tools and create artifact directories |
| `preflight` | Capture cluster version, network type, MTU, CIDRs, operator health |
| `deploy` | Deploy iperf3 server and client pods on selected nodes |
| `cross-node` | Run cross-node pod network test (default scenario) |
| `same-node` | Run same-node pod network test |
| `host-network` | Run host-network test (bypasses overlay) |
| `pod-to-service` | Run pod-to-service test via ClusterIP |
| `node-metrics` | Run a dedicated deep metrics collection test |
| `ovn-diagnostics` | Capture OVN-Kubernetes logs, DB state, tunnel stats |
| `report` | Generate markdown report with verdict |
| `cleanup` | Delete validation namespace |
| `all` | Run the full recommended topology and diagnostics sequence |

## Configuration

See `config/validation.env.example` for all available settings. Key options:

- `IPERF_IMAGE` — container image for pods (default: `ghcr.io/tomazb/openshift-testing/network-testing-image:latest`)
- `IPERF_SERVER_NODE` / `IPERF_CLIENT_NODE` — pin pods to specific nodes (default: auto-select workers)
- `IPERF_SERVER_ADDRESS` — optional address override for the client target
- `IPERF_HOST_NETWORK` — use `hostNetwork: true` (default: `false`)
- `IPERF_PRIVILEGED_MODE` — leave empty to match host-network mode, or set `false` for best-effort restricted host-network metrics
- `IPERF_PROTOCOL` — `tcp` or `udp` (default: `tcp`)
- `IPERF_PACKET_SIZE` — UDP payload size or `auto` from the selected interface MTU
- `IPERF_SOCKET_BUFFER` — optional iperf3 socket buffer/window; empty means use iperf3 defaults
- `IPERF_PARALLEL` — parallel streams as a positive integer or `auto` (default: `auto`)
- `IPERF_INTERFACE` — interface to monitor inside the pod-side collector (`auto` by default)
- `IPERF_DURATION` — test duration in seconds (default: `30`)
- `IPERF_MIN_THROUGHPUT_GBPS` — minimum acceptable throughput for verdict (default: `0` = skip)
- `IPERF_MAX_LOSS_PERCENT` — maximum acceptable packet loss (default: `1`)
- `NODE_METRICS_DURATION` — duration for the dedicated `node-metrics` action (default: `120`)
- `NODE_METRICS_PROTOCOL` — protocol for the dedicated `node-metrics` action (default: `tcp`)
- `IPERF_DEEP_METRICS` — set to `true` to capture extended metrics in every iperf3 test

When `IPERF_PARALLEL=auto`, the tool checks the iperf3 version in the server pod. Versions newer than 3.16 use four parallel streams; older or undetected versions use one stream. Set a concrete value when a validation profile requires a fixed stream count.

TCP is the recommended baseline profile. Use `IPERF_PROTOCOL=udp` when the goal is explicit loss, jitter, and UDP payload-size validation.

## Artifact structure

Each run creates a timestamped directory under `runs/`:

```text
runs/<timestamp>/
  00-preflight/       — cluster and network baseline
  01-cross-node/      — cross-node test results and metrics
    client/           — client collector artifacts and iperf3 JSON
    server/           — server collector artifacts and iperf3 JSON
  02-same-node/       — same-node test results
  03-host-network/    — host-network test results
  04-pod-to-service/  — ClusterIP service path test results
  05-node-metrics/    — dedicated deep metrics test results
  06-ovn-diagnostics/ — OVN logs, DB state, tunnel stats
  07-report/          — markdown report and verdict
```

## Collector

The pod-side collector is mounted from `network-validation/lib/iperf3-collector.sh` into both validation pods. It records iperf3 JSON, per-side return codes, baseline network details, and lightweight CPU/network counter samples for the server and client side of each scenario.

The collector captures extended metrics when `IPERF_DEEP_METRICS=true` or when running the dedicated `node-metrics` action. Extended artifacts include softirqs, TCP/UDP counters, sockstat, memory/load samples, ethtool stats, socket state, mpstat output when available, and CPU pressure data.

## OVN diagnostics

OVN diagnostics discover the current OpenShift pod/container layout before collecting database state and node-level tunnel details. This supports newer releases where `nbdb`/`sbdb` containers may run in `ovnkube-node` pods and node commands may use `ovn-controller` instead of an `ovnkube-node` container.

## Changelog

See `CHANGELOG.md` for network-validation changes.
