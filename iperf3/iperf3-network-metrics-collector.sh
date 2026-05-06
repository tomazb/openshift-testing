#!/usr/bin/env bash
# Collect iperf3 output and host-visible network metrics inside an OpenShift pod.
set -Eeuo pipefail

ROLE=""
TARGET=""
PEER=""
DURATION=30
BANDWIDTH="0"
PROTOCOL="tcp"
PACKET_SIZE="auto"
SOCKET_BUFFER="256M"
PARALLEL=1
OUTPUT_DIR=""
INTERFACE="auto"
SERVER_PORT=5201
LOG_DIR=""
IPERF_PID=""
METRIC_PID=""

usage() {
  cat <<USAGE
Usage: $0 --role <client|server> [options]

Required:
  --role client|server

Client options:
  --target ADDRESS      Server IP or DNS name. Defaults to --peer.
  --peer NAME           Peer node or host name used for route/interface detection.

Common options:
  --duration SECONDS    Test duration (default: 30)
  --protocol tcp|udp    Protocol (default: tcp)
  --bandwidth VALUE     UDP bandwidth target (default: 0)
  --packet-size BYTES   UDP payload size or auto from MTU (default: auto)
  --window VALUE        iperf3 socket buffer (default: 256M)
  --parallel COUNT      Parallel streams (default: 1)
  --interface IFACE     Interface to monitor, or auto (default: auto)
  --output DIR          Output directory
  --port PORT           iperf3 port (default: 5201)
USAGE
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--role) ROLE="${2:-}"; shift 2 ;;
      -t|--target) TARGET="${2:-}"; shift 2 ;;
      --peer) PEER="${2:-}"; shift 2 ;;
      -d|--duration) DURATION="${2:-}"; shift 2 ;;
      -b|--bandwidth) BANDWIDTH="${2:-}"; shift 2 ;;
      -p|--protocol) PROTOCOL="${2:-}"; shift 2 ;;
      -l|--packet-size) PACKET_SIZE="${2:-}"; shift 2 ;;
      -w|--window) SOCKET_BUFFER="${2:-}"; shift 2 ;;
      -P|--parallel) PARALLEL="${2:-}"; shift 2 ;;
      -i|--interface) INTERFACE="${2:-}"; shift 2 ;;
      -o|--output) OUTPUT_DIR="${2:-}"; shift 2 ;;
      --port) SERVER_PORT="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      *) echo "Unknown option: $1" >&2; usage ;;
    esac
  done

  [[ "$ROLE" == "client" || "$ROLE" == "server" ]] || { echo "ERROR: --role must be client or server" >&2; usage; }
  [[ "$PROTOCOL" == "tcp" || "$PROTOCOL" == "udp" ]] || { echo "ERROR: --protocol must be tcp or udp" >&2; usage; }
  [[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --duration must be a positive integer" >&2; exit 2; }
  [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --parallel must be a positive integer" >&2; exit 2; }
  [[ "$SERVER_PORT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --port must be a positive integer" >&2; exit 2; }

  if [[ "$ROLE" == "client" && -z "$TARGET" ]]; then
    TARGET="$PEER"
  fi
  [[ "$ROLE" == "server" || -n "$TARGET" ]] || { echo "ERROR: --target or --peer is required for client role" >&2; usage; }
}

command_available() {
  command -v "$1" >/dev/null 2>&1
}

warn_missing() {
  local cmd="$1"
  command_available "$cmd" || echo "WARN: optional command unavailable: $cmd" >>"$LOG_DIR/00_warnings.log"
}

setup() {
  if [[ -z "$OUTPUT_DIR" ]]; then
    LOG_DIR="/tmp/iperf3-${ROLE}"
  else
    LOG_DIR="$OUTPUT_DIR"
  fi
  mkdir -p "$LOG_DIR"
  : >"$LOG_DIR/00_warnings.log"
  for cmd in ip iperf3 awk sed grep date; do
    command_available "$cmd" || { echo "ERROR: required command unavailable: $cmd" >&2; exit 127; }
  done
  for cmd in ethtool ss jq mpstat conntrack journalctl; do
    warn_missing "$cmd"
  done
}

detect_interface() {
  if [[ "$INTERFACE" != "auto" && -n "$INTERFACE" ]]; then
    return
  fi

  if [[ -n "$TARGET" ]]; then
    INTERFACE="$(ip route get "$TARGET" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }' || true)"
  fi
  if [[ -z "$INTERFACE" || "$INTERFACE" == "auto" ]]; then
    INTERFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)"
  fi
  [[ -n "$INTERFACE" && "$INTERFACE" != "auto" ]] || { echo "ERROR: could not auto-detect network interface" >&2; exit 2; }
}

auto_packet_size() {
  [[ "$PROTOCOL" == "udp" && "$PACKET_SIZE" == "auto" ]] || return
  local mtu
  mtu="$(cat "/sys/class/net/$INTERFACE/mtu" 2>/dev/null || true)"
  if [[ "$mtu" =~ ^[0-9]+$ && "$mtu" -gt 28 ]]; then
    PACKET_SIZE="$((mtu - 28))"
  else
    PACKET_SIZE="1472"
  fi
}

write_metadata() {
  cat >"$LOG_DIR/run-metadata.json" <<EOF
{
  "role": "$ROLE",
  "target": "$TARGET",
  "peer": "$PEER",
  "protocol": "$PROTOCOL",
  "duration_seconds": $DURATION,
  "port": $SERVER_PORT,
  "parallel": $PARALLEL,
  "interface": "$INTERFACE",
  "packet_size": "$PACKET_SIZE",
  "socket_buffer": "$SOCKET_BUFFER",
  "started_at": "$(date -Iseconds)"
}
EOF
}

collect_baseline() {
  local f="$LOG_DIR/00_baseline.txt"
  {
    echo "=== Baseline collected at $(date -Iseconds) ==="
    hostname || true
    uname -a || true
    cat /etc/os-release 2>/dev/null || true
    echo "--- Interface $INTERFACE ---"
    ip addr show "$INTERFACE" || true
    ip route show || true
    if command_available ethtool; then
      ethtool "$INTERFACE" 2>/dev/null || true
      ethtool -S "$INTERFACE" 2>/dev/null || true
    fi
    echo "--- Interrupts ---"
    grep -F "$INTERFACE" /proc/interrupts 2>/dev/null || true
    echo "--- RPS / XPS ---"
    for q in "/sys/class/net/$INTERFACE"/queues/rx-*/rps_cpus; do
      [[ -e "$q" ]] || continue
      echo "$q: $(cat "$q" 2>/dev/null || echo N/A)"
    done
    for q in "/sys/class/net/$INTERFACE"/queues/tx-*/xps_cpus; do
      [[ -e "$q" ]] || continue
      echo "$q: $(cat "$q" 2>/dev/null || echo N/A)"
    done
    sysctl net.core.rmem_max net.core.wmem_max net.core.netdev_max_backlog 2>/dev/null || true
    iperf3 --version 2>/dev/null || true
  } >"$f"
}

collect_continuous_metrics() {
  local netdev_file="$LOG_DIR/09_netdev.log"
  local cpu_file="$LOG_DIR/01_cpu_usage.log"
  local ss_file="$LOG_DIR/11_ss_sockets.log"
  local prev_cpu_line=""
  echo "timestamp,user,system,iowait,idle" >"$cpu_file"
  echo "timestamp,iface,rx_bytes,rx_packets,rx_errs,rx_drop,tx_bytes,tx_packets,tx_errs,tx_drop" >"$netdev_file"

  while true; do
    local ts cur_cpu_line
    ts="$(date +%s.%N)"
    cur_cpu_line="$(grep '^cpu ' /proc/stat | head -1)"
    if [[ -n "$prev_cpu_line" ]]; then
      awk -v ts="$ts" -v cur="$cur_cpu_line" -v prev="$prev_cpu_line" 'BEGIN {
        n = split(cur, c, " "); split(prev, p, " "); dt = 0
        for (i = 2; i <= n; i++) dt += c[i] - p[i]
        if (dt > 0) printf "%s,%.2f,%.2f,%.2f,%.2f\n", ts, (c[2]+c[3]-p[2]-p[3])*100/dt, (c[4]-p[4])*100/dt, (c[6]-p[6])*100/dt, (c[5]-p[5])*100/dt
      }' >>"$cpu_file" 2>/dev/null || true
    fi
    prev_cpu_line="$cur_cpu_line"
    awk -v ts="$ts" -v iface="$INTERFACE" '$1 == iface ":" {gsub(":",""); printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", ts, $1, $2, $3, $4, $5, $10, $11, $12, $13}' /proc/net/dev >>"$netdev_file" 2>/dev/null || true
    if command_available ss; then
      ss -tanup 2>/dev/null | awk -v ts="$ts" -v port=":$SERVER_PORT" 'index($0, port) {printf "%s,%s\n", ts, $0}' >>"$ss_file" || true
    fi
    sleep 1
  done
}

collect_posttest() {
  local f="$LOG_DIR/99_posttest.txt"
  [[ -f "$f" ]] && return
  {
    echo "=== Post-test collected at $(date -Iseconds) ==="
    ip -s link show "$INTERFACE" || true
    if command_available ethtool; then
      ethtool -S "$INTERFACE" 2>/dev/null || true
    fi
    dmesg 2>/dev/null | tail -n 50 || journalctl -k -n 50 2>/dev/null || true
  } >"$f"
}

cleanup() {
  [[ -n "${IPERF_PID:-}" ]] && kill "$IPERF_PID" 2>/dev/null || true
  [[ -n "${METRIC_PID:-}" ]] && kill "$METRIC_PID" 2>/dev/null || true
  [[ -n "${METRIC_PID:-}" ]] && wait "$METRIC_PID" 2>/dev/null || true
  collect_posttest 2>/dev/null || true
}

trap cleanup EXIT INT TERM

run_server() {
  collect_continuous_metrics &
  METRIC_PID=$!
  iperf3 -s -p "$SERVER_PORT" -1 --json >"$LOG_DIR/iperf3_server.json" 2>"$LOG_DIR/iperf3_server.stderr" &
  IPERF_PID=$!
  local rc=0
  wait "$IPERF_PID" || rc=$?
  IPERF_PID=""
  echo "$rc" >"$LOG_DIR/iperf3_server.rc"
  return "$rc"
}

run_client() {
  collect_continuous_metrics &
  METRIC_PID=$!
  local iperf_args=(-c "$TARGET" -p "$SERVER_PORT" -t "$DURATION" -w "$SOCKET_BUFFER" -P "$PARALLEL" --json)
  if [[ "$PROTOCOL" == "udp" ]]; then
    iperf_args+=(-u -b "$BANDWIDTH" -l "$PACKET_SIZE")
  fi
  printf 'Running: iperf3'
  printf ' %q' "${iperf_args[@]}"
  printf '\n'
  iperf3 "${iperf_args[@]}" >"$LOG_DIR/iperf3_client.json" 2>"$LOG_DIR/iperf3_client.stderr" &
  IPERF_PID=$!
  local rc=0
  wait "$IPERF_PID" || rc=$?
  IPERF_PID=""
  echo "$rc" >"$LOG_DIR/iperf3_client.rc"
  if command_available jq && [[ -s "$LOG_DIR/iperf3_client.json" ]]; then
    jq -r '.end | if .sum_received then "throughput_gbps=\(.sum_received.bits_per_second / 1000000000)" else "lost_percent=\(.sum.lost_percent // "N/A")" end' "$LOG_DIR/iperf3_client.json" 2>/dev/null || true
  fi
  return "$rc"
}

parse_args "$@"
setup
detect_interface
auto_packet_size
write_metadata
collect_baseline

if [[ "$ROLE" == "server" ]]; then
  run_server
else
  run_client
fi
