#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/home/.kube"
: >"$TMP_DIR/home/.kube/config"
FAKE_OC_LOG="$TMP_DIR/fake-oc.log"
export FAKE_OC_LOG

cat >"$FAKE_BIN/oc" <<'FAKEOC'
#!/usr/bin/env bash
set -Eeuo pipefail

args="$*"
printf '%s\n' "$args" >>"${FAKE_OC_LOG:-/dev/null}"

case "$args" in
  version|whoami)
    echo "ok"
    exit 0
    ;;
  "get clusterversion version -o yaml"|\
  "get clusteroperators"|\
  "get networks.config/cluster -o yaml"|\
  "get network.operator/cluster -o yaml"|\
  "describe clusteroperator/network"|\
  "-n openshift-ovn-kubernetes get pods -o wide"|\
  "-n openshift-ovn-kubernetes get daemonsets -o wide"|\
  "-n openshift-ovn-kubernetes get events --sort-by=.metadata.creationTimestamp")
    echo "ok"
    exit 0
    ;;
  "get nodes -o wide")
    cat <<'NODES'
NAME     STATUS   ROLES    AGE   VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE   KERNEL-VERSION   CONTAINER-RUNTIME
node-a   Ready    worker   1d    v1.31.0   192.0.2.11     <none>        CoreOS     6.1.0            cri-o://1.31.0
node-b   Ready    worker   1d    v1.31.0   192.0.2.12     <none>        CoreOS     6.1.0            cri-o://1.31.0
NODES
    exit 0
    ;;
  "get nodes --no-headers")
    echo "node-a   Ready    worker   1d    v1.31.0"
    echo "node-b   Ready    worker   1d    v1.31.0"
    exit 0
    ;;
esac

# Network type
if [[ "${1:-}" == "get" && "${2:-}" == "networks.config/cluster" && "${3:-}" == "-o" ]]; then
  case "${4:-}" in
    "jsonpath={.status.networkType}") echo "OVNKubernetes" ;;
    "jsonpath={.status.clusterNetwork[0].cidr}") echo "10.128.0.0/14" ;;
    "jsonpath={.status.serviceNetwork[0]}") echo "172.30.0.0/16" ;;
    *) echo "ok" ;;
  esac
  exit 0
fi

# MTU
if [[ "${1:-}" == "get" && "${2:-}" == "network.operator/cluster" && "${3:-}" == "-o" ]]; then
  case "${4:-}" in
    "jsonpath={.status.defaultNetwork.ovnKubernetesConfig.mtu}") echo "1400" ;;
    *) echo "ok" ;;
  esac
  exit 0
fi

# Network operator conditions
if [[ "${1:-}" == "get" && "${2:-}" == "clusteroperator/network" && "${3:-}" == "-o" ]]; then
  case "${4:-}" in
    'jsonpath={.status.conditions[?(@.type=="Available")].status}') echo "True" ;;
    'jsonpath={.status.conditions[?(@.type=="Progressing")].status}') echo "False" ;;
    'jsonpath={.status.conditions[?(@.type=="Degraded")].status}') echo "False" ;;
    *) echo "ok" ;;
  esac
  exit 0
fi

# Worker node listing
if [[ "$args" == *"node-role.kubernetes.io/worker"* ]]; then
  echo "node-a"
  echo "node-b"
  exit 0
fi

# Node topology
if [[ "$args" == *"custom-columns=NAME"* ]]; then
  echo "node-a   Ready   true   192.0.2.11   zone-a"
  echo "node-b   Ready   true   192.0.2.12   zone-b"
  exit 0
fi

# Namespace and pod operations
if [[ "$args" == *"create namespace"* ]] || [[ "$args" == *"delete namespace"* ]]; then
  echo "runtime must not create or delete namespaces: $args" >&2
  exit 99
fi

if [[ "$args" == *"get ns network-validation"* ]] || \
   [[ "$args" == *"apply -f"* ]] || \
   [[ "$args" == *"wait pod"* ]] || \
   [[ "$args" == *"delete pod"* ]]; then
  echo "ok"
  exit 0
fi

if [[ "$args" == "-n network-validation get pod iperf3-server -o jsonpath={.status.podIP}" ]]; then
  echo "10.128.0.10"
  exit 0
fi

if [[ "$args" == "-n network-validation get pod iperf3-client -o jsonpath={.status.podIP}" ]]; then
  echo "10.129.0.10"
  exit 0
fi

if [[ "$args" == "-n network-validation get pod iperf3-server -o jsonpath={.status.hostIP}" ]]; then
  echo "192.0.2.11"
  exit 0
fi

