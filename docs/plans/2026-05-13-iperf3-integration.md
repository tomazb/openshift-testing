# iperf3 Metrics Collector — Integration Implementation Plan

**Goal:** Three-layer improvement of iperf3 metric collection: standalone script quality (Layer C), `--deep` flag for pod-side collector and `IPERF_DEEP_METRICS` pass-through (Layer A), and a dedicated `node-metrics` subcommand (Layer B).

**Architecture:** Layer C adds the standalone script to static checks, a smoke test, and a README. Layer A extends `network-validation/lib/iperf3-collector.sh` with a `--deep` flag enabling 10 extra metric streams from `/proc`, then wires `IPERF_DEEP_METRICS=true` to pass `--deep` in all existing iperf3 test invocations. Layer B adds a `node-metrics` subcommand that runs a dedicated iperf3 test with deep metrics on two cluster nodes, saving artifacts in `05-node-metrics/`. Implementation order: C → A (--deep flag) → B → A (pass-through).

**Tech Stack:** Bash, shellcheck, oc (OpenShift CLI), iperf3, `/proc` filesystem

---

## Task 1: Layer C — Add standalone script to static checks

**Files:**
- Modify: `scripts/check-static.sh`
- Modify: `iperf3/iperf3-network-metrics-collector.sh`

**Step 1: Run shellcheck on the standalone script to find issues**

```bash
shellcheck iperf3/iperf3-network-metrics-collector.sh
```

**Step 2: Fix mandatory convention issues**

The following are certain based on the file content:

In `iperf3/iperf3-network-metrics-collector.sh`:
- Line 1: `#!/bin/bash` → `#!/usr/bin/env bash`
- Line 6: `set -euo pipefail` → `set -Eeuo pipefail`

Fix any additional issues shellcheck reports. Common patterns:
- SC2231 (unquoted glob in for loop over `/sys/class/net/$INTERFACE/queues/...`): either quote the variable inside the glob path or add a `# shellcheck disable=SC2231` comment with a brief justification on the line above.
- SC2155 (declare + assign in one `local foo=$(...)` line): split into two lines.

**Step 3: Add to `scripts/check-static.sh`**

In the `bash -n` block (after `bash -n network-validation/lib/results.sh`), add:
```bash
bash -n iperf3/iperf3-network-metrics-collector.sh
```

In the `shellcheck` invocation (after `network-validation/lib/results.sh \`), add:
```text
  iperf3/iperf3-network-metrics-collector.sh \
```

**Step 4: Run check-static.sh and iterate until green**

```bash
bash scripts/check-static.sh
```

Expected: exit 0. Fix any remaining shellcheck findings before continuing.

**Step 5: Commit**

```bash
git add iperf3/iperf3-network-metrics-collector.sh scripts/check-static.sh
git commit -m "chore: add standalone iperf3 collector to static checks"
```

---

## Task 2: Layer C — Smoke test for standalone script

**Files:**
- Create: `tests/iperf3-collector-smoke.sh`

**Step 1: Create the test file**

```bash
#!/usr/bin/env bash
# Smoke test: iperf3/iperf3-network-metrics-collector.sh runs in client role,
# creates expected artifact files, and exits 0.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDALONE="$REPO_ROOT/iperf3/iperf3-network-metrics-collector.sh"

MOCKS_DIR="$(mktemp -d)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCKS_DIR" "$OUT_DIR"' EXIT

# Mock iperf3: client writes valid JSON to stdout; server exits 0.
cat > "$MOCKS_DIR/iperf3" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == "-s" ]] && exit 0; done
cat <<'JSON'
{"start":{},"intervals":[],"end":{"sum_received":{"bits_per_second":10000000000,"bytes":100000000,"seconds":1},"sum_sent":{"retransmits":0}}}
JSON
MOCK
chmod +x "$MOCKS_DIR/iperf3"

# Mock optional commands — just exit 0 so baseline/cleanup don't fail.
for cmd in mpstat ethtool; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKS_DIR/$cmd"
  chmod +x "$MOCKS_DIR/$cmd"
