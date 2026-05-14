# iperf3 network metrics collector

Standalone iperf3 runner and system metric collector for OpenShift/CoreOS nodes.
Runs inside a container without privileged access — all metrics are read from `/proc`
or standard commands available in the node's chroot.

## Usage

### `oc debug node/` (recommended for ad hoc inspection)

Start the server first, then the client on a different node:

```bash
# Terminal 1 — server node
oc debug node/<server-node> -- chroot /host bash -s <<'EOF'
curl -sL https://raw.githubusercontent.com/tomazb/openshift-testing/main/iperf3/iperf3-network-metrics-collector.sh \
  | bash -s -- -r server -o /tmp/iperf3-server
EOF

# Terminal 2 — client node (substitute <server-node-ip> with the node's IP)
oc debug node/<client-node> -- chroot /host bash -s <<'EOF'
curl -sL https://raw.githubusercontent.com/tomazb/openshift-testing/main/iperf3/iperf3-network-metrics-collector.sh \
  | bash -s -- -r client -t <server-node-ip> -d 30 -o /tmp/iperf3-client
EOF
```

Single-command alternative:

```bash
oc debug node/<client-node> -- chroot /host bash -c \
  'curl -sL https://raw.githubusercontent.com/tomazb/openshift-testing/main/iperf3/iperf3-network-metrics-collector.sh \
   | bash -s -- -r client -t <server-ip> -d 30 -p tcp -o /tmp/iperf3-client'
```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `-r, --role` | *(required)* | `client` or `server` |
| `-t, --target` | | Server IP address (client role only) |
| `-d, --duration` | `30` | Test duration in seconds |
| `-p, --protocol` | `udp` | `tcp` or `udp` |
| `-b, --bandwidth` | `0` | iperf3 bandwidth target (e.g. `10G`; `0` = unlimited) |
| `-l, --packet-size` | `8972` | UDP payload bytes (8972 = jumbo frames for 9000 MTU) |
| `-w, --window` | `256M` | iperf3 socket buffer |
| `-P, --parallel` | `1` | Parallel streams |
| `-i, --interface` | *(auto)* | Network interface to monitor |
| `-o, --output` | `./iperf3-metrics-<role>-<ts>` | Output directory |
| `--port` | `5201` | iperf3 server port |

## Artifact files

| File | Contents |
|------|----------|
| `00_baseline.txt` | System state snapshot before test (hostname, kernel, ethtool, sysctls…) |
| `01_cpu_usage.log` | Per-second CPU delta (user/sys/iowait/idle) |
| `02_interrupts.log` | Interface interrupt counts (continuous) |
| `03_softirqs.log` | NET_RX / NET_TX softirq counters |
| `04_netstat.log` | TCP extended counters (`TcpExt`/`IpExt`) |
| `05_snmp.log` | TCP/UDP SNMP counters |
| `06_sockstat.log` | Socket statistics (`/proc/net/sockstat`) |
| `07_memory.log` | Memory info (`MemTotal`, `MemFree`, `MemAvailable`…) |
| `08_loadavg.log` | Load averages |
| `09_netdev.log` | Interface byte/packet/drop counters (continuous) |
| `10_ethtool_S.log` | NIC hardware counters via `ethtool -S` (every 2 s) |
| `11_ss_sockets.log` | Socket buffer sizes during test |
| `12_mpstat.log` | Per-CPU statistics via `mpstat` (every ~5 s) |
| `13_pressure.log` | PSI pressure (`/proc/pressure/cpu`) if available |
| `99_posttest.txt` | System state after test (interface counters, dmesg tail…) |
| `iperf3_<role>.json` | iperf3 structured output |

## Retrieving artifacts from the debug pod

```bash
# From a separate terminal while the debug pod is still running.
# The script runs inside `chroot /host`, so `-o /tmp/iperf3-*` is visible
# as `/host/tmp/iperf3-*` from outside the chroot (inside the debug pod).
oc exec <debug-pod-name> -- tar -cf - /host/tmp/iperf3-client | tar -xf - -C ./local-artifacts/
oc exec <debug-pod-name> -- tar -cf - /host/tmp/iperf3-server | tar -xf - -C ./local-artifacts/

# Or with oc cp (if the pod has a name):
oc cp <debug-pod-name>:/host/tmp/iperf3-client ./local-artifacts/
oc cp <debug-pod-name>:/host/tmp/iperf3-server ./local-artifacts/
```

## Quick analysis after retrieval

```bash
# Packet drops during test (rx_drop = col 5, tx_drop = col 10):
awk -F',' 'NR>1 {print $1, $5, $10}' local-artifacts/09_netdev.log

# Did softirqs saturate one CPU?
tail -5 local-artifacts/03_softirqs.log

# iperf3 summary:
jq '.end' local-artifacts/iperf3_client.json

# UDP kernel drops (InErrors, RcvbufErrors):
awk -F',' '/Udp:/ {print}' local-artifacts/05_snmp.log | tail -4
```

## Requirements

- `iperf3`
- Standard Linux tools: `ip`, `awk`, `grep`, `date`
- Optional (gracefully skipped if absent): `ethtool`, `ss`, `mpstat`, `conntrack`, `lscpu`