if [[ "$args" == "-n network-validation get svc iperf3-server -o jsonpath={.spec.clusterIP}" ]]; then
  echo "172.30.99.99"
  exit 0
fi

# DB pod container list (tab-separated: pod-name TAB containers...) — simulates OCP 4.14+ where
# nbdb/sbdb live in ovnkube-node; must be matched before the field-selector queries below.
if [[ "$args" == *"get pods -l app=ovnkube-node"*'metadata.name}{"\t"}'* ]]; then
  printf 'ovnkube-node-a\tovn-controller nbdb sbdb northd ovnkube-controller \n'
  printf 'ovnkube-node-b\tovn-controller nbdb sbdb northd ovnkube-controller \n'
  exit 0
fi

# Node exec container list for first pod (used to detect the right exec container).
if [[ "$args" == *"get pods -l app=ovnkube-node"*"items[0].spec.containers"* ]]; then
  printf 'ovn-controller\nnbdb\nsbdb\nnorthd\novnkube-controller\n'
  exit 0
fi

if [[ "$args" == "-n openshift-ovn-kubernetes get pods -l app=ovnkube-control-plane -o jsonpath="* ]]; then
  echo "ovnkube-control-plane-a"
  exit 0
fi

if [[ "$args" == "-n openshift-ovn-kubernetes get pods -l app=ovnkube-node --field-selector spec.nodeName=node-a -o jsonpath={.items[0].metadata.name}" ]]; then
  echo "ovnkube-node-a"
  exit 0
fi

if [[ "$args" == "-n openshift-ovn-kubernetes get pods -l app=ovnkube-node --field-selector spec.nodeName=node-b -o jsonpath={.items[0].metadata.name}" ]]; then
  echo "ovnkube-node-b"
  exit 0
fi

if [[ "$args" == "-n openshift-ovn-kubernetes logs "* ]] || \
   [[ "$args" == "-n openshift-ovn-kubernetes exec "* ]]; then
  echo "ok"
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-server -- iperf3 -s -p 5201 -1 --json" ]]; then
  echo '{"start":{},"end":{}}'
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-server -- bash -c "*"ss -H -ltn"* ]]; then
  echo "ready"
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-server -- iperf3 --version" ]]; then
  echo "iperf 3.21 (cJSON 1.7.15)"
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-server -- /opt/network-validation/iperf3-collector.sh "* ]]; then
  echo "server collector complete"
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-client -- /opt/network-validation/iperf3-collector.sh "* ]]; then
  if [[ "${FAKE_IPERF_CLIENT_FAIL:-false}" == "true" ]]; then
    echo "simulated iperf failure" >&2
    exit 7
  fi
  echo "client collector complete"
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-client -- cat /tmp/network-validation-client/iperf3_client.json" ]]; then
  if [[ "${FAKE_IPERF_PROTOCOL:-tcp}" == "udp" ]]; then
    cat <<'IPERFJSON'
{
  "start": {},
  "end": {
    "sum": {
      "bits_per_second": 9500000000,
      "jitter_ms": 0.02,
      "lost_percent": 0,
      "packets": 100000,
      "lost_packets": 0,
      "seconds": 5
    }
  }
}
IPERFJSON
  else
    cat <<'IPERFJSON'
{
  "start": {},
  "end": {
    "sum_received": {
      "bits_per_second": 2500000000,
      "bytes": 1000,
      "seconds": 5
    },
    "sum_sent": {
      "retransmits": 0
    }
  }
}
IPERFJSON
  fi
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-client -- cat /tmp/network-validation-client/iperf3_client.rc" ]]; then
  echo "0"
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-server -- cat /tmp/network-validation-server/iperf3_server.rc" ]]; then
  echo "0"
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-client -- cat /tmp/network-validation-client/"* ]] || \
   [[ "$args" == "-n network-validation exec iperf3-server -- cat /tmp/network-validation-server/"* ]]; then
  echo "artifact"
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-client -- iperf3"* ]]; then
  if [[ "${FAKE_IPERF_CLIENT_FAIL:-false}" == "true" ]]; then
    echo "simulated iperf failure" >&2
    exit 7
  fi
  if [[ "$args" == *" -u "* ]]; then
    cat <<'IPERFJSON'
{
  "start": {},
  "end": {
    "sum": {
      "bits_per_second": 9500000000,
      "jitter_ms": 0.02,
      "lost_percent": 0,
      "packets": 100000,
      "lost_packets": 0,
      "seconds": 5
    }
  }
}
IPERFJSON
  else
    cat <<'IPERFJSON'
{
  "start": {},
  "end": {
    "sum_received": {
      "bits_per_second": 2500000000,
      "bytes": 1000,
      "seconds": 5
    },
    "sum_sent": {
      "retransmits": 0
    }
  }
}
IPERFJSON
  fi
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-client -- cat /tmp/metrics_"* ]]; then
  echo "metric"
  exit 0
