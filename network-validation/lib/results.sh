#!/usr/bin/env bash
# Verdict computation and report rendering for network validation.
set -Eeuo pipefail

VERDICT_ACCEPTED="Accepted"
VERDICT_RISK="Accepted with risks"
VERDICT_BLOCKED="Blocked"

# Read a scenario summary file and extract a key.
# Arguments: <summary-file> <key>
results_get_summary_value() {
  local file="$1" key="$2"
  if [[ -f "$file" ]]; then
    awk -v key="$key" 'index($0, key "=") == 1 {sub("^[^=]*=", ""); print; exit}' "$file"
  fi
}

results_add_blocking_reason() {
  local reason="$1"
  local artifact="${2:-}"
  if [[ -n "$artifact" ]]; then
    printf -- "- %s (artifact: \`%s\`)\n" "$reason" "$artifact" >> "$ARTIFACT_DIR/07-report/verdict-blocking-reasons.txt"
  else
    printf -- '- %s\n' "$reason" >> "$ARTIFACT_DIR/07-report/verdict-blocking-reasons.txt"
  fi
}

results_add_risk_reason() {
  local reason="$1"
  local artifact="${2:-}"
  if [[ -n "$artifact" ]]; then
    printf -- "- %s (artifact: \`%s\`)\n" "$reason" "$artifact" >> "$ARTIFACT_DIR/07-report/verdict-risk-reasons.txt"
  else
    printf -- '- %s\n' "$reason" >> "$ARTIFACT_DIR/07-report/verdict-risk-reasons.txt"
  fi
}

results_evaluate_scenario() {
  local label="$1" summary="$2" required="$3"

  if [[ ! -f "$summary" ]]; then
    if [[ "$required" == "true" ]]; then
      results_add_risk_reason "$label test was not run"
    fi
    return
  fi

  local status throughput_gbps
  status="$(results_get_summary_value "$summary" status)"
  throughput_gbps="$(results_get_summary_value "$summary" throughput_gbps)"

  if [[ "$status" != "ok" ]]; then
    results_add_blocking_reason "$label iperf3 test failed: status=${status:-unknown}" "$summary"
    return
  fi

  if [[ -n "$throughput_gbps" ]] && awk "BEGIN {exit !($IPERF_MIN_THROUGHPUT_GBPS > 0 && $throughput_gbps < $IPERF_MIN_THROUGHPUT_GBPS)}" 2>/dev/null; then
    results_add_blocking_reason \
      "$label throughput ${throughput_gbps} Gbps below minimum ${IPERF_MIN_THROUGHPUT_GBPS} Gbps" \
      "$summary"
  fi

  local protocol
  protocol="$(results_get_summary_value "$summary" protocol)"
  if [[ "$protocol" == "udp" ]]; then
    local lost_pct
    lost_pct="$(results_get_summary_value "$summary" lost_percent)"
    if [[ -n "$lost_pct" ]] && awk "BEGIN {exit !($lost_pct > $IPERF_MAX_LOSS_PERCENT)}" 2>/dev/null; then
      results_add_blocking_reason \
        "$label packet loss ${lost_pct}% exceeds maximum ${IPERF_MAX_LOSS_PERCENT}%" \
        "$summary"
    elif [[ -n "$lost_pct" ]] && awk "BEGIN {exit !($lost_pct > 0)}" 2>/dev/null; then
      results_add_risk_reason "$label packet loss detected: ${lost_pct}%"
    fi
  elif [[ "$protocol" == "tcp" ]]; then
    local retransmits
    retransmits="$(results_get_summary_value "$summary" retransmits)"
    if [[ -n "$retransmits" ]] && (( IPERF_MAX_RETRANSMITS > 0 )) && (( retransmits > IPERF_MAX_RETRANSMITS )); then
      results_add_risk_reason "$label retransmits ($retransmits) exceed threshold ($IPERF_MAX_RETRANSMITS)"
    fi
  fi
}

results_compute_verdict() {
  local d="$ARTIFACT_DIR/07-report"
  mkdir -p "$d"
  : > "$d/verdict-blocking-reasons.txt"
  : > "$d/verdict-risk-reasons.txt"

  read_runtime

  # --- Network operator gate ---
  local net_available="${NET_AVAILABLE:-unknown}"
  local net_degraded="${NET_DEGRADED:-unknown}"
  if [[ "$net_available" != "True" || "$net_degraded" == "True" ]]; then
    results_add_blocking_reason \
      "Network operator gate unhealthy: Available=$net_available, Degraded=$net_degraded" \
      "$ARTIFACT_DIR/00-preflight/network-operator-gate.txt"
  fi

  if [[ "$IPERF_PROTOCOL" == "udp" && "${IPERF_PACKET_SIZE:-}" =~ ^[0-9]+$ && "${CLUSTER_MTU:-unknown}" =~ ^[0-9]+$ ]] && (( IPERF_PACKET_SIZE > CLUSTER_MTU )); then
    results_add_risk_reason \
      "UDP packet size ${IPERF_PACKET_SIZE} exceeds captured cluster MTU ${CLUSTER_MTU}; throughput may include fragmentation effects" \
      "$ARTIFACT_DIR/00-preflight/network-baseline.env"
  fi

  if [[ -n "${DEPLOYED_IPERF_SERVER_NODE:-}" && -n "${DEPLOYED_IPERF_CLIENT_NODE:-}" && "${DEPLOYED_IPERF_SERVER_NODE}" == "${DEPLOYED_IPERF_CLIENT_NODE}" ]]; then
    results_add_risk_reason "Server and client pods were deployed on the same node"
  fi

  results_evaluate_scenario "Cross-node" "$ARTIFACT_DIR/01-cross-node/iperf3_summary.txt" true
  results_evaluate_scenario "Same-node" "$ARTIFACT_DIR/02-same-node/iperf3_summary.txt" false
  results_evaluate_scenario "Host-network" "$ARTIFACT_DIR/03-host-network/iperf3_summary.txt" false
  results_evaluate_scenario "Pod-to-service" "$ARTIFACT_DIR/04-pod-to-service/iperf3_summary.txt" false

  # --- Determine final verdict ---
  if [[ -s "$d/verdict-blocking-reasons.txt" ]]; then
    echo "$VERDICT_BLOCKED" > "$d/verdict.txt"
  elif [[ -s "$d/verdict-risk-reasons.txt" ]]; then
    echo "$VERDICT_RISK" > "$d/verdict.txt"
  else
    echo "$VERDICT_ACCEPTED" > "$d/verdict.txt"
  fi
}

