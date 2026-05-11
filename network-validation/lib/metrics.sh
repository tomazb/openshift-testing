#!/usr/bin/env bash
# CoreOS-compatible metric collection via exec into pods.
# All /proc and /sys reads work on CoreOS; mpstat, ethtool -S, and conntrack
# are optional and degrade gracefully when absent.
set -Eeuo pipefail

# Collect a baseline snapshot from inside a pod.
# Arguments: <pod-name> <output-dir>
collect_pod_baseline() {
  local pod="$1" d="$2"
  local f="$d/00_baseline.txt"

  log "Collecting baseline from pod $pod..."
  # shellcheck disable=SC2016 # script is evaluated inside the target pod.
  oc -n "$IPERF_NAMESPACE" exec "$pod" -- bash -c '
    echo "=== Baseline collected at $(date -Iseconds) ==="
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
    lscpu 2>/dev/null | grep -E "Model name|CPU\(s\)|Thread|Core|Socket|NUMA" || true
    echo
    echo "--- Memory ---"
    free -h 2>/dev/null || cat /proc/meminfo | head -5
    echo
    echo "--- Interfaces ---"
    ip addr show 2>/dev/null || true
    echo
    echo "--- Routes ---"
    ip route show 2>/dev/null || true
    echo
    echo "--- Default interface details ---"
    IFACE=$(ip route show default 2>/dev/null | awk "/default/ {print \$5; exit}")
    if [ -n "$IFACE" ]; then
      echo "Interface: $IFACE"
      ethtool "$IFACE" 2>/dev/null || echo "ethtool not available"
      echo
      echo "--- ethtool ring buffer ---"
      ethtool -g "$IFACE" 2>/dev/null || true
      echo
      echo "--- ethtool features ---"
      ethtool -k "$IFACE" 2>/dev/null || true
    fi
    echo
    echo "--- Sysctl network buffers ---"
    sysctl net.core.rmem_max net.core.wmem_max net.core.rmem_default \
           net.core.wmem_default net.core.netdev_max_backlog 2>/dev/null || true
    echo
    echo "--- iperf3 version ---"
    iperf3 --version 2>/dev/null || true
  ' > "$f" 2>&1 || warn "Baseline collection incomplete for $pod"
}

