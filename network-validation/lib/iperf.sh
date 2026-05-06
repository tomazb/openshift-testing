#!/usr/bin/env bash
# iperf3 test execution across topology scenarios.
set -Eeuo pipefail

# Run an iperf3 test between server and client pods.
# Arguments: <scenario-name> <target-ip> <artifact-subdir>
# The server pod must already be deployed.
run_iperf_test() {
  local scenario="$1" target_ip="$2" d="$3"
  mkdir -p "$d"

  [[ -n "$target_ip" ]] || fail "No target IP for scenario $scenario."
  log "Running iperf3 $scenario test: client -> $target_ip (${IPERF_PROTOCOL}, ${IPERF_DURATION}s)"

  local command_timeout=$((IPERF_DURATION + 30))

  # Start iperf3 server inside the server pod
  log "Starting iperf3 server in pod iperf3-server..."
  timeout "$command_timeout" oc -n "$IPERF_NAMESPACE" exec iperf3-server -- \
    iperf3 -s -p "$IPERF_PORT" -1 --json \
    > "$d/iperf3_server.json" 2>"$d/iperf3_server.stderr" &
  local server_pid=$!

  # Brief pause to let server bind
  sleep 2

  # Start metric collection on client pod
  local METRICS_EXEC_PID=""
  start_pod_metrics "iperf3-client" "$d" "$IPERF_DURATION"

  # Build iperf3 client args
  local iperf_args=(-c "$target_ip" -p "$IPERF_PORT" -t "$IPERF_DURATION"
                    -w "$IPERF_SOCKET_BUFFER" -P "$IPERF_PARALLEL" --json)
  if [[ "$IPERF_PROTOCOL" == "udp" ]]; then
    iperf_args+=(-u -b "$IPERF_BANDWIDTH" -l "$IPERF_PACKET_SIZE")
  fi

  log "Running: iperf3 ${iperf_args[*]}"
  local client_rc=0
  timeout "$command_timeout" oc -n "$IPERF_NAMESPACE" exec iperf3-client -- \
    iperf3 "${iperf_args[@]}" \
    > "$d/iperf3_client.json" 2>"$d/iperf3_client.stderr" || client_rc=$?
  echo "$client_rc" > "$d/iperf3_client.rc"

  # Wait for server to finish (it runs with -1 for single test)
  local server_rc=0
  wait "$server_pid" 2>/dev/null || server_rc=$?
  echo "$server_rc" > "$d/iperf3_server.rc"

  # Wait for metric collection to finish and retrieve
  if [[ -n "$METRICS_EXEC_PID" ]]; then
    wait "$METRICS_EXEC_PID" 2>/dev/null || true
  fi
  retrieve_pod_metrics "iperf3-client" "$d"

  # Collect post-test snapshots
  collect_pod_posttest "iperf3-server" "$d"
  collect_pod_posttest "iperf3-client" "$d"

  # Parse and display results
  parse_iperf_results "$d" "$scenario"
}

# Parse iperf3 JSON output and write a summary.
# Arguments: <artifact-dir> <scenario-name>
parse_iperf_results() {
  local d="$1" scenario="$2"
  local json="$d/iperf3_client.json"
  local summary="$d/iperf3_summary.txt"
  local client_rc server_rc

  client_rc="$(results_read_artifact_rc "$d/iperf3_client.rc")"
  server_rc="$(results_read_artifact_rc "$d/iperf3_server.rc")"

  if [[ "$client_rc" != "0" ]]; then
    warn "iperf3 client failed for $scenario (rc=$client_rc)."
    {
      echo "status=error"
      echo "client_rc=$client_rc"
      echo "server_rc=$server_rc"
      echo "client_stderr=$d/iperf3_client.stderr"
      echo "server_stderr=$d/iperf3_server.stderr"
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
      echo "client_stderr=$d/iperf3_client.stderr"
      echo "server_stderr=$d/iperf3_server.stderr"
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
  report
}
