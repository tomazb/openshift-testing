#!/usr/bin/env bash
# iperf3-network-metrics-collector.sh
# Automates iperf3 UDP/TCP tests with full system and network metric collection.
# Designed for CoreOS / containerized environments.

set -Eeuo pipefail

# --- Configuration ---
ROLE=""
TARGET=""
DURATION=30
BANDWIDTH="0"
PROTOCOL="udp"
PACKET_SIZE=8972        # UDP payload size; 8972 for jumbo frames (9000 MTU)
SOCKET_BUFFER="256M"    # iperf3 -w value (requires net.core.rmem_max >= this)
PARALLEL=1
OUTPUT_DIR=""
INTERFACE=""
SERVER_PORT=5201

# --- Internal ---
LOG_DIR=""
START_TIME=""
IPERF_PID=""
METRIC_PID=""
MPSTAT_PID=""

usage() {
  cat <<EOF
Usage: $0 -r <client|server> [options]

Required:
  -r, --role          client or server

Client only:
  -t, --target        Server IP address

Common options:
  -d, --duration      Test duration in seconds (default: 30)
  -b, --bandwidth     iperf3 bandwidth target, e.g. 10G or 0 (default: 0)
  -p, --protocol      udp or tcp (default: udp)
  -l, --packet-size   Payload size in bytes (default: 8972)
  -w, --window        Socket buffer size, e.g. 256M (default: 256M)
  -P, --parallel      Parallel streams (default: 1)
  -i, --interface     Network interface to monitor (default: auto)
  -o, --output        Output directory (default: ./iperf3-metrics-<timestamp>)
  --port              iperf3 server port (default: 5201)

Examples:
  Server: $0 -r server
  Client: $0 -r client -t 192.168.1.10 -d 30 -b 0 -p udp
EOF
  exit 1
}

require_value() {
  local option="$1" value="$2"
  if [[ -z "$value" || "$value" == -* ]]; then
    echo "ERROR: $option requires a value" >&2
    usage
  fi
  printf '%s\n' "$value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--role) ROLE="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -t|--target) TARGET="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -d|--duration) DURATION="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -b|--bandwidth) BANDWIDTH="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -p|--protocol) PROTOCOL="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -l|--packet-size) PACKET_SIZE="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -w|--window) SOCKET_BUFFER="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -P|--parallel) PARALLEL="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -i|--interface) INTERFACE="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -o|--output) OUTPUT_DIR="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --port) SERVER_PORT="$(require_value "$1" "${2:-}")"; shift 2 ;;
      -h|--help) usage ;;
      *) echo "Unknown option: $1"; usage ;;
    esac
  done

  if [[ -z "$ROLE" ]]; then
    echo "ERROR: --role is required."
    usage
  fi

  if [[ "$ROLE" == "client" && -z "$TARGET" ]]; then
    echo "ERROR: --target is required for client role."
    usage
  fi
}

detect_interface() {
  if [[ -n "$INTERFACE" ]]; then
    return
  fi
  INTERFACE=$(ip route show default | awk '/default/ {print $5; exit}')
  if [[ -z "$INTERFACE" ]]; then
    echo "ERROR: Could not auto-detect network interface. Use -i."
    exit 1
  fi
  echo "Auto-detected interface: $INTERFACE"
}

setup() {
  START_TIME=$(date +%Y%m%d_%H%M%S)
  if [[ -z "$OUTPUT_DIR" ]]; then
    LOG_DIR="./iperf3-metrics-${ROLE}-${START_TIME}"
  else
    LOG_DIR="$OUTPUT_DIR"
  fi
  mkdir -p "$LOG_DIR"
  echo "Results will be saved to: $LOG_DIR"
}

