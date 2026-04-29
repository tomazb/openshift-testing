#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/oc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"

case "$args" in
  "get ns dns-validation"|\
  "apply -f "*|\
  "-n dns-validation delete pod/dnsperf configmap/dnsperf-queries --ignore-not-found=true"|\
  "-n dns-validation create configmap dnsperf-queries --from-file=queries.txt="*)
    echo "ok"
    exit 0
    ;;
  "-n dns-validation rollout status ds/dns-sweep --timeout=180s")
    echo "rollout timed out" >&2
    exit 1
    ;;
  "-n dns-validation wait pod/dnsperf --for=condition=Ready --timeout=180s")
    echo "pod never became ready" >&2
    exit 1
    ;;
  "-n dns-validation get pod -l app=dns-sweep -o jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
    echo "dns-sweep-a"
    exit 0
    ;;
  "-n dns-validation get pod dns-sweep-a -o jsonpath={.spec.nodeName}")
    echo "node-a"
    exit 0
    ;;
esac

if [[ "${1:-}" == "-n" && "${2:-}" == "dns-validation" && "${3:-}" == "exec" ]]; then
  echo "exec should not run after readiness failure" >&2
  exit 2
fi

echo "unexpected oc call: $args" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR/03-dnsperf"
cat >"$ARTIFACT_DIR/runtime.env" <<EOF
CLUSTER_DNS_IP=172.30.0.10
CLUSTER_DOMAIN=cluster.example.test
DNSPERF_QUERY_FILE=$ARTIFACT_DIR/03-dnsperf/queries.ocp.txt
EOF
printf 'kubernetes.default.svc.cluster.example.test A\n' >"$ARTIFACT_DIR/03-dnsperf/queries.ocp.txt"

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
DNS_SWEEP_IMAGE="registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3"
DNSPERF_IMAGE="docker.io/guessi/dnsperf:2.15.1-1"
DNSPERF_QPS_STEPS="100"
DNSPERF_DURATION_SECONDS="1"
DNSPERF_CLIENTS="1"
DNSPERF_THREADS="1"
DNSPERF_STATS_INTERVAL="1"
EOF

set +e
PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" node-sweep >"$TMP_DIR/node-sweep.out" 2>&1
node_rc=$?
PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" dnsperf >"$TMP_DIR/dnsperf.out" 2>&1
dnsperf_rc=$?
set -e

if [[ "$node_rc" -eq 0 ]]; then
  echo "node-sweep should fail when dns-sweep rollout fails" >&2
  cat "$TMP_DIR/node-sweep.out" >&2
  exit 1
fi
grep -Fq "dns-sweep rollout failed" "$TMP_DIR/node-sweep.out"

if [[ "$dnsperf_rc" -eq 0 ]]; then
  echo "dnsperf should fail when pod readiness wait fails" >&2
  cat "$TMP_DIR/dnsperf.out" >&2
  exit 1
fi
grep -Fq "dnsperf pod did not become Ready" "$TMP_DIR/dnsperf.out"