results_verdict() {
  cat "$ARTIFACT_DIR/07-report/verdict.txt" 2>/dev/null || echo "Not computed"
}

# Render a scenario section for the report.
# Arguments: <scenario-name> <artifact-dir>
render_scenario_section() {
  local d="$2"
  local summary="$d/iperf3_summary.txt"

  if [[ ! -f "$summary" ]]; then
    echo "Not run."
    return
  fi

  local status
  status="$(results_get_summary_value "$summary" status)"
  if [[ "$status" != "ok" ]]; then
    local error
    error="$(results_get_summary_value "$summary" error)"
    echo "Status: $status"
    [[ -n "$error" ]] && echo "Error: $error"
    return
  fi

  local protocol throughput_gbps
  protocol="$(results_get_summary_value "$summary" protocol)"
  throughput_gbps="$(results_get_summary_value "$summary" throughput_gbps)"

  echo "- Protocol: $protocol"
  echo "- Throughput: ${throughput_gbps} Gbps"

  if [[ "$protocol" == "udp" ]]; then
    echo "- Jitter: $(results_get_summary_value "$summary" jitter_ms) ms"
    echo "- Packet loss: $(results_get_summary_value "$summary" lost_percent)%"
    echo "- Packets: $(results_get_summary_value "$summary" packets)"
    echo "- Lost packets: $(results_get_summary_value "$summary" lost_packets)"
  else
    echo "- Retransmits: $(results_get_summary_value "$summary" retransmits)"
    echo "- Bytes: $(results_get_summary_value "$summary" bytes)"
  fi
  echo "- Duration: $(results_get_summary_value "$summary" duration)s"
}

render_results_summary() {
  local verdict
  verdict="$(results_verdict)"

  cat <<EOF
## Results summary

- Verdict: $verdict
EOF

  if [[ -s "$ARTIFACT_DIR/07-report/verdict-blocking-reasons.txt" ]]; then
    echo ""
    echo "### Blocking reasons"
    echo ""
    cat "$ARTIFACT_DIR/07-report/verdict-blocking-reasons.txt"
  fi

  if [[ -s "$ARTIFACT_DIR/07-report/verdict-risk-reasons.txt" ]]; then
    echo ""
    echo "### Risk factors"
    echo ""
    cat "$ARTIFACT_DIR/07-report/verdict-risk-reasons.txt"
  fi
}

report() {
  init_dirs
  read_runtime

  results_compute_verdict
  local verdict
  verdict="$(results_verdict)"

  local f="$ARTIFACT_DIR/07-report/network-validation-report.md"
  local summary
  summary="$(render_results_summary)"

  cat > "$f" <<EOF
# OpenShift Network Validation Report

Generated: $(date -Iseconds)

## Runtime

- Artifact directory: \`$ARTIFACT_DIR\`
- Validation namespace: \`$IPERF_NAMESPACE\`
- Network type: \`${NETWORK_TYPE:-unknown}\`
- Cluster MTU: \`${CLUSTER_MTU:-unknown}\`
- Cluster CIDR: \`${CLUSTER_CIDR:-unknown}\`
- Service CIDR: \`${SERVICE_CIDR:-unknown}\`
- Node count: \`${NODE_COUNT:-unknown}\`
- Server node: \`${DEPLOYED_IPERF_SERVER_NODE:-${IPERF_SERVER_NODE:-unknown}}\`
- Client node: \`${DEPLOYED_IPERF_CLIENT_NODE:-${IPERF_CLIENT_NODE:-unknown}}\`

## Network operator gate

\`\`\`
$(cat "$ARTIFACT_DIR/00-preflight/network-operator-gate.txt" 2>/dev/null || echo "Not captured")
\`\`\`

## Test configuration

- Protocol: ${IPERF_PROTOCOL}
- Duration: ${IPERF_DURATION}s
- Bandwidth target: ${IPERF_BANDWIDTH}
- Packet size: ${IPERF_PACKET_SIZE}
- Socket buffer: ${IPERF_SOCKET_BUFFER}
- Parallel streams: ${IPERF_PARALLEL}

## Cross-node pod network

$(render_scenario_section "cross-node" "$ARTIFACT_DIR/01-cross-node")

## Same-node pod network

$(render_scenario_section "same-node" "$ARTIFACT_DIR/02-same-node")

## Host network

$(render_scenario_section "host-network" "$ARTIFACT_DIR/03-host-network")

## Pod-to-service network

$(render_scenario_section "pod-to-service" "$ARTIFACT_DIR/04-pod-to-service")

$summary
EOF

  log "Report written: $f"
  printf '%s\n' "$summary" | tee -a "$LOG_FILE"
}