fi

if [[ "$args" == "-n network-validation exec "* ]]; then
  echo "ok"
  exit 0
fi

echo "unexpected oc call: $args" >&2
exit 2
FAKEOC
chmod +x "$FAKE_BIN/oc"

ARTIFACT_DIR="$TMP_DIR/artifacts"

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
IPERF_NAMESPACE="network-validation"
IPERF_DURATION="5"
EOF

# --- Test 1: Config validation rejects bad values ---
BAD_CONFIG="$TMP_DIR/bad.env"
cat >"$BAD_CONFIG" <<EOF
ARTIFACT_DIR="$TMP_DIR/bad-artifacts"
IPERF_DURATION="abc"
EOF

set +e
env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$BAD_CONFIG" init >"$TMP_DIR/bad.out" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "invalid config should fail" >&2
  exit 1
fi
grep -Fq "IPERF_DURATION must be a positive integer" "$TMP_DIR/bad.out"

# --- Test 1b: TCP retransmit threshold must be an integer ---
BAD_RETRANSMITS_CONFIG="$TMP_DIR/bad-retransmits.env"
cat >"$BAD_RETRANSMITS_CONFIG" <<EOF
ARTIFACT_DIR="$TMP_DIR/bad-retransmits-artifacts"
IPERF_MAX_RETRANSMITS="0.5"
EOF

set +e
env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$BAD_RETRANSMITS_CONFIG" init >"$TMP_DIR/bad-retransmits.out" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "decimal IPERF_MAX_RETRANSMITS should fail" >&2
  exit 1
fi
grep -Fq "IPERF_MAX_RETRANSMITS must be a non-negative integer" "$TMP_DIR/bad-retransmits.out"

# --- Test 1c: Collector option parsing rejects missing values clearly ---
set +e
bash "$REPO_ROOT/network-validation/lib/iperf3-collector.sh" --role >"$TMP_DIR/collector-missing-value.out" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "collector option missing a value should fail" >&2
  exit 1
fi
grep -Fq "ERROR: --role requires a value" "$TMP_DIR/collector-missing-value.out"

# --- Test 1d: TCP server collector does not exit before starting iperf3 ---
cat >"$FAKE_BIN/iperf3" <<'FAKEIPERF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "iperf 3.19"
  exit 0
fi
printf '%s\n' "$*" >"${FAKE_IPERF_LOG:-/dev/null}"
printf '{"end":{}}\n'
FAKEIPERF
chmod +x "$FAKE_BIN/iperf3"

TCP_COLLECTOR_DIR="$TMP_DIR/tcp-collector"
FAKE_IPERF_LOG="$TMP_DIR/fake-iperf.log" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/lib/iperf3-collector.sh" \
    --role server \
    --protocol tcp \
    --interface eth0 \
    --output "$TCP_COLLECTOR_DIR" \
    --port 5201

test -f "$TCP_COLLECTOR_DIR/iperf3_server.rc"
grep -Fxq "0" "$TCP_COLLECTOR_DIR/iperf3_server.rc"
grep -Fq -- "-s -p 5201 -1 --json" "$TMP_DIR/fake-iperf.log"

# --- Test 2: --config without a path fails ---
set +e
env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config --yes init >"$TMP_DIR/missing-config.out" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "--config without path should fail" >&2
  exit 1
fi
grep -Fq -- "--config requires a file path" "$TMP_DIR/missing-config.out"

# --- Test 3: Init runs successfully ---
env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$CONFIG_FILE" init

test -f "$ARTIFACT_DIR/run-info.txt"
grep -Fq "IPERF_NAMESPACE=network-validation" "$ARTIFACT_DIR/run-info.txt"

# --- Test 4: Preflight captures network baseline ---
env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$CONFIG_FILE" preflight

test -f "$ARTIFACT_DIR/00-preflight/network-baseline.env"
grep -Fq "NETWORK_TYPE=OVNKubernetes" "$ARTIFACT_DIR/00-preflight/network-baseline.env"
grep -Fq "CLUSTER_MTU=1400" "$ARTIFACT_DIR/00-preflight/network-baseline.env"
test -f "$ARTIFACT_DIR/00-preflight/network-operator-gate.txt"
grep -Fq "Available=True" "$ARTIFACT_DIR/00-preflight/network-operator-gate.txt"

