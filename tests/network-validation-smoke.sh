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
  "-n openshift-ovn-kubernetes get daemonsets -o wide")
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
if [[ "$args" == *"get ns network-validation"* ]] || \
   [[ "$args" == *"create namespace"* ]] || \
   [[ "$args" == *"apply -f"* ]] || \
   [[ "$args" == *"wait pod"* ]] || \
   [[ "$args" == *"delete pod"* ]] || \
   [[ "$args" == *"delete namespace"* ]]; then
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

if [[ "$args" == "-n network-validation exec iperf3-server -- iperf3 -s -p 5201 -1 --json" ]]; then
  echo '{"start":{},"end":{}}'
  exit 0
fi

if [[ "$args" == "-n network-validation exec iperf3-client -- iperf3"* ]]; then
  if [[ "${FAKE_IPERF_CLIENT_FAIL:-false}" == "true" ]]; then
    echo "simulated iperf failure" >&2
    exit 7
  fi
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
IPERF_PROTOCOL="udp"
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
# Write a fake cross-node result so verdict can evaluate
mkdir -p "$ARTIFACT_DIR/01-cross-node"
cat >"$ARTIFACT_DIR/01-cross-node/iperf3_summary.txt" <<EOF
status=ok
protocol=udp
throughput_gbps=9.5
jitter_ms=0.02
lost_percent=0
packets=100000
lost_packets=0
duration=5
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$CONFIG_FILE" report

test -f "$ARTIFACT_DIR/06-report/network-validation-report.md"
grep -Fq -- "- Verdict: Accepted" "$ARTIFACT_DIR/06-report/network-validation-report.md"
grep -Fq "Throughput: 9.5 Gbps" "$ARTIFACT_DIR/06-report/network-validation-report.md"

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

# Runtime variables written for hyphenated scenarios must remain sourceable.
# shellcheck disable=SC1091
source "$SAME_ARTIFACT_DIR/runtime.env"
grep -Fq "SAME_NODE_RESULT_DIR=" "$SAME_ARTIFACT_DIR/runtime.env"

# --- Test 7: Pod-to-service uses a real artifact dir and valid Service ports ---
SVC_ARTIFACT_DIR="$TMP_DIR/service-artifacts"
SVC_CONFIG="$TMP_DIR/service.env"
cat >"$SVC_CONFIG" <<EOF
ARTIFACT_DIR="$SVC_ARTIFACT_DIR"
IPERF_NAMESPACE="network-validation"
IPERF_DURATION="5"
IPERF_PROTOCOL="udp"
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$SVC_CONFIG" pod-to-service

test -f "$SVC_ARTIFACT_DIR/04-pod-to-service/iperf3_summary.txt"
grep -Fq "name: tcp" "$SVC_ARTIFACT_DIR/tmp/iperf3-service.yaml"
grep -Fq "name: udp" "$SVC_ARTIFACT_DIR/tmp/iperf3-service.yaml"
# shellcheck disable=SC1091
source "$SVC_ARTIFACT_DIR/runtime.env"
grep -Fq "POD_TO_SERVICE_RESULT_DIR=" "$SVC_ARTIFACT_DIR/runtime.env"

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/network-validation/bin/ocp-network-validate" --config "$SVC_CONFIG" report

grep -Fq "## Pod-to-service network" "$SVC_ARTIFACT_DIR/06-report/network-validation-report.md"
grep -Fq "Throughput: 9.5 Gbps" "$SVC_ARTIFACT_DIR/06-report/network-validation-report.md"

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

grep -Fq -- "- Verdict: Blocked" "$FAIL_ARTIFACT_DIR/06-report/network-validation-report.md"