done

# Run: client role, loopback interface (skip auto-detect), 1 s duration.
PATH="$MOCKS_DIR:$PATH" timeout 15 bash "$STANDALONE" \
  -r client -t 127.0.0.1 -i lo -d 1 -o "$OUT_DIR" || true

pass=0; fail=0
check_file() {
  if [[ -f "$OUT_DIR/$1" ]]; then
    echo "PASS: $1 exists"
    (( pass++ )) || true
  else
    echo "FAIL: $1 missing"
    (( fail++ )) || true
  fi
}

check_file "iperf3_client.json"
check_file "00_baseline.txt"
check_file "01_cpu_usage.log"
check_file "09_netdev.log"
check_file "99_posttest.txt"

if (( fail > 0 )); then
  echo "SMOKE TEST FAILED: $fail check(s) failed, $pass passed"
  exit 1
fi
echo "SMOKE TEST PASSED: $pass checks"
```

**Step 2: Run the test directly**

```bash
bash tests/iperf3-collector-smoke.sh
```

Expected: `SMOKE TEST PASSED: 5 checks`

If checks fail, add `set -x` temporarily to the test and re-run to trace what's missing. Common causes:
- `iperf3_client.json` missing: mock iperf3 not found (PATH not prepended correctly)
- `01_cpu_usage.log` missing: script exited before metrics loop ran — look for errors in script output

**Step 3: Run check-static.sh**

```bash
bash scripts/check-static.sh
```

Expected: exit 0.

**Step 4: Commit**

```bash
git add tests/iperf3-collector-smoke.sh
git commit -m "test: smoke test for standalone iperf3 collector"
```

---

## Task 3: Layer C — README for standalone script

**Files:**
- Create: `iperf3/README.md`

**Step 1: Create the README**

```markdown
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
  | bash -s -- -r server
EOF

# Terminal 2 — client node (substitute <server-node-ip> with the node's IP)
oc debug node/<client-node> -- chroot /host bash -s <<'EOF'
curl -sL https://raw.githubusercontent.com/tomazb/openshift-testing/main/iperf3/iperf3-network-metrics-collector.sh \
  | bash -s -- -r client -t <server-node-ip> -d 30 -o /tmp/metrics
EOF
```

Or copy the script in advance to avoid downloading it twice:

```bash
oc debug node/<client-node> -- bash -c \
  'curl -sL https://raw.githubusercontent.com/tomazb/openshift-testing/main/iperf3/iperf3-network-metrics-collector.sh \
   | bash -s -- -r client -t <server-ip> -d 30 -p tcp -o /tmp/metrics'
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
# From a separate terminal while the debug pod is still running:
oc exec <debug-pod-name> -- tar -cf - /tmp/metrics | tar -xf - -C ./local-artifacts/

# Or with oc cp (if the pod has a name):
oc cp <debug-pod-name>:/tmp/metrics ./local-artifacts/
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

**Step 2: Verify the file is tracked by git**

```bash
git status iperf3/README.md
```

Expected: shown as an untracked new file.

**Step 3: Commit**

```bash
git add iperf3/README.md
git commit -m "docs: add README for standalone iperf3 collector"
```

---

## Task 4: Layer A (part 1) — Add `--deep` flag to pod-side iperf3-collector.sh

**Files:**
- Modify: `network-validation/lib/iperf3-collector.sh`

The existing pod-side collector (`network-validation/lib/iperf3-collector.sh`) collects CPU
(`01_cpu_usage.log`) and netdev (`09_netdev.log`). This task adds 10 more streams behind
a `--deep` flag, ported from the standalone script.

**Step 1: Add `DEEP` and `MPSTAT_PID` variables**

After `METRIC_PID=""` (line 17), add:
```bash
DEEP="false"
MPSTAT_PID=""
```

**Step 2: Add `--deep` to `usage()` and `parse_args()`**

In `usage()`, after `  --port PORT           iperf3 server port`, add:
```text
  --deep                Enable extended metric collection (softirqs, sockstat, PSI, mpstat, etc.)
```

