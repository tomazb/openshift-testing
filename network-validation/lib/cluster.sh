#!/usr/bin/env bash
# Cluster baseline and OpenShift network preflight.
set -Eeuo pipefail

init_action() {
  init_dirs
  require_cmd oc
  require_cmd awk
  require_cmd grep
  require_cmd jq
  run_out "$ARTIFACT_DIR/00-preflight/oc-version.txt" oc version
  run_out "$ARTIFACT_DIR/00-preflight/whoami.txt" oc whoami
  cat >"$ARTIFACT_DIR/run-info.txt" <<EOF
RUN_ID=$RUN_ID
ARTIFACT_DIR=$ARTIFACT_DIR
CONFIG_FILE=$CONFIG_FILE
IPERF_NAMESPACE=$IPERF_NAMESPACE
IPERF_IMAGE=$IPERF_IMAGE
IPERF_PROTOCOL=$IPERF_PROTOCOL
IPERF_DURATION=$IPERF_DURATION
EOF
  log "Initialization complete. Artifacts: $ARTIFACT_DIR"
}

preflight() {
  init_dirs
  require_cmd oc
  log "Capturing OpenShift network and cluster baseline."

  run_out "$ARTIFACT_DIR/00-preflight/oc-version.txt" oc version
  run_out "$ARTIFACT_DIR/00-preflight/whoami.txt" oc whoami
  run_out "$ARTIFACT_DIR/00-preflight/clusterversion.yaml" oc get clusterversion version -o yaml
  run_out "$ARTIFACT_DIR/00-preflight/clusteroperators.txt" oc get clusteroperators
  run_out "$ARTIFACT_DIR/00-preflight/nodes-wide.txt" oc get nodes -o wide
  run_out "$ARTIFACT_DIR/00-preflight/network-config.yaml" oc get networks.config/cluster -o yaml
  run_out "$ARTIFACT_DIR/00-preflight/network-operator.yaml" oc get network.operator/cluster -o yaml
  run_out "$ARTIFACT_DIR/00-preflight/clusteroperator-network.describe.txt" oc describe clusteroperator/network

  local network_type cluster_cidr service_cidr mtu node_count
  network_type="$(oc get networks.config/cluster -o jsonpath='{.status.networkType}' 2>/dev/null || true)"
  cluster_cidr="$(oc get networks.config/cluster -o jsonpath='{.status.clusterNetwork[0].cidr}' 2>/dev/null || true)"
  service_cidr="$(oc get networks.config/cluster -o jsonpath='{.status.serviceNetwork[0]}' 2>/dev/null || true)"
  mtu="$(oc get network.operator/cluster -o jsonpath='{.status.defaultNetwork.ovnKubernetesConfig.mtu}' 2>/dev/null || true)"
  [[ -n "$mtu" ]] || mtu="$(oc get network.operator/cluster -o jsonpath='{.status.defaultNetwork.openshiftSDNConfig.mtu}' 2>/dev/null || true)"
  node_count="$(oc get nodes --no-headers 2>/dev/null | wc -l | awk '{print $1}')"

  write_runtime_kv NETWORK_TYPE "$network_type"
  write_runtime_kv CLUSTER_CIDR "$cluster_cidr"
  write_runtime_kv SERVICE_CIDR "$service_cidr"
  write_runtime_kv CLUSTER_MTU "${mtu:-unknown}"
  write_runtime_kv NODE_COUNT "$node_count"

  # Node topology with roles and IPs
  run_out "$ARTIFACT_DIR/00-preflight/node-topology.txt" \
    oc get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1:].type,ROLES:'.metadata.labels.node-role\.kubernetes\.io/worker',INTERNAL-IP:'.status.addresses[?(@.type=="InternalIP")].address',ZONE:'.metadata.labels.topology\.kubernetes\.io/zone' --no-headers

  # Network operator conditions
  local net_available net_progressing net_degraded
  net_available="$(oc get clusteroperator/network -o 'jsonpath={.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  net_progressing="$(oc get clusteroperator/network -o 'jsonpath={.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)"
  net_degraded="$(oc get clusteroperator/network -o 'jsonpath={.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)"

  {
    echo "Available=$net_available"
    echo "Progressing=$net_progressing"
    echo "Degraded=$net_degraded"
    echo "Expected: Available=True, Progressing=False, Degraded=False"
  } >"$ARTIFACT_DIR/00-preflight/network-operator-gate.txt"

  write_runtime_kv NET_AVAILABLE "$net_available"
  write_runtime_kv NET_PROGRESSING "$net_progressing"
  write_runtime_kv NET_DEGRADED "$net_degraded"

  # OVN-Kubernetes pod health (if applicable)
  if [[ "$network_type" == "OVNKubernetes" ]]; then
    run_out "$ARTIFACT_DIR/00-preflight/ovn-pods.txt" oc -n openshift-ovn-kubernetes get pods -o wide
    run_out "$ARTIFACT_DIR/00-preflight/ovn-daemonset.txt" oc -n openshift-ovn-kubernetes get daemonsets -o wide
  fi

  cat >"$ARTIFACT_DIR/00-preflight/network-baseline.env" <<EOF
NETWORK_TYPE=$network_type
CLUSTER_CIDR=$cluster_cidr
SERVICE_CIDR=$service_cidr
CLUSTER_MTU=${mtu:-unknown}
NODE_COUNT=$node_count
NET_AVAILABLE=$net_available
NET_PROGRESSING=$net_progressing
NET_DEGRADED=$net_degraded
EOF

  log "Network type: ${network_type:-unknown}; MTU: ${mtu:-unknown}; nodes: $node_count; CIDRs: pod=${cluster_cidr:-unknown} svc=${service_cidr:-unknown}."
}

