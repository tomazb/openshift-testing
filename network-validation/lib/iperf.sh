#!/usr/bin/env bash
# iperf3 test execution across topology scenarios.
set -Eeuo pipefail

# Run an iperf3 test between server and client pods.
# Arguments: <scenario-name> <target-ip> <artifact-subdir>
# The server pod must already be deployed.
run_iperf_test() {
  local scenario="$1" target_ip="$2" d="$3"
  local client_dir="$d/client"
  local server_dir="$d/server"
  mkdir -p "$client_dir" "$server_dir"

  [[ -n "$target_ip" ]] || fail "No target IP for scenario $scenario."
  log "Running iperf3 $scenario test: client -> $target_ip (${IPERF_PROTOCOL}, ${IPERF_DURATION}s)"

  local command_timeout=$((IPERF_DURATION + 30))
  local server_remote_dir="/tmp/network-validation-server"
  local client_remote_dir="/tmp/network-validation-client"
  local collector_extra_args=()
  [[ "${IPERF_DEEP_METRICS:-false}" == "true" ]] && collector_extra_args+=(--deep)

  log "Starting iperf3 server collector in pod iperf3-server..."
  timeout "$command_timeout" oc -n "$IPERF_NAMESPACE" exec iperf3-server -- \
    /opt/network-validation/iperf3-collector.sh \
      --role server \
      --protocol "$IPERF_PROTOCOL" \
      --port "$IPERF_PORT" \
      --duration "$IPERF_DURATION" \
      --parallel "$IPERF_PARALLEL" \
      --window "$IPERF_SOCKET_BUFFER" \
      --interface "$IPERF_INTERFACE" \
      --output "$server_remote_dir" \
      "${collector_extra_args[@]}" \
    > "$server_dir/collector.stdout" 2>"$server_dir/collector.stderr" &
  local server_pid=$!

  wait_for_iperf_server "$target_ip" "$d" || {
    echo "1" > "$client_dir/iperf3_client.rc"
    echo "server readiness check failed" > "$client_dir/iperf3_client.stderr"
    wait "$server_pid" 2>/dev/null || true
    retrieve_collector_artifacts "iperf3-server" "$server_remote_dir" "$server_dir"
    parse_iperf_results "$d" "$scenario"
    return
  }

  log "Starting iperf3 client collector in pod iperf3-client..."
  local client_rc=0
  timeout "$command_timeout" oc -n "$IPERF_NAMESPACE" exec iperf3-client -- \
    /opt/network-validation/iperf3-collector.sh \
      --role client \
      --target "$target_ip" \
      --protocol "$IPERF_PROTOCOL" \
      --port "$IPERF_PORT" \
      --duration "$IPERF_DURATION" \
      --parallel "$IPERF_PARALLEL" \
      --window "$IPERF_SOCKET_BUFFER" \
      --bandwidth "$IPERF_BANDWIDTH" \
      --packet-size "$IPERF_PACKET_SIZE" \
      --interface "$IPERF_INTERFACE" \
      --output "$client_remote_dir" \
      "${collector_extra_args[@]}" \
    > "$client_dir/collector.stdout" 2>"$client_dir/collector.stderr" || client_rc=$?

  local server_rc=0
  wait "$server_pid" 2>/dev/null || server_rc=$?

  retrieve_collector_artifacts "iperf3-client" "$client_remote_dir" "$client_dir"
  retrieve_collector_artifacts "iperf3-server" "$server_remote_dir" "$server_dir"
  if [[ "$client_rc" -ne 0 ]]; then
    echo "$client_rc" > "$client_dir/iperf3_client.rc"
  fi
  if [[ "$server_rc" -ne 0 ]]; then
    echo "$server_rc" > "$server_dir/iperf3_server.rc"
  fi

  parse_iperf_results "$d" "$scenario"
}

wait_for_iperf_server() {
  local target_ip="$1" d="$2"
  # shellcheck disable=SC2016 # evaluated by bash inside the client pod.
  local ready_script='for i in $(seq 1 "$1"); do if timeout 1 bash -c "</dev/tcp/$2/$3" 2>/dev/null; then exit 0; fi; sleep 1; done; exit 1'
  log "Waiting for iperf3 server readiness on $target_ip:$IPERF_PORT..."
  run_out_checked "$d/ready-check.txt" oc -n "$IPERF_NAMESPACE" exec iperf3-client -- \
    bash -c "$ready_script" ready-check "$IPERF_SERVER_READY_TIMEOUT" "$target_ip" "$IPERF_PORT"
}