In `parse_args()`, add a case before `--help|-h)`:
```bash
      --deep) DEEP="true" ;;
```

**Step 3: Add `start_mpstat_loop()` function**

Add after `command_available()`:
```bash
start_mpstat_loop() {
  [[ "$DEEP" == "true" ]] || return 0
  command_available mpstat || return 0
  local mpstat_file="$LOG_DIR/12_mpstat.log"
  (
    while true; do
      {
        echo "--- TIMESTAMP $(date +%s.%N) ---"
        mpstat -P ALL 1 1 2>/dev/null || true
      } >> "$mpstat_file"
      sleep 4
    done
  ) &
  MPSTAT_PID=$!
}
```

**Step 4: Add `sec` and deep collectors to `collect_continuous_metrics()`**

The existing loop begins with:
```bash
  while true; do
    local ts cur_cpu_line
    ts="$(date +%s.%N)"
```

Change the `local` declaration to also declare `sec`, and derive it from `ts`:
```bash
  while true; do
    local ts cur_cpu_line sec
    ts="$(date +%s.%N)"
    sec="${ts%%.*}"
```

Then, just before `sleep 1` at the bottom of the loop, insert the deep block:
```bash
    if [[ "$DEEP" == "true" ]]; then
      awk -v ts="$ts" '/NET_RX|NET_TX/ {printf "%s,%s", ts, $1; for(i=2;i<=NF;i++) printf ",%s", $i; print ""}' /proc/softirqs >> "$LOG_DIR/03_softirq.log" 2>/dev/null || true
      awk -v ts="$ts" '/^TcpExt:|^IpExt:/ {printf "%s,%s\n", ts, $0}' /proc/net/netstat >> "$LOG_DIR/04_tcpext.log" 2>/dev/null || true
      awk -v ts="$ts" '/^Udp:|^Tcp:/ {printf "%s,%s\n", ts, $0}' /proc/net/snmp >> "$LOG_DIR/05_snmp.log" 2>/dev/null || true
      awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' /proc/net/sockstat >> "$LOG_DIR/06_sockstat.log" 2>/dev/null || true
      awk -v ts="$ts" '/^MemTotal:|^MemFree:|^MemAvailable:|^Buffers:|^Cached:/ {printf "%s,%s,%s\n", ts, $1, $2}' /proc/meminfo >> "$LOG_DIR/07_memory.log" 2>/dev/null || true
      awk -v ts="$ts" '{printf "%s,%s,%s,%s\n", ts, $1, $2, $3}' /proc/loadavg >> "$LOG_DIR/08_loadavg.log" 2>/dev/null || true
      if (( sec % 2 == 0 )); then
        { echo "--- TIMESTAMP $ts ---"; ethtool -S "$INTERFACE" 2>/dev/null || true; } >> "$LOG_DIR/10_ethtool_stats.log"
      fi
      if command_available ss; then
        if [[ "$PROTOCOL" == "udp" ]]; then
          ss -uanmp 2>/dev/null | awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' >> "$LOG_DIR/11_ss.log" || true
        else
          ss -tanmp 2>/dev/null | awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' >> "$LOG_DIR/11_ss.log" || true
        fi
      fi
      if [[ -f /proc/pressure/cpu ]]; then
        awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' /proc/pressure/cpu >> "$LOG_DIR/13_psi.log" 2>/dev/null || true
      fi
    fi
```

**Step 5: Call `start_mpstat_loop` from `run_server()` and `run_client()`**

In both `run_server()` and `run_client()`, after `METRIC_PID=$!`, add:
```bash
  start_mpstat_loop
```

**Step 6: Add `MPSTAT_PID` to `cleanup()`**

After the existing `METRIC_PID` block in `cleanup()`, add:
```bash
  if [[ -n "${MPSTAT_PID:-}" ]]; then
    kill "$MPSTAT_PID" 2>/dev/null || true
    wait "$MPSTAT_PID" 2>/dev/null || true
  fi
```

**Step 7: Run check-static.sh**

```bash
bash scripts/check-static.sh
```