# --- OVN-Kubernetes diagnostics ---
ovn_diagnostics() {
  init_dirs
  require_cmd oc
  read_runtime
  [[ -n "${NETWORK_TYPE:-}" ]] || { preflight; read_runtime; }

  if [[ "${NETWORK_TYPE:-}" != "OVNKubernetes" ]]; then
    log "Skipping OVN diagnostics: network type is ${NETWORK_TYPE:-unknown}, not OVNKubernetes."
    return 0
  fi

  local d="$ARTIFACT_DIR/05-ovn-diagnostics"
  local rc=0
  mkdir -p "$d"

  log "Capturing OVN-Kubernetes diagnostics."

  run_out "$d/ovn-pods.txt" oc -n openshift-ovn-kubernetes get pods -o wide
  run_out "$d/ovn-daemonsets.txt" oc -n openshift-ovn-kubernetes get daemonsets -o wide
  run_out "$d/ovn-events.txt" oc -n openshift-ovn-kubernetes get events --sort-by=.metadata.creationTimestamp

  local control_plane_pod_file="$d/ovnkube-control-plane-pods.txt"
  if run_out_checked "$control_plane_pod_file" oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-control-plane -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}'; then
    local control_plane_pod
    control_plane_pod="$(awk 'NF {print; exit}' "$control_plane_pod_file")"
    if [[ -n "$control_plane_pod" ]]; then
      run_out "$d/${control_plane_pod}-logs.txt" oc -n openshift-ovn-kubernetes logs "$control_plane_pod" --all-containers --tail=500 || rc=1
      run_out "$d/${control_plane_pod}-nbctl-show.txt" oc -n openshift-ovn-kubernetes exec "$control_plane_pod" -c nbdb -- ovn-nbctl show || rc=1
      run_out "$d/${control_plane_pod}-sbctl-show.txt" oc -n openshift-ovn-kubernetes exec "$control_plane_pod" -c sbdb -- ovn-sbctl show || rc=1
    else
      warn "No ovnkube-control-plane pod found for OVN database diagnostics."
      rc=1
    fi
  else
    rc=1
  fi

  local participant_nodes=()
  if [[ -n "${DEPLOYED_IPERF_SERVER_NODE:-${IPERF_SERVER_NODE:-}}" ]]; then
    participant_nodes+=("${DEPLOYED_IPERF_SERVER_NODE:-${IPERF_SERVER_NODE:-}}")
  fi
  if [[ -n "${DEPLOYED_IPERF_CLIENT_NODE:-${IPERF_CLIENT_NODE:-}}" && "${DEPLOYED_IPERF_CLIENT_NODE:-${IPERF_CLIENT_NODE:-}}" != "${participant_nodes[0]:-}" ]]; then
    participant_nodes+=("${DEPLOYED_IPERF_CLIENT_NODE:-${IPERF_CLIENT_NODE:-}}")
  fi

  local node_pod_file="$d/ovnkube-node-pods.txt"
  : > "$node_pod_file"
  if [[ ${#participant_nodes[@]} -gt 0 ]]; then
    local node node_pod
    for node in "${participant_nodes[@]}"; do
      node_pod="$(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node --field-selector "spec.nodeName=$node" -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -z "$node_pod" ]]; then
        warn "No ovnkube-node pod found on participant node $node."
        rc=1
        continue
      fi
      printf '%s %s\n' "$node" "$node_pod" >> "$node_pod_file"
    done
  else
    warn "No deployed participant nodes available; falling back to the first ovnkube-node pod."
    if run_out_checked "$node_pod_file" oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}'; then
      local first_node_pod
      first_node_pod="$(awk 'NF {print; exit}' "$node_pod_file")"
      printf 'unknown-node %s\n' "$first_node_pod" > "$node_pod_file"
    else
      rc=1
    fi
  fi

  local node_label pod
  while read -r node_label pod; do
    [[ -n "$node_label" && -n "${pod:-}" ]] || continue

    run_out "$d/${node_label}-${pod}-logs.txt" oc -n openshift-ovn-kubernetes logs "$pod" --all-containers --tail=500 || rc=1
    run_out "$d/${node_label}-${pod}-geneve-stats.txt" oc -n openshift-ovn-kubernetes exec "$pod" -c ovnkube-node -- ip -s link show genev_sys_6081 || rc=1
    run_out "$d/${node_label}-${pod}-ovn-mp0-stats.txt" oc -n openshift-ovn-kubernetes exec "$pod" -c ovnkube-node -- ip -s link show ovn-k8s-mp0 || rc=1
    run_out "$d/${node_label}-${pod}-flow-count.txt" oc -n openshift-ovn-kubernetes exec "$pod" -c ovnkube-node -- ovs-ofctl dump-aggregate br-int || rc=1
  done <"$node_pod_file"

  echo "$rc" >"$d/ovn-diagnostics.rc"
  if [[ "$rc" -eq 0 ]]; then
    log "OVN diagnostics captured: $d"
  else
    warn "OVN diagnostics incomplete; see $d"
  fi
  return 0
}
