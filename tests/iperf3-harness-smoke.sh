#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
FAKE_STATE_DIR="$TMP_DIR/state"
export FAKE_STATE_DIR
mkdir -p "$FAKE_BIN" "$FAKE_STATE_DIR" "$TMP_DIR/home/.kube"
: >"$TMP_DIR/home/.kube/config"

cat >"$FAKE_BIN/oc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

args="$*"
printf '%s\n' "$args" >>"$FAKE_STATE_DIR/oc-calls.log"

case "$args" in
  version|whoami|\
  "get ns iperf3-validation"|\
  "get nodes -o wide"|\
  "get node node-a -o name"|\
  "get node node-b -o name")
    echo "ok"
    exit 0
    ;;
  "get node node-a -o jsonpath={.status.addresses[?(@.type==\"InternalIP\")].address}")
    echo "192.0.2.10"
    exit 0
    ;;
  "apply -f "*)
    echo "ok"
    exit 0
    ;;
  "-n iperf3-validation wait pod/iperf3-server --for=condition=Ready --timeout=120s"|\
  "-n iperf3-validation wait pod/iperf3-client --for=condition=Ready --timeout=180s")
    echo "ready"
    exit 0
    ;;
  "-n iperf3-validation logs iperf3-client")
    cat <<'LOGS'
iperf3 summary
Client test complete. Results in /tmp/iperf3-client
LOGS
    exit 0
    ;;
  "-n iperf3-validation logs iperf3-server")
    echo "server complete"
    exit 0
    ;;
  "-n iperf3-validation cp iperf3-client:/tmp/iperf3-client "*|\
  "-n iperf3-validation cp iperf3-server:/tmp/iperf3-server "*)
    mkdir -p "${@: -1}"
    if [[ "$args" == *"iperf3-client"* ]]; then
      cat >"${@: -1}/iperf3_client.json" <<'JSON'
{"end":{"sum_received":{"bits_per_second":2500000000,"bytes":1000},"sum_sent":{"retransmits":0}}}
JSON
      echo "0" >"${@: -1}/iperf3_client.rc"
    else
      echo "0" >"${@: -1}/iperf3_server.rc"
    fi
    exit 0
    ;;
  "delete namespace iperf3-validation --ignore-not-found=true")
    echo "deleted"
    exit 0
    ;;
esac

if [[ "${1:-}" == "create" && "${2:-}" == "namespace" && "${3:-}" == "iperf3-validation" ]]; then
  echo "created"
  exit 0
fi

echo "unexpected oc call: $args" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

ARTIFACT_DIR="$TMP_DIR/artifacts"
CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="iperf3-validation"
IPERF3_SERVER_NODE="node-a"
IPERF3_CLIENT_NODE="node-b"
IPERF3_IMAGE="ghcr.io/tomazb/openshift-testing/network-testing-image:latest"
IPERF3_DURATION_SECONDS="3"
IPERF3_PRIVILEGED_MODE="true"
IPERF3_MIN_TCP_GBPS="2"
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/iperf3-validation/bin/ocp-iperf3-validate" --config "$CONFIG_FILE" all

MANIFEST="$ARTIFACT_DIR/01-run/iperf3-pair.yaml"
REPORT="$ARTIFACT_DIR/02-report/iperf3-validation-report.md"

grep -Fq "nodeSelector:" "$MANIFEST"
grep -Fq "kubernetes.io/hostname: node-a" "$MANIFEST"
grep -Fq "kubernetes.io/hostname: node-b" "$MANIFEST"
grep -Fq "hostNetwork: true" "$MANIFEST"
grep -Fq "hostPID: true" "$MANIFEST"
grep -Fq "privileged: true" "$MANIFEST"
grep -Fq -- "--protocol" "$MANIFEST"
grep -Fq "tcp" "$MANIFEST"
grep -Fq -- "--duration" "$MANIFEST"
grep -Fq "3" "$MANIFEST"
grep -Fq "192.0.2.10" "$MANIFEST"
grep -Fq "network-testing-image:latest" "$MANIFEST"

grep -Fq "Accepted" "$REPORT"
grep -Fq "2.50 Gbps" "$REPORT"
test -s "$ARTIFACT_DIR/ocp-iperf3-validate.log"
grep -Fq "wait pod/iperf3-server" "$FAKE_STATE_DIR/oc-calls.log"
grep -Fq "wait pod/iperf3-client" "$FAKE_STATE_DIR/oc-calls.log"

BEST_EFFORT_ARTIFACTS="$TMP_DIR/best-effort-artifacts"
BEST_EFFORT_CONFIG="$TMP_DIR/best-effort.env"
cat >"$BEST_EFFORT_CONFIG" <<EOF
ARTIFACT_DIR="$BEST_EFFORT_ARTIFACTS"
VALIDATION_NAMESPACE="iperf3-validation"
IPERF3_SERVER_NODE="node-a"
IPERF3_CLIENT_NODE="node-b"
IPERF3_SERVER_ADDRESS="192.0.2.10"
IPERF3_PRIVILEGED_MODE="false"
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/iperf3-validation/bin/ocp-iperf3-validate" --config "$BEST_EFFORT_CONFIG" run-pair

BEST_EFFORT_MANIFEST="$BEST_EFFORT_ARTIFACTS/01-run/iperf3-pair.yaml"
grep -Fq "hostNetwork: true" "$BEST_EFFORT_MANIFEST"
grep -Fq "hostPID: false" "$BEST_EFFORT_MANIFEST"
if grep -Fq "privileged: true" "$BEST_EFFORT_MANIFEST"; then
  echo "best-effort manifest must not request privileged containers" >&2
  exit 1
fi