retrieve_collector_artifacts() {
  local pod="$1" remote_dir="$2" local_dir="$3"
  local files=(
    00_warnings.log
    00_baseline.txt
    01_cpu_usage.log
    09_netdev.log
    99_posttest.txt
    run-metadata.json
    iperf3_client.command
    iperf3_client.json
    iperf3_client.stderr
    iperf3_client.rc
    iperf3_server.json
    iperf3_server.stderr
    iperf3_server.rc
    03_softirqs.log
    04_netstat.log
    05_snmp.log
    06_sockstat.log
    07_memory.log
    08_loadavg.log
    10_ethtool_S.log
    11_ss_sockets.log
    12_mpstat.log
    13_pressure.log
  )
  mkdir -p "$local_dir"
  for f in "${files[@]}"; do
    oc -n "$IPERF_NAMESPACE" exec "$pod" -- cat "$remote_dir/$f" > "$local_dir/$f" 2>/dev/null || true
  done
}

# Parse iperf3 JSON output and write a summary.
# Arguments: <artifact-dir> <scenario-name>
parse_iperf_results() {
  local d="$1" scenario="$2"
  local client_dir="$d/client"
  local server_dir="$d/server"
  local json="$client_dir/iperf3_client.json"
  local summary="$d/iperf3_summary.txt"
  local client_rc server_rc

  client_rc="$(results_read_artifact_rc "$client_dir/iperf3_client.rc")"
  server_rc="$(results_read_artifact_rc "$server_dir/iperf3_server.rc")"

  if [[ "$client_rc" != "0" ]]; then
    warn "iperf3 client failed for $scenario (rc=$client_rc)."
    {
      echo "status=error"
      echo "client_rc=$client_rc"
      echo "server_rc=$server_rc"
      echo "client_stderr=$client_dir/iperf3_client.stderr"
      echo "server_stderr=$server_dir/iperf3_server.stderr"
    } > "$summary"
    write_runtime_kv "$(runtime_key_prefix "$scenario")_RESULT_DIR" "$d"
    return
  fi

  if [[ ! -s "$json" ]]; then
    warn "No iperf3 client output for $scenario."
    {
      echo "status=error"
      echo "client_rc=$client_rc"
      echo "server_rc=$server_rc"
      echo "client_stderr=$client_dir/iperf3_client.stderr"
      echo "server_stderr=$server_dir/iperf3_server.stderr"
    } > "$summary"
    write_runtime_kv "$(runtime_key_prefix "$scenario")_RESULT_DIR" "$d"
    return
  fi

  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not available; skipping result parsing."
    echo "status=no-jq" > "$summary"
    return
  fi

  # Check for iperf3 error
  local error
  error="$(jq -r '.error // empty' "$json" 2>/dev/null || true)"
  if [[ -n "$error" ]]; then
    warn "iperf3 error for $scenario: $error"
    {
      echo "status=error"
      echo "error=$error"
      echo "client_rc=$client_rc"
      echo "server_rc=$server_rc"
    } > "$summary"
    write_runtime_kv "$(runtime_key_prefix "$scenario")_RESULT_DIR" "$d"
    return
  fi

  jq -r '
    .end |
    if .sum_received then
      # TCP
      "status=ok",
      "protocol=tcp",
      "throughput_bps=\(.sum_received.bits_per_second)",
      "throughput_gbps=\(.sum_received.bits_per_second / 1e9 | . * 100 | round / 100)",
      "bytes=\(.sum_received.bytes)",
      "retransmits=\(.sum_sent.retransmits // 0)",
      "duration=\(.sum_received.seconds)",
      "client_rc='"$client_rc"'",
      "server_rc='"$server_rc"'"
    else
      # UDP
      "status=ok",
      "protocol=udp",
      "throughput_bps=\(.sum.bits_per_second)",
      "throughput_gbps=\(.sum.bits_per_second / 1e9 | . * 100 | round / 100)",
      "jitter_ms=\(.sum.jitter_ms // 0)",
      "lost_percent=\(.sum.lost_percent // 0)",
      "packets=\(.sum.packets // 0)",
      "lost_packets=\(.sum.lost_packets // 0)",
      "duration=\(.sum.seconds)",
      "client_rc='"$client_rc"'",
      "server_rc='"$server_rc"'"
    end
  ' "$json" > "$summary" 2>/dev/null || {
    warn "Failed to parse iperf3 JSON for $scenario."
    echo "status=parse-error" > "$summary"
  }

  # Display quick summary
  if [[ -f "$summary" ]] && grep -q "status=ok" "$summary"; then
    log "--- $scenario results ---"
    grep -E "^(throughput_gbps|retransmits|lost_percent|jitter_ms|packets)=" "$summary" | while IFS='=' read -r key val; do
      log "  $key: $val"
    done
  fi

  write_runtime_kv "$(runtime_key_prefix "$scenario")_RESULT_DIR" "$d"
}