# --- Test 5: Report generates with Accepted verdict (when preflight is healthy) ---
env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$CONFIG_FILE" deploy

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$CONFIG_FILE" ovn-diagnostics

test -f "$ARTIFACT_DIR/06-ovn-diagnostics/ovnkube-control-plane-logs.txt"
test -f "$ARTIFACT_DIR/06-ovn-diagnostics/ovnkube-node-a-nbctl-show.txt"
test -f "$ARTIFACT_DIR/06-ovn-diagnostics/node-a-ovnkube-node-a-geneve-stats.txt"
test -f "$ARTIFACT_DIR/06-ovn-diagnostics/node-b-ovnkube-node-b-flow-count.txt"
grep -Fq "ovnkube-node-a -c nbdb -- ovn-nbctl show" "$FAKE_OC_LOG"
grep -Fq "ovnkube-node --field-selector spec.nodeName=node-a" "$FAKE_OC_LOG"
grep -Fq "ovnkube-node --field-selector spec.nodeName=node-b" "$FAKE_OC_LOG"

# Write a fake cross-node result so verdict can evaluate
mkdir -p "$ARTIFACT_DIR/01-cross-node"
cat >"$ARTIFACT_DIR/01-cross-node/iperf3_summary.txt" <<EOF
status=ok
protocol=tcp
throughput_gbps=2.5
retransmits=0
bytes=1000
duration=5
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$CONFIG_FILE" report

test -f "$ARTIFACT_DIR/07-report/network-validation-report.md"
grep -Fq -- "- Verdict: Accepted" "$ARTIFACT_DIR/07-report/network-validation-report.md"
grep -Fq "Throughput: 2.5 Gbps" "$ARTIFACT_DIR/07-report/network-validation-report.md"
grep -Fq "Protocol: tcp" "$ARTIFACT_DIR/07-report/network-validation-report.md"
grep -Fq "Server node: \`node-a\`" "$ARTIFACT_DIR/07-report/network-validation-report.md"
grep -Fq "Client node: \`node-b\`" "$ARTIFACT_DIR/07-report/network-validation-report.md"
grep -Fq "Socket buffer: system default" "$ARTIFACT_DIR/07-report/network-validation-report.md"
if grep -Fq -- "--window 256M" "$FAKE_OC_LOG"; then
  echo "default network validation should not force a large socket buffer" >&2
  exit 1
fi

# --- Test 6: Direct same-node action pins both pods to one node ---
SAME_ARTIFACT_DIR="$TMP_DIR/same-node-artifacts"
SAME_CONFIG="$TMP_DIR/same-node.env"
cat >"$SAME_CONFIG" <<EOF
ARTIFACT_DIR="$SAME_ARTIFACT_DIR"
IPERF_NAMESPACE="network-validation"
IPERF_DURATION="5"
IPERF_PROTOCOL="udp"
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$SAME_CONFIG" same-node

grep -Fq 'kubernetes.io/hostname: "node-a"' "$SAME_ARTIFACT_DIR/tmp/iperf3-server.yaml"
grep -Fq 'kubernetes.io/hostname: "node-a"' "$SAME_ARTIFACT_DIR/tmp/iperf3-client.yaml"
grep -Fq "name: network-validation-collector" "$SAME_ARTIFACT_DIR/tmp/iperf3-server.yaml"
grep -Fq "mountPath: /opt/network-validation" "$SAME_ARTIFACT_DIR/tmp/iperf3-client.yaml"

# Runtime variables written for hyphenated scenarios must remain sourceable.
(
  # shellcheck disable=SC1091
  source "$SAME_ARTIFACT_DIR/runtime.env"
  [[ -n "${SAME_NODE_RESULT_DIR:-}" ]]
)
test -f "$SAME_ARTIFACT_DIR/02-same-node/client/iperf3_client.json"
test -f "$SAME_ARTIFACT_DIR/02-same-node/server/iperf3_server.rc"
test -f "$SAME_ARTIFACT_DIR/02-same-node/ready-check.txt"
grep -Fxq "0" "$SAME_ARTIFACT_DIR/02-same-node/ready-check.txt.rc"
grep -Fq "ready-check" "$FAKE_OC_LOG"
grep -Fq "ss -H -ltn" "$FAKE_OC_LOG"
if grep -Fq "/dev/tcp/" "$FAKE_OC_LOG"; then
  echo "readiness check must not consume the single-shot iperf3 server connection" >&2
  exit 1
fi