Expected: exit 0.

**Step 8: Commit**

```bash
git add network-validation/lib/iperf3-collector.sh
git commit -m "feat(network-validation): add --deep flag to pod-side iperf3 collector"
```

---

## Task 5: Layer B — `run_node_metrics()` and artifact retrieval update

**Files:**
- Modify: `network-validation/lib/iperf.sh`

**Step 1: Expand `retrieve_collector_artifacts()` to include deep metric files**

The existing `files=(...)` array in `retrieve_collector_artifacts()` ends with `iperf3_server.rc`. Append the deep metric filenames — they are silently skipped when absent (the copy uses `|| true`):

```bash
    03_softirq.log
    04_tcpext.log
    05_snmp.log
    06_sockstat.log
    07_memory.log
    08_loadavg.log
    10_ethtool_stats.log
    11_ss.log
    12_mpstat.log
    13_psi.log
```

**Step 2: Add `run_node_metrics()` function**

Add at the end of `iperf.sh`, after `all_actions()`:

```bash
run_node_metrics() {
  init_dirs
  require_cmd oc
  ensure_pods_deployed

  local orig_duration="$IPERF_DURATION"
  local orig_protocol="$IPERF_PROTOCOL"
  local orig_deep="${IPERF_DEEP_METRICS:-false}"
  IPERF_DURATION="$NODE_METRICS_DURATION"
  IPERF_PROTOCOL="$NODE_METRICS_PROTOCOL"
  IPERF_DEEP_METRICS="true"

  local d="$ARTIFACT_DIR/05-node-metrics"
  collect_pod_baseline "iperf3-server" "$d"
  collect_pod_baseline "iperf3-client" "$d"

  local target_ip
  target_ip="$(get_target_ip pod)"
  run_iperf_test "node-metrics" "$target_ip" "$d"

  IPERF_DURATION="$orig_duration"
  IPERF_PROTOCOL="$orig_protocol"
  IPERF_DEEP_METRICS="$orig_deep"
}
```

**Step 3: Add `run_node_metrics` to `all_actions()`**

Change:
```bash
all_actions() {
  preflight
  deploy_pods
  run_cross_node
  ovn_diagnostics
  report
}
```

To:
```bash
all_actions() {
  preflight
  deploy_pods
  run_cross_node
  ovn_diagnostics
  run_node_metrics
  report
}
```

**Step 4: Run check-static.sh**

```bash
bash scripts/check-static.sh
```

Expected: exit 0.

**Step 5: Commit**

```bash
git add network-validation/lib/iperf.sh
git commit -m "feat(network-validation): add run_node_metrics() and expand artifact retrieval"
```

---

## Task 6: Layer B — Wire up `node-metrics` subcommand, menu, and config

**Files:**
- Modify: `network-validation/bin/ocp-network-validate`
- Modify: `network-validation/config/validation.env.example`

**Step 1: Add new defaults in the `# --- Defaults ---` section**

After the existing `IPERF_MAX_RETRANSMITS` default, add:
```bash
NODE_METRICS_DURATION="${NODE_METRICS_DURATION:-120}"
NODE_METRICS_PROTOCOL="${NODE_METRICS_PROTOCOL:-tcp}"
IPERF_DEEP_METRICS="${IPERF_DEEP_METRICS:-false}"
```

**Step 2: Add config validation in `validate_config()`**

After the existing `IPERF_MAX_RETRANSMITS` validation, add:
```bash
  validate_positive_integer NODE_METRICS_DURATION "$NODE_METRICS_DURATION"
  case "$NODE_METRICS_PROTOCOL" in
    udp|tcp) ;;
    *) config_error "NODE_METRICS_PROTOCOL must be udp or tcp" ;;
  esac
  case "$IPERF_DEEP_METRICS" in
    true|false) ;;
    *) config_error "IPERF_DEEP_METRICS must be true or false" ;;
  esac
```

**Step 3: Update `usage()`**

In the Actions list in `usage()`, add after `pod-to-service`:
```text
  node-metrics         Run dedicated node-level metrics collection (deep, 120 s by default)
```