# Start continuous metric collection inside a pod (backgrounds the process).
# Arguments: <pod-name> <output-dir> <duration>
# Sets METRICS_EXEC_PID in the caller's scope.
start_pod_metrics() {
  local pod="$1" d="$2" duration="$3"
  local interval=1

  log "Starting metric collection in pod $pod for ${duration}s..."
  oc -n "$IPERF_NAMESPACE" exec "$pod" -- bash -c "
    interval=$interval
    duration=$duration
    end_time=\$(( \$(date +%s) + duration + 5 ))

    cpu_file=/tmp/metrics_cpu.csv
    netdev_file=/tmp/metrics_netdev.csv
    softirq_file=/tmp/metrics_softirq.log
    snmp_file=/tmp/metrics_snmp.log
    sockstat_file=/tmp/metrics_sockstat.log
    mem_file=/tmp/metrics_memory.log
    load_file=/tmp/metrics_loadavg.csv
    pressure_file=/tmp/metrics_pressure.log

    echo 'timestamp,user,system,iowait,idle' > \"\$cpu_file\"
    echo 'timestamp,iface,rx_bytes,rx_packets,rx_errs,rx_drop,tx_bytes,tx_packets,tx_errs,tx_drop' > \"\$netdev_file\"
    echo 'timestamp,load1,load5,load15' > \"\$load_file\"

    prev_cpu_line=''

    while [ \$(date +%s) -lt \$end_time ]; do
      ts=\$(date +%s.%N)

      # CPU delta
      cur_cpu_line=\$(grep '^cpu ' /proc/stat | head -1)
      if [ -n \"\$prev_cpu_line\" ]; then
        awk -v ts=\"\$ts\" -v cur=\"\$cur_cpu_line\" -v prev=\"\$prev_cpu_line\" 'BEGIN {
          n = split(cur, c, \" \")
          split(prev, p, \" \")
          dt = 0
          for (i = 2; i <= n; i++) dt += c[i] - p[i]
          if (dt > 0)
            printf \"%s,%.2f,%.2f,%.2f,%.2f\n\", ts,
              (c[2]+c[3]-p[2]-p[3])*100/dt,
              (c[4]-p[4])*100/dt,
              (c[6]-p[6])*100/dt,
              (c[5]-p[5])*100/dt
        }' >> \"\$cpu_file\" 2>/dev/null || true
      fi
      prev_cpu_line=\"\$cur_cpu_line\"

      # NET_RX / NET_TX softirqs
      awk -v ts=\"\$ts\" '/NET_RX|NET_TX/ {printf \"%s,%s\", ts, \$1; for(i=2;i<=NF;i++) printf \",%s\", \$i; print \"\"}' /proc/softirqs >> \"\$softirq_file\" 2>/dev/null || true

      # /proc/net/dev — all interfaces
      awk -v ts=\"\$ts\" '/:/ {gsub(\":\",\"\"); printf \"%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n\", ts, \$1, \$2, \$3, \$4, \$5, \$10, \$11, \$12, \$13}' /proc/net/dev >> \"\$netdev_file\" 2>/dev/null || true

      # /proc/net/snmp
      awk -v ts=\"\$ts\" '/^Udp:|^Tcp:/ {printf \"%s,%s\n\", ts, \$0}' /proc/net/snmp >> \"\$snmp_file\" 2>/dev/null || true

      # /proc/net/sockstat
      awk -v ts=\"\$ts\" '{printf \"%s,%s\n\", ts, \$0}' /proc/net/sockstat >> \"\$sockstat_file\" 2>/dev/null || true

      # Memory
      awk -v ts=\"\$ts\" '/^MemTotal:|^MemFree:|^MemAvailable:/ {printf \"%s,%s,%s\n\", ts, \$1, \$2}' /proc/meminfo >> \"\$mem_file\" 2>/dev/null || true

      # Load average
      awk -v ts=\"\$ts\" '{printf \"%s,%s,%s,%s\n\", ts, \$1, \$2, \$3}' /proc/loadavg >> \"\$load_file\" 2>/dev/null || true

      # PSI (if available)
      if [ -f /proc/pressure/cpu ]; then
        awk -v ts=\"\$ts\" '{printf \"%s,%s\n\", ts, \$0}' /proc/pressure/cpu >> \"\$pressure_file\" 2>/dev/null || true
      fi

      sleep \"\$interval\"
    done
  " &>/dev/null &
  # shellcheck disable=SC2034  # used by caller via dynamic scoping
  METRICS_EXEC_PID=$!
}

# Retrieve collected metrics from a pod and save locally.
# Arguments: <pod-name> <output-dir>
retrieve_pod_metrics() {
  local pod="$1" d="$2"

  log "Retrieving metrics from pod $pod..."
  local files=(
    metrics_cpu.csv
    metrics_netdev.csv
    metrics_softirq.log
    metrics_snmp.log
    metrics_sockstat.log
    metrics_memory.log
    metrics_loadavg.csv
    metrics_pressure.log
  )
  for f in "${files[@]}"; do
    oc -n "$IPERF_NAMESPACE" exec "$pod" -- cat "/tmp/$f" > "$d/$f" 2>/dev/null || true
  done
}

# Collect a post-test snapshot from inside a pod.
# Arguments: <pod-name> <output-dir>
collect_pod_posttest() {
  local pod="$1" d="$2"
  local f="$d/99_posttest.txt"

  log "Collecting post-test snapshot from pod $pod..."
  # shellcheck disable=SC2016 # script is evaluated inside the target pod.
  oc -n "$IPERF_NAMESPACE" exec "$pod" -- bash -c '
    echo "=== Post-test collected at $(date -Iseconds) ==="
    echo "--- Interface counters ---"
    ip -s link show 2>/dev/null || true
    echo
    echo "--- /proc/net/snmp final ---"
    cat /proc/net/snmp 2>/dev/null || true
    echo
    echo "--- /proc/net/netstat final ---"
    cat /proc/net/netstat 2>/dev/null || true
  ' > "$f" 2>&1 || warn "Post-test collection incomplete for $pod"
}