# Called on SIGINT, SIGTERM, or EXIT — idempotent via sentinel in collect_posttest
cleanup() {
  if [[ -n "${METRIC_PID:-}" ]] || [[ -n "${IPERF_PID:-}" ]]; then
    echo "Cleaning up..."
  fi
  if [[ -n "${IPERF_PID:-}" ]];   then kill "$IPERF_PID"   2>/dev/null || true; fi
  if [[ -n "${METRIC_PID:-}" ]];  then kill "$METRIC_PID"  2>/dev/null || true; fi
  if [[ -n "${MPSTAT_PID:-}" ]];  then kill "$MPSTAT_PID"  2>/dev/null || true; fi
  if [[ -n "${METRIC_PID:-}" ]];  then wait "$METRIC_PID"  2>/dev/null || true; fi
  if [[ -n "${MPSTAT_PID:-}" ]];  then wait "$MPSTAT_PID"  2>/dev/null || true; fi
  collect_posttest 2>/dev/null || true
}

trap cleanup SIGINT SIGTERM EXIT

# --- Baseline snapshot ---
collect_baseline() {
  local f="$LOG_DIR/00_baseline.txt"
  echo "=== Baseline collected at $(date -Iseconds) ===" > "$f"
  {
    echo "--- Hostname / Uptime ---"
    hostname
    uptime
    echo
    echo "--- OS / Kernel ---"
    uname -a
    cat /etc/os-release 2>/dev/null || true
    echo
    echo "--- CPU Info ---"
    nproc
    lscpu | grep -E "Model name|CPU\(s\)|Thread|Core|Socket|NUMA"
    echo
    echo "--- Memory ---"
    free -h
    echo
    echo "--- Interface $INTERFACE ---"
    ip addr show "$INTERFACE"
    echo
    echo "--- Routes ---"
    ip route show
    echo
    echo "--- ethtool basics ---"
    ethtool "$INTERFACE" 2>/dev/null || true
    echo
    echo "--- ethtool ring buffer ---"
    ethtool -g "$INTERFACE" 2>/dev/null || true
    echo
    echo "--- ethtool channels (RSS) ---"
    ethtool -l "$INTERFACE" 2>/dev/null || true
    echo
    echo "--- ethtool coalescence ---"
    ethtool -c "$INTERFACE" 2>/dev/null || true
    echo
    echo "--- ethtool features ---"
    ethtool -k "$INTERFACE" 2>/dev/null || true
    echo
    echo "--- ethtool stats ---"
    ethtool -S "$INTERFACE" 2>/dev/null || true
    echo
    echo "--- Interrupt affinity ---"
    grep "$INTERFACE" /proc/interrupts 2>/dev/null || true
    echo
    echo "--- RPS / XPS ---"
    for q in "/sys/class/net/${INTERFACE}/queues/rx-"*/rps_cpus; do
      echo "$q: $(cat "$q" 2>/dev/null || echo N/A)"
    done
    for q in "/sys/class/net/${INTERFACE}/queues/tx-"*/xps_cpus; do
      echo "$q: $(cat "$q" 2>/dev/null || echo N/A)"
    done
    echo
    echo "--- Sysctl network buffers ---"
    sysctl net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default \
           net.core.netdev_max_backlog net.ipv4.udp_mem 2>/dev/null || true
    echo
    echo "--- Conntrack ---"
    sysctl net.netfilter.nf_conntrack_max 2>/dev/null || true
    conntrack -C 2>/dev/null || true
    echo
    echo "--- Process limits ---"
    cat /proc/self/limits
    echo
    echo "--- iperf3 version ---"
    iperf3 --version 2>/dev/null || true
  } >> "$f"
}

