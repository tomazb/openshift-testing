#!/usr/bin/env bash
# Pod deployment and cleanup for iperf3 server/client.
set -Eeuo pipefail

# Select two worker nodes for server and client placement.
# If IPERF_SERVER_NODE / IPERF_CLIENT_NODE are already set, respect them.
auto_select_nodes() {
  read_runtime
  if [[ -n "$IPERF_SERVER_NODE" && -n "$IPERF_CLIENT_NODE" && "${IPERF_FORCE_SAME_NODE:-false}" != "true" ]]; then
    return
  fi

  local nodes
  nodes="$(oc get nodes -l node-role.kubernetes.io/worker= --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)"
  if [[ -z "$nodes" ]]; then
    # Fallback: try all schedulable nodes (compact/SNO clusters may not have worker label)
    nodes="$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)"
  fi

  local node_array=()
  while IFS= read -r n; do
    [[ -n "$n" ]] && node_array+=("$n")
  done <<< "$nodes"

  if [[ ${#node_array[@]} -lt 1 ]]; then
    fail "No schedulable nodes found."
  fi

  if [[ -z "$IPERF_SERVER_NODE" ]]; then
    IPERF_SERVER_NODE="${node_array[0]}"
    write_runtime_kv IPERF_SERVER_NODE "$IPERF_SERVER_NODE"
  fi

  if [[ "${IPERF_FORCE_SAME_NODE:-false}" == "true" ]]; then
    IPERF_CLIENT_NODE="$IPERF_SERVER_NODE"
    write_runtime_kv IPERF_CLIENT_NODE "$IPERF_CLIENT_NODE"
  elif [[ -z "$IPERF_CLIENT_NODE" ]]; then
    if [[ ${#node_array[@]} -ge 2 ]]; then
      IPERF_CLIENT_NODE="${node_array[1]}"
    else
      # Single-node cluster: client and server on the same node
      IPERF_CLIENT_NODE="${node_array[0]}"
      warn "Only one node available; client and server will share the same node."
    fi
    write_runtime_kv IPERF_CLIENT_NODE "$IPERF_CLIENT_NODE"
  fi

  log "Node selection: server=$IPERF_SERVER_NODE client=$IPERF_CLIENT_NODE"
}

deployment_matches_request() {
  read_runtime
  [[ -n "${SERVER_POD_IP:-}" ]] || return 1
  [[ "${DEPLOYED_IPERF_SERVER_NODE:-}" == "${IPERF_SERVER_NODE:-}" ]] || return 1
  [[ "${DEPLOYED_IPERF_CLIENT_NODE:-}" == "${IPERF_CLIENT_NODE:-}" ]] || return 1
  [[ "${DEPLOYED_IPERF_HOST_NETWORK:-}" == "${IPERF_HOST_NETWORK:-false}" ]] || return 1
  [[ "${DEPLOYED_IPERF_PRIVILEGED_MODE:-}" == "$(effective_privileged_mode "${IPERF_HOST_NETWORK:-false}")" ]] || return 1
  [[ "${DEPLOYED_IPERF_NAMESPACE:-}" == "$IPERF_NAMESPACE" ]] || return 1
  [[ "${DEPLOYED_IPERF_IMAGE:-}" == "$IPERF_IMAGE" ]] || return 1
}

effective_privileged_mode() {
  local host_net="$1"
  if [[ -n "${IPERF_PRIVILEGED_MODE:-}" ]]; then
    echo "$IPERF_PRIVILEGED_MODE"
  else
    echo "$host_net"
  fi
}

yaml_literal_file() {
  local file="$1"
  sed 's/^/    /' "$file"
}

generate_collector_configmap() {
  local manifest="$ARTIFACT_DIR/tmp/network-validation-collector.yaml"
  local collector="$PROJECT_DIR/lib/iperf3-collector.sh"
  [[ -f "$collector" ]] || fail "Collector script missing: $collector"

  {
    cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: network-validation-collector
  namespace: ${IPERF_NAMESPACE}
data:
  iperf3-collector.sh: |
EOF
    yaml_literal_file "$collector"
  } > "$manifest"
}

# Generate a pod manifest for iperf3 server or client.
# Arguments: <pod-name> <node-name> <host-network: true|false>
generate_pod_manifest() {
  local pod_name="$1" node_name="$2" host_net="$3"
  local privileged
  privileged="$(effective_privileged_mode "$host_net")"

  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${IPERF_NAMESPACE}
  labels:
    app: iperf3
    role: ${pod_name}
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: "${node_name}"
  hostNetwork: ${host_net}
  hostPID: ${privileged}
  containers:
  - name: iperf3
    image: ${IPERF_IMAGE}
    command: ["sleep", "3600"]
    volumeMounts:
    - name: network-validation-collector
      mountPath: /opt/network-validation
      readOnly: true
    securityContext:
      privileged: ${privileged}
EOF
  if [[ "$privileged" == "true" ]]; then
    cat <<EOF
      runAsUser: 0
EOF
  fi
  cat <<EOF
  volumes:
  - name: network-validation-collector
    configMap:
      name: network-validation-collector
      defaultMode: 0755
EOF
}

deploy_pods() {
  init_dirs
  require_cmd oc
  read_runtime
  [[ -n "${NETWORK_TYPE:-}" ]] || { preflight; read_runtime; }

  auto_select_nodes

  ensure_namespace

  local host_net="${IPERF_HOST_NETWORK}"
  local privileged
  privileged="$(effective_privileged_mode "$host_net")"
  local server_manifest="$ARTIFACT_DIR/tmp/iperf3-server.yaml"
  local client_manifest="$ARTIFACT_DIR/tmp/iperf3-client.yaml"

  generate_collector_configmap
  generate_pod_manifest "iperf3-server" "$IPERF_SERVER_NODE" "$host_net" > "$server_manifest"
  generate_pod_manifest "iperf3-client" "$IPERF_CLIENT_NODE" "$host_net" > "$client_manifest"

  # Clean up any previous pods
  oc -n "$IPERF_NAMESPACE" delete pod/iperf3-server pod/iperf3-client --ignore-not-found=true >/dev/null 2>&1 || true

  run oc apply -f "$ARTIFACT_DIR/tmp/network-validation-collector.yaml"
  run oc apply -f "$server_manifest"
  run oc apply -f "$client_manifest"

  log "Waiting for pods to become Ready..."
  run_out "$ARTIFACT_DIR/tmp/server-wait.txt" oc -n "$IPERF_NAMESPACE" wait pod/iperf3-server --for=condition=Ready --timeout=180s
  local server_rc
  server_rc="$(results_read_artifact_rc "$ARTIFACT_DIR/tmp/server-wait.txt.rc")"
  [[ "$server_rc" == "0" ]] || fail "iperf3-server pod did not become Ready (rc=$server_rc)."

  run_out "$ARTIFACT_DIR/tmp/client-wait.txt" oc -n "$IPERF_NAMESPACE" wait pod/iperf3-client --for=condition=Ready --timeout=180s
  local client_rc
  client_rc="$(results_read_artifact_rc "$ARTIFACT_DIR/tmp/client-wait.txt.rc")"
  [[ "$client_rc" == "0" ]] || fail "iperf3-client pod did not become Ready (rc=$client_rc)."

  # Record pod IPs
  local server_pod_ip client_pod_ip server_host_ip
  server_pod_ip="$(oc -n "$IPERF_NAMESPACE" get pod iperf3-server -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  client_pod_ip="$(oc -n "$IPERF_NAMESPACE" get pod iperf3-client -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  server_host_ip="$(oc -n "$IPERF_NAMESPACE" get pod iperf3-server -o jsonpath='{.status.hostIP}' 2>/dev/null || true)"

  write_runtime_kv SERVER_POD_IP "$server_pod_ip"
  write_runtime_kv CLIENT_POD_IP "$client_pod_ip"
  write_runtime_kv SERVER_HOST_IP "$server_host_ip"
  write_runtime_kv DEPLOYED_IPERF_SERVER_NODE "$IPERF_SERVER_NODE"
  write_runtime_kv DEPLOYED_IPERF_CLIENT_NODE "$IPERF_CLIENT_NODE"
  write_runtime_kv DEPLOYED_IPERF_HOST_NETWORK "$host_net"
  write_runtime_kv DEPLOYED_IPERF_PRIVILEGED_MODE "$privileged"
  write_runtime_kv DEPLOYED_IPERF_NAMESPACE "$IPERF_NAMESPACE"
  write_runtime_kv DEPLOYED_IPERF_IMAGE "$IPERF_IMAGE"

  log "Pods deployed: server=$IPERF_SERVER_NODE ($server_pod_ip) client=$IPERF_CLIENT_NODE ($client_pod_ip)"
}

# Resolve the target IP the client should connect to.
# For host-network: returns the server's host IP (same as pod IP in hostNetwork mode).
# For pod-to-service: returns the ClusterIP.
# Default: returns the server's pod IP.
get_target_ip() {
  local mode="${1:-pod}"
  read_runtime
  case "$mode" in
    host)
      echo "${IPERF_SERVER_ADDRESS:-${SERVER_HOST_IP:-${SERVER_POD_IP:-}}}"
      ;;
    service)
      local svc_ip
      svc_ip="$(oc -n "$IPERF_NAMESPACE" get svc iperf3-server -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
      echo "$svc_ip"
      ;;
    *)
      echo "${IPERF_SERVER_ADDRESS:-${SERVER_POD_IP:-}}"
      ;;
  esac
}

# Create a ClusterIP Service fronting the iperf3-server pod.
create_iperf_service() {
  local manifest="$ARTIFACT_DIR/tmp/iperf3-service.yaml"
  cat > "$manifest" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: iperf3-server
  namespace: ${IPERF_NAMESPACE}
spec:
  selector:
    role: iperf3-server
  ports:
  - name: tcp
    port: ${IPERF_PORT}
    targetPort: ${IPERF_PORT}
    protocol: TCP
  - name: udp
    port: ${IPERF_PORT}
    targetPort: ${IPERF_PORT}
    protocol: UDP
EOF
  run oc apply -f "$manifest"
}

cleanup_action() {
  init_dirs
  read_runtime
  require_cmd oc
  if confirm "Delete namespace '$IPERF_NAMESPACE'?"; then
    run oc delete namespace "$IPERF_NAMESPACE" --ignore-not-found=true
  else
    log "Cleanup skipped."
  fi
}