# --- Scenario wrappers ---

ensure_pods_deployed() {
  read_runtime
  auto_select_nodes
  if ! deployment_matches_request; then
    deploy_pods
    read_runtime
  fi
}

run_cross_node() {
  init_dirs
  require_cmd oc
  ensure_pods_deployed

  local d="$ARTIFACT_DIR/01-cross-node"
  collect_pod_baseline "iperf3-server" "$d"
  collect_pod_baseline "iperf3-client" "$d"

  local target_ip
  target_ip="$(get_target_ip pod)"
  run_iperf_test "cross-node" "$target_ip" "$d"
}

run_same_node() {
  init_dirs
  require_cmd oc
  read_runtime

  # For same-node, temporarily override client to use the server's node
  local orig_client="${IPERF_CLIENT_NODE:-}"
  local orig_force="${IPERF_FORCE_SAME_NODE:-false}"
  IPERF_FORCE_SAME_NODE="true"
  IPERF_CLIENT_NODE="${IPERF_SERVER_NODE:-}"

  # Redeploy pods on the same node
  deploy_pods
  read_runtime

  local d="$ARTIFACT_DIR/02-same-node"
  collect_pod_baseline "iperf3-server" "$d"
  collect_pod_baseline "iperf3-client" "$d"

  local target_ip
  target_ip="$(get_target_ip pod)"
  run_iperf_test "same-node" "$target_ip" "$d"

  # Restore original client node for subsequent tests
  IPERF_CLIENT_NODE="$orig_client"
  IPERF_FORCE_SAME_NODE="$orig_force"
}

run_host_network() {
  init_dirs
  require_cmd oc
  read_runtime

  # Temporarily enable host network
  local orig_host_net="${IPERF_HOST_NETWORK}"
  IPERF_HOST_NETWORK="true"

  deploy_pods
  read_runtime

  local d="$ARTIFACT_DIR/03-host-network"
  collect_pod_baseline "iperf3-server" "$d"
  collect_pod_baseline "iperf3-client" "$d"

  local target_ip
  target_ip="$(get_target_ip host)"
  run_iperf_test "host-network" "$target_ip" "$d"

  IPERF_HOST_NETWORK="$orig_host_net"
}

run_pod_to_service() {
  init_dirs
  require_cmd oc
  ensure_pods_deployed

  create_iperf_service

  local d="$ARTIFACT_DIR/04-pod-to-service"
  mkdir -p "$d"

  local svc_ip
  svc_ip="$(get_target_ip service)"
  [[ -n "$svc_ip" ]] || fail "Could not resolve iperf3-server Service ClusterIP."

  run_iperf_test "pod-to-service" "$svc_ip" "$d"
}

all_actions() {
  preflight
  deploy_pods
  run_cross_node
  ovn_diagnostics
  run_node_metrics
  report
}

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
  mkdir -p "$d"
  collect_pod_baseline "iperf3-server" "$d"
  collect_pod_baseline "iperf3-client" "$d"

  local target_ip
  target_ip="$(get_target_ip pod)"
  run_iperf_test "node-metrics" "$target_ip" "$d"

  IPERF_DURATION="$orig_duration"
  IPERF_PROTOCOL="$orig_protocol"
  IPERF_DEEP_METRICS="$orig_deep"
}