**Step 4: Add menu entry**

In the `cat <<MENU` heredoc, add after ` 12) Show artifact paths`:
```text
 13) Run node-level metrics collection
```

In the `case "$choice" in` block, add after `12) show_paths ;;`:
```bash
      13) run_node_metrics ;;
```

**Step 5: Add to the `case "$ACTION"` dispatch**

After `pod-to-service) run_pod_to_service ;;`, add:
```bash
  node-metrics) run_node_metrics ;;
```

**Step 6: Update `config/validation.env.example`**

Add a new section at the end:
```bash
# --- Node-level metrics collection ---
# Duration in seconds for the dedicated node-metrics subcommand.
NODE_METRICS_DURATION="120"
# Protocol for the dedicated node-metrics run.
NODE_METRICS_PROTOCOL="tcp"

# --- Extended metrics (opt-in) ---
# Set to "true" to enable extended metric collection in ALL iperf3 tests.
# Adds softirqs, TCP/UDP counters, sockstat, PSI, mpstat, and ethtool stats
# to every test run. No verdict impact — extra files are for manual inspection.
IPERF_DEEP_METRICS="false"
```

**Step 7: Run check-static.sh**

```bash
bash scripts/check-static.sh
```

Expected: exit 0.

**Step 8: Commit**

```bash
git add network-validation/bin/ocp-network-validate network-validation/config/validation.env.example
git commit -m "feat(network-validation): add node-metrics subcommand, menu entry, and config"
```

---

## Task 7: Layer A (part 2) — Pass `--deep` in `run_iperf_test()` when `IPERF_DEEP_METRICS=true`

**Files:**
- Modify: `network-validation/lib/iperf.sh`

**Step 1: Build a `collector_extra_args` array in `run_iperf_test()`**

At the top of `run_iperf_test()`, after the `local` declarations, add:
```bash
  local collector_extra_args=()
  [[ "${IPERF_DEEP_METRICS:-false}" == "true" ]] && collector_extra_args+=(--deep)
```

**Step 2: Append `"${collector_extra_args[@]}"` to both collector invocations**

In the server invocation, change the last `--output "$server_remote_dir" \` line to:
```bash
      --output "$server_remote_dir" \
      "${collector_extra_args[@]}" \
```

In the client invocation, change `--output "$client_remote_dir" \` to:
```bash
      --output "$client_remote_dir" \
      "${collector_extra_args[@]}" \
```

Both invocations redirect stdout/stderr after the collector args, so the array expansion lands before the redirections.

If the array is empty (default), bash expands `"${collector_extra_args[@]}"` to nothing — no extra argument is passed.

**Step 3: Run check-static.sh**

```bash
bash scripts/check-static.sh
```

Expected: exit 0.

**Step 4: Commit**

```bash
git add network-validation/lib/iperf.sh
git commit -m "feat(network-validation): pass --deep to collectors when IPERF_DEEP_METRICS=true"
```

---

## Task 8: Final verification

**Step 1: Full static check**

```bash
bash scripts/check-static.sh
```

Expected: exit 0.

**Step 2: Verify subcommand appears in usage**

```bash
bash network-validation/bin/ocp-network-validate --help 2>&1 | grep node-metrics
```

Expected: one line showing `node-metrics` with its description.

**Step 3: Verify config validation catches bad `IPERF_DEEP_METRICS`**

```bash
IPERF_DEEP_METRICS=bad bash network-validation/bin/ocp-network-validate --help 2>&1 | grep -i error
```

Expected: `ERROR: Invalid config: IPERF_DEEP_METRICS must be true or false`

**Step 4: Verify config validation catches bad `NODE_METRICS_DURATION`**

```bash
NODE_METRICS_DURATION=0 bash network-validation/bin/ocp-network-validate --help 2>&1 | grep -i error
```

Expected: `ERROR: Invalid config: NODE_METRICS_DURATION must be a positive integer`

**Step 5: Commit any remaining cleanup, or confirm nothing to commit**

```bash
git status
```
