#!/usr/bin/env bash
# Pod-side iperf3 runner and lightweight host-visible metric collector.
set -Eeuo pipefail

ROLE=""
TARGET=""
DURATION="30"
BANDWIDTH="0"
PROTOCOL="tcp"
PACKET_SIZE="auto"
SOCKET_BUFFER="256M"
PARALLEL="1"
OUTPUT_DIR=""
INTERFACE="auto"
SERVER_PORT="5201"
LOG_DIR=""
IPERF_PID=""
METRIC_PID=""
DEEP="${DEEP:-false}"
MPSTAT_PID=""

usage() {
  cat <<USAGE
Usage: $0 --role <client|server> [options]

Options:
  --target ADDRESS      Server address for client role
  --duration SECONDS    Test duration
  --protocol tcp|udp    Test protocol
  --bandwidth VALUE     UDP bandwidth target
  --packet-size BYTES   UDP payload size or auto from interface MTU
  --window VALUE        iperf3 socket buffer
  --parallel COUNT      Parallel streams
  --interface IFACE     Interface to monitor, or auto
  --output DIR          Artifact directory inside the pod
  --port PORT           iperf3 server port
  --deep                Enable extended metric collection (softirqs, sockstat, PSI, mpstat, etc.)
USAGE
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role|-r) ROLE="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --target|-t) TARGET="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --duration|-d) DURATION="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --bandwidth|-b) BANDWIDTH="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --protocol|-p) PROTOCOL="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --packet-size|-l) PACKET_SIZE="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --window|-w) SOCKET_BUFFER="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --parallel|-P) PARALLEL="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --interface|-i) INTERFACE="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --output|-o) OUTPUT_DIR="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --port) SERVER_PORT="$(require_value "$1" "${2:-}")"; shift 2 ;;
      --deep) DEEP="true"; shift ;;
      --help|-h) usage ;;
      *) echo "Unknown option: $1" >&2; usage ;;
    esac
  done

  [[ "$ROLE" == "client" || "$ROLE" == "server" ]] || { echo "ERROR: --role must be client or server" >&2; usage; }
  [[ "$PROTOCOL" == "tcp" || "$PROTOCOL" == "udp" ]] || { echo "ERROR: --protocol must be tcp or udp" >&2; exit 2; }
  [[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --duration must be a positive integer" >&2; exit 2; }
  [[ "$PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --parallel must be a positive integer" >&2; exit 2; }
  [[ "$SERVER_PORT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --port must be a positive integer" >&2; exit 2; }
  [[ "$ROLE" == "server" || -n "$TARGET" ]] || { echo "ERROR: --target is required for client role" >&2; exit 2; }
}

require_value() {
  local option="$1" value="$2"
  if [[ -z "$value" || "$value" == -* ]]; then
    echo "ERROR: $option requires a value" >&2
    usage
  fi
  printf '%s\n' "$value"
}

command_available() {
  command -v "$1" >/dev/null 2>&1
}

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

setup() {
  LOG_DIR="${OUTPUT_DIR:-/tmp/network-validation-${ROLE}}"
  mkdir -p "$LOG_DIR"
  : >"$LOG_DIR/00_warnings.log"
  for cmd in ip iperf3 awk grep date; do
    command_available "$cmd" || { echo "ERROR: required command unavailable: $cmd" >&2; exit 127; }
  done
  for cmd in ethtool ss journalctl; do
    command_available "$cmd" || echo "WARN: optional command unavailable: $cmd" >>"$LOG_DIR/00_warnings.log"
  done
}

write_metadata() {
  cat >"$LOG_DIR/run-metadata.json" <<EOF
{
  "role": "$ROLE",
  "target": "$TARGET",
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
  {
    echo "=== Baseline collected at $(date -Iseconds) ==="
    hostname || true
    uname -a || true
    cat /etc/os-release 2>/dev/null || true
    ip addr show "$INTERFACE" 2>/dev/null || true
    ip route show 2>/dev/null || true
    ethtool "$INTERFACE" 2>/dev/null || true
    ethtool -S "$INTERFACE" 2>/dev/null || true
    grep -F "$INTERFACE" /proc/interrupts 2>/dev/null || true
    sysctl net.core.rmem_max net.core.wmem_max net.core.netdev_max_backlog 2>/dev/null || true
    iperf3 --version 2>/dev/null || true
  } >"$LOG_DIR/00_baseline.txt"
}

collect_continuous_metrics() {
  local cpu_file="$LOG_DIR/01_cpu_usage.log"
  local netdev_file="$LOG_DIR/09_netdev.log"
  local prev_cpu_line=""
  echo "timestamp,user,system,iowait,idle" >"$cpu_file"
  echo "timestamp,iface,rx_bytes,rx_packets,rx_errs,rx_drop,tx_bytes,tx_packets,tx_errs,tx_drop" >"$netdev_file"

  while true; do
    local ts cur_cpu_line sec
    ts="$(date +%s.%N)"
    sec="${ts%%.*}"
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
    if [[ "$DEEP" == "true" ]]; then
      awk -v ts="$ts" '/NET_RX|NET_TX/ {printf "%s,%s", ts, $1; for(i=2;i<=NF;i++) printf ",%s", $i; print ""}' /proc/softirqs >> "$LOG_DIR/03_softirqs.log" 2>/dev/null || true
      awk -v ts="$ts" '/^TcpExt:|^IpExt:/ {printf "%s,%s\n", ts, $0}' /proc/net/netstat >> "$LOG_DIR/04_netstat.log" 2>/dev/null || true
      awk -v ts="$ts" '/^Udp:|^Tcp:/ {printf "%s,%s\n", ts, $0}' /proc/net/snmp >> "$LOG_DIR/05_snmp.log" 2>/dev/null || true
      awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' /proc/net/sockstat >> "$LOG_DIR/06_sockstat.log" 2>/dev/null || true
      awk -v ts="$ts" '/^MemTotal:|^MemFree:|^MemAvailable:|^Buffers:|^Cached:/ {printf "%s,%s,%s\n", ts, $1, $2}' /proc/meminfo >> "$LOG_DIR/07_memory.log" 2>/dev/null || true
      awk -v ts="$ts" '{printf "%s,%s,%s,%s\n", ts, $1, $2, $3}' /proc/loadavg >> "$LOG_DIR/08_loadavg.log" 2>/dev/null || true
      if command_available ethtool && [[ $(( sec % 2 )) -eq 0 ]]; then
        { echo "--- TIMESTAMP $ts ---"; ethtool -S "$INTERFACE" 2>/dev/null || true; } >> "$LOG_DIR/10_ethtool_S.log" || true
      fi
      if command_available ss; then
        if [[ "$PROTOCOL" == "udp" ]]; then
          ss -uanmp 2>/dev/null | grep -E "iperf3|UNCONN|ESTAB" | awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' >> "$LOG_DIR/11_ss_sockets.log" || true
        else
          ss -tanmp 2>/dev/null | grep -E "iperf3|ESTAB|LISTEN" | awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' >> "$LOG_DIR/11_ss_sockets.log" || true
        fi
      fi
      if [[ -f /proc/pressure/cpu ]]; then
        awk -v ts="$ts" '{printf "%s,%s\n", ts, $0}' /proc/pressure/cpu >> "$LOG_DIR/13_pressure.log" 2>/dev/null || true
      fi
    fi
    sleep 1
  done
}

collect_posttest() {
  [[ -n "${LOG_DIR:-}" ]] || return 0
  {
    echo "=== Post-test collected at $(date -Iseconds) ==="
    ip -s link show "$INTERFACE" 2>/dev/null || true
    ethtool -S "$INTERFACE" 2>/dev/null || true
    dmesg 2>/dev/null | tail -n 50 || journalctl -k -n 50 2>/dev/null || true
  } >"$LOG_DIR/99_posttest.txt"
}

cleanup() {
  if [[ -n "${IPERF_PID:-}" ]]; then
    kill "$IPERF_PID" 2>/dev/null || true
  fi
  if [[ -n "${METRIC_PID:-}" ]]; then
    kill "$METRIC_PID" 2>/dev/null || true
    wait "$METRIC_PID" 2>/dev/null || true
  fi
  if [[ -n "${MPSTAT_PID:-}" ]]; then
    kill "$MPSTAT_PID" 2>/dev/null || true
    wait "$MPSTAT_PID" 2>/dev/null || true
  fi
  collect_posttest 2>/dev/null || true
}

run_server() {
  collect_continuous_metrics &
  METRIC_PID=$!
  start_mpstat_loop
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
  start_mpstat_loop
  local iperf_args=(-c "$TARGET" -p "$SERVER_PORT" -t "$DURATION" -w "$SOCKET_BUFFER" -P "$PARALLEL" --json)
  if [[ "$PROTOCOL" == "udp" ]]; then
    iperf_args+=(-u -b "$BANDWIDTH" -l "$PACKET_SIZE")
  fi
  printf 'Running: iperf3' >"$LOG_DIR/iperf3_client.command"
  printf ' %q' "${iperf_args[@]}" >>"$LOG_DIR/iperf3_client.command"
  printf '\n' >>"$LOG_DIR/iperf3_client.command"
  local rc=0
  iperf3 "${iperf_args[@]}" >"$LOG_DIR/iperf3_client.json" 2>"$LOG_DIR/iperf3_client.stderr" || rc=$?
  echo "$rc" >"$LOG_DIR/iperf3_client.rc"
  return "$rc"
}

trap cleanup EXIT INT TERM
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