# --- Continuous metrics during test ---
collect_continuous_metrics() {
  local interval=1
  local cpu_file="$LOG_DIR/01_cpu_usage.log"
  local irq_file="$LOG_DIR/02_interrupts.log"
  local softirq_file="$LOG_DIR/03_softirqs.log"
  local netstat_file="$LOG_DIR/04_netstat.log"
  local snmp_file="$LOG_DIR/05_snmp.log"
  local sock_file="$LOG_DIR/06_sockstat.log"
  local mem_file="$LOG_DIR/07_memory.log"
  local load_file="$LOG_DIR/08_loadavg.log"
  local netdev_file="$LOG_DIR/09_netdev.log"
  local ethtool_file="$LOG_DIR/10_ethtool_S.log"
  local ss_file="$LOG_DIR/11_ss_sockets.log"
  local pressure_file="$LOG_DIR/13_pressure.log"

  echo "timestamp,user,system,iowait,idle" > "$cpu_file"
  echo "timestamp,iface,rx_bytes,rx_packets,rx_errs,rx_drop,tx_bytes,tx_packets,tx_errs,tx_drop" > "$netdev_file"
  echo "timestamp,load1,load5,load15" > "$load_file"

  local prev_cpu_line=""

  while true; do
    local ts sec
    ts=$(date +%s.%N)
    sec=$(date +%s)

    # CPU: diff consecutive /proc/stat snapshots for true per-second usage (not boot average)
    local cur_cpu_line
    cur_cpu_line=$(grep '^cpu ' /proc/stat | head -1)
    if [[ -n "$prev_cpu_line" ]]; then
      awk -v ts="$ts" -v cur="$cur_cpu_line" -v prev="$prev_cpu_line" 'BEGIN {
        n = split(cur, c, " ")
        split(prev, p, " ")
        dt = 0
        for (i = 2; i <= n; i++) dt += c[i] - p[i]
        if (dt > 0)
          printf "%s,%.2f,%.2f,%.2f,%.2f\n", ts,
            (c[2]+c[3]-p[2]-p[3])*100/dt,
            (c[4]-p[4])*100/dt,
            (c[6]-p[6])*100/dt,
            (c[5]-p[5])*100/dt
      }' >> "$cpu_file" 2>/dev/null || true
    fi
    prev_cpu_line="$cur_cpu_line"

    # Per-CPU softirqs (NET_RX / NET_TX)
    awk -v ts="$ts" '/NET_RX|NET_TX/ {printf "%s,%s", ts, $1; for(i=2;i<=NF;i++) printf ",%s", $i; print ""}' /proc/softirqs >> "$softirq_file" 2>/dev/null || true

    # Interrupts for our interface
    grep "$INTERFACE" /proc/interrupts | awk -v ts="$ts" '{printf "%s", ts; for(i=1;i<=NF;i++) printf ",%s", $i; print ""}' >> "$irq_file" 2>/dev/null || true

    # /proc/net/dev
    awk -v ts="$ts" -v iface="$INTERFACE" '$1 ~ iface ":" {gsub(":",""); printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", ts, $1, $2, $3, $4, $5, $10, $11, $12, $13}' /proc/net/dev >> "$netdev_file" 2>/dev/null || true

    # /proc/net/netstat — TCP extended counters (TCPRetransFail, TCPTimeouts, etc.)
    awk -v ts="$ts" '/^TcpExt:|^IpExt:/ {printf "%s,%s\n", ts, $0}' /proc/net/netstat >> "$netstat_file" 2>/dev/null || true

    # /proc/net/snmp — UDP/TCP base counters
    awk -v ts="$ts" '/^Udp:|^Tcp:/ {printf "%s,%s\n", ts, $0}' /proc/net/snmp >> "$snmp_file" 2>/dev/null || true

    # /proc/net/sockstat
    awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' /proc/net/sockstat >> "$sock_file" 2>/dev/null || true

    # Memory
    awk -v ts="$ts" '/^MemTotal:|^MemFree:|^MemAvailable:|^Buffers:|^Cached:/ {printf "%s,%s,%s\n", ts, $1, $2}' /proc/meminfo >> "$mem_file" 2>/dev/null || true

    # Load average
    awk -v ts="$ts" '{printf "%s,%s,%s,%s\n", ts, $1, $2, $3}' /proc/loadavg >> "$load_file" 2>/dev/null || true

    # Socket state (only while iperf3 is running)
    if pgrep -x iperf3 >/dev/null 2>&1; then
      if [[ "$PROTOCOL" == "udp" ]]; then
        ss -uanmp 2>/dev/null | grep -E "iperf3|UNCONN|ESTAB" | awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' >> "$ss_file" || true
      else
        ss -tanmp 2>/dev/null | grep -E "iperf3|ESTAB|LISTEN" | awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' >> "$ss_file" || true
      fi
    fi

    # ethtool -S snapshot (every 2s — NIC hardware counters are expensive to read)
    if (( sec % 2 == 0 )); then
      {
        echo "--- TIMESTAMP $ts ---"
        ethtool -S "$INTERFACE" 2>/dev/null || true
      } >> "$ethtool_file"
    fi

    # PSI (if available)
    if [[ -f /proc/pressure/cpu ]]; then
      awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' /proc/pressure/cpu >> "$pressure_file" 2>/dev/null || true
    fi

    sleep "$interval"
  done
}