# --- Test 7: Pod-to-service uses a real artifact dir and valid Service ports ---
SVC_ARTIFACT_DIR="$TMP_DIR/service-artifacts"
SVC_CONFIG="$TMP_DIR/service.env"
cat >"$SVC_CONFIG" <<EOF
ARTIFACT_DIR="$SVC_ARTIFACT_DIR"
IPERF_NAMESPACE="network-validation"
IPERF_DURATION="5"
IPERF_PROTOCOL="udp"
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" FAKE_IPERF_PROTOCOL="udp" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$SVC_CONFIG" pod-to-service

test -f "$SVC_ARTIFACT_DIR/04-pod-to-service/iperf3_summary.txt"
grep -Fq "name: tcp" "$SVC_ARTIFACT_DIR/tmp/iperf3-service.yaml"
grep -Fq "name: udp" "$SVC_ARTIFACT_DIR/tmp/iperf3-service.yaml"
(
  # shellcheck disable=SC1091
  source "$SVC_ARTIFACT_DIR/runtime.env"
  [[ -n "${POD_TO_SERVICE_RESULT_DIR:-}" ]]
)

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$SVC_CONFIG" report

grep -Fq "## Pod-to-service network" "$SVC_ARTIFACT_DIR/07-report/network-validation-report.md"
grep -Fq "Throughput: 9.5 Gbps" "$SVC_ARTIFACT_DIR/07-report/network-validation-report.md"

# --- Test 8: iperf client failures become reportable validation results ---
FAIL_ARTIFACT_DIR="$TMP_DIR/fail-artifacts"
FAIL_CONFIG="$TMP_DIR/fail.env"
cat >"$FAIL_CONFIG" <<EOF
ARTIFACT_DIR="$FAIL_ARTIFACT_DIR"
IPERF_NAMESPACE="network-validation"
IPERF_DURATION="5"
IPERF_PROTOCOL="udp"
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" FAKE_IPERF_CLIENT_FAIL="true" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$FAIL_CONFIG" cross-node

grep -Fq "status=error" "$FAIL_ARTIFACT_DIR/01-cross-node/iperf3_summary.txt"
grep -Fq "client_rc=7" "$FAIL_ARTIFACT_DIR/01-cross-node/iperf3_summary.txt"

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$FAIL_CONFIG" report

grep -Fq -- "- Verdict: Blocked" "$FAIL_ARTIFACT_DIR/07-report/network-validation-report.md"

# --- Test 9: Host-network metrics can run in best-effort restricted mode ---
BEST_EFFORT_ARTIFACT_DIR="$TMP_DIR/best-effort-artifacts"
BEST_EFFORT_CONFIG="$TMP_DIR/best-effort.env"
cat >"$BEST_EFFORT_CONFIG" <<EOF
ARTIFACT_DIR="$BEST_EFFORT_ARTIFACT_DIR"
IPERF_NAMESPACE="network-validation"
IPERF_DURATION="5"
IPERF_HOST_NETWORK="true"
IPERF_PRIVILEGED_MODE="false"
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$BEST_EFFORT_CONFIG" deploy

grep -Fq "hostNetwork: true" "$BEST_EFFORT_ARTIFACT_DIR/tmp/iperf3-server.yaml"
grep -Fq "hostPID: false" "$BEST_EFFORT_ARTIFACT_DIR/tmp/iperf3-server.yaml"
grep -Fq "privileged: false" "$BEST_EFFORT_ARTIFACT_DIR/tmp/iperf3-client.yaml"
if grep -Fq "runAsUser: 0" "$BEST_EFFORT_ARTIFACT_DIR/tmp/iperf3-client.yaml"; then
  echo "restricted best-effort pod must not request root runAsUser" >&2
  exit 1
fi

# --- Test 10: IPERF_PARALLEL accepts "auto" and positive integers, rejects 0 ---
PARALLEL_BAD_CONFIG="$TMP_DIR/bad-parallel.env"
cat >"$PARALLEL_BAD_CONFIG" <<EOF
ARTIFACT_DIR="$TMP_DIR/p-test"
IPERF_PARALLEL="0"
EOF

set +e
env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$PARALLEL_BAD_CONFIG" init \
  >"$TMP_DIR/bad-parallel.out" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "IPERF_PARALLEL=0 should be rejected" >&2
  exit 1
fi
grep -Fq "IPERF_PARALLEL must be auto or a positive integer" "$TMP_DIR/bad-parallel.out"

PARALLEL_AUTO_CONFIG="$TMP_DIR/auto-parallel.env"
cat >"$PARALLEL_AUTO_CONFIG" <<EOF
ARTIFACT_DIR="$TMP_DIR/p-auto"
IPERF_PARALLEL="auto"
EOF
env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$PARALLEL_AUTO_CONFIG" init