# mpstat runs in its own loop — `mpstat -P ALL 1 1` blocks ~1s, causing drift if inlined
start_mpstat_loop() {
  if ! command -v mpstat >/dev/null 2>&1; then
    return
  fi
  local mpstat_file="$LOG_DIR/12_mpstat.log"
  (
    while true; do
      {
        echo "--- TIMESTAMP $(date +%s.%N) ---"
        mpstat -P ALL 1 1 2>/dev/null || true
      } >> "$mpstat_file"
      sleep 4  # total cadence ~5s: 4s sleep + ~1s mpstat measurement
    done
  ) &
  MPSTAT_PID=$!
}

# --- Post-test snapshot ---
collect_posttest() {
  # Sentinel prevents double-run from both normal flow and EXIT trap
  [[ -z "${LOG_DIR:-}" ]] && return
  local sentinel="$LOG_DIR/99_posttest.txt"
  [[ -f "$sentinel" ]] && return

  echo "=== Post-test collected at $(date -Iseconds) ===" > "$sentinel"
  {
    echo "--- ethtool stats diff (final) ---"
    ethtool -S "$INTERFACE" 2>/dev/null || true
    echo
    echo "--- Interface counters ---"
    ip -s link show "$INTERFACE"
    echo
    echo "--- Conntrack final ---"
    conntrack -C 2>/dev/null || true
    echo
    echo "--- Kernel messages (last 50) ---"
    dmesg | tail -n 50 || journalctl -k -n 50 || true
    echo
    echo "--- Process stats for iperf3 ---"
    if [[ -n "${IPERF_PID:-}" ]] && [[ -d "/proc/$IPERF_PID" ]]; then
      cat "/proc/$IPERF_PID/status" 2>/dev/null || true
      cat "/proc/$IPERF_PID/schedstat" 2>/dev/null || true
    fi
  } >> "$sentinel"
}

stop_background_jobs() {
  if [[ -n "${METRIC_PID:-}" ]]; then kill "$METRIC_PID" 2>/dev/null || true; fi
  if [[ -n "${MPSTAT_PID:-}" ]]; then kill "$MPSTAT_PID" 2>/dev/null || true; fi
  if [[ -n "${METRIC_PID:-}" ]]; then wait "$METRIC_PID" 2>/dev/null || true; fi
  if [[ -n "${MPSTAT_PID:-}" ]]; then wait "$MPSTAT_PID" 2>/dev/null || true; fi
  METRIC_PID=""
  MPSTAT_PID=""
}

run_server() {
  echo "Starting iperf3 server on port $SERVER_PORT..."

  collect_continuous_metrics &
  METRIC_PID=$!
  start_mpstat_loop

  iperf3 -s -p "$SERVER_PORT" -1 --json > "$LOG_DIR/iperf3_server.json" 2>"$LOG_DIR/iperf3_server.stderr" &
  IPERF_PID=$!

  echo "Server PID: $IPERF_PID, Metrics PID: $METRIC_PID"
  echo "Waiting for client connection..."

  local rc=0
  wait "$IPERF_PID" || rc=$?
  IPERF_PID=""
  echo "$rc" > "$LOG_DIR/iperf3_server.rc"

  stop_background_jobs
  collect_posttest
  echo "Server test complete. Results in $LOG_DIR"
  return "$rc"
}

run_client() {
  echo "Starting iperf3 client to $TARGET:$SERVER_PORT..."

  collect_continuous_metrics &
  METRIC_PID=$!
  start_mpstat_loop

  local iperf_args=(-c "$TARGET" -p "$SERVER_PORT" -t "$DURATION" -w "$SOCKET_BUFFER" -P "$PARALLEL" --json)
  if [[ "$PROTOCOL" == "udp" ]]; then
    iperf_args+=(-u -b "$BANDWIDTH" -l "$PACKET_SIZE")
  fi

  echo "Running: iperf3 ${iperf_args[*]}"
  echo "Test running for ${DURATION}s..."

  # Single iperf3 run — JSON output captured to file; no second connection
  iperf3 "${iperf_args[@]}" > "$LOG_DIR/iperf3_client.json" 2>"$LOG_DIR/iperf3_client.stderr" &
  IPERF_PID=$!

  local rc=0
  wait "$IPERF_PID" || rc=$?
  IPERF_PID=""
  echo "$rc" > "$LOG_DIR/iperf3_client.rc"

  stop_background_jobs
  collect_posttest

  # Quick result display from the single JSON output
  if command -v jq >/dev/null 2>&1 && [[ -s "$LOG_DIR/iperf3_client.json" ]]; then
    echo "--- iperf3 summary ---"
    jq -r '
      .end |
      if .sum_received then
        "  throughput:  \(.sum_received.bits_per_second / 1e9 | . * 100 | round / 100) Gbps",
        "  bytes:       \(.sum_received.bytes)",
        "  retransmits: \(.sum_sent.retransmits // "N/A")"
      else
        "  throughput:  \(.sum.bits_per_second / 1e9 | . * 100 | round / 100) Gbps",
        "  jitter_ms:   \(.sum.jitter_ms // "N/A")",
        "  lost_pct:    \(.sum.lost_percent // "N/A")%",
        "  packets:     \(.sum.packets // "N/A")"
      end
    ' "$LOG_DIR/iperf3_client.json" 2>/dev/null || true
  fi

  echo "Client test complete. Results in $LOG_DIR"
  return "$rc"
}

# --- Main ---
parse_args "$@"
detect_interface
setup
collect_baseline

if [[ "$ROLE" == "server" ]]; then
  run_server
else
  run_client
fi

# --- Quick summary ---
cat <<SUMMARY

========================================
Test Summary
========================================
Role:        $ROLE
Interface:   $INTERFACE
Protocol:    $PROTOCOL
Duration:    ${DURATION}s
Output:      $LOG_DIR

Files:
  iperf3_${ROLE}.json        - iperf3 structured output
  00_baseline.txt            - system state before test
  01_cpu_usage.log           - per-second CPU delta (user/sys/iowait/idle)
  02_interrupts.log          - interface interrupt counts
  03_softirqs.log            - NET_RX / NET_TX softirqs
  04_netstat.log             - TCP extended counters (TcpExt/IpExt)
  05_snmp.log                - TCP/UDP SNMP counters
  06_sockstat.log            - socket statistics
  07_memory.log              - memory info
  08_loadavg.log             - load average
  09_netdev.log              - interface byte/packet/drop counters
  10_ethtool_S.log           - NIC-level counters (every 2s)
  11_ss_sockets.log          - socket buffer sizes during test
  12_mpstat.log              - per-CPU stats (every ~5s)
  13_pressure.log            - PSI (if available)
  99_posttest.txt            - system state after test

Quick checks:
  # Packet drops during test (rx_drop=col5, tx_drop=col10):
  awk -F',' 'NR>1 {print \$1, \$5, \$10}' $LOG_DIR/09_netdev.log

  # Did softirqs saturate one CPU?
  tail -n 5 $LOG_DIR/03_softirqs.log

  # iperf3 summary:
  jq '.end' $LOG_DIR/iperf3_${ROLE}.json

  # UDP drops from kernel (InErrors, RcvbufErrors):
  awk -F',' '/Udp:/ {print}' $LOG_DIR/05_snmp.log | tail -n 4
SUMMARY
