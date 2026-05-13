#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/home/.kube"
: >"$TMP_DIR/home/.kube/config"

cat >"$FAKE_BIN/oc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

args="$*"

case "$args" in
  version|whoami|\
  "get clusterversion version -o yaml"|\
  "get clusteroperators"|\
  "get networks.config/cluster -o yaml"|\
  "get dns.operator/default -o yaml"|\
  "describe dns.operator/default"|\
  "describe clusteroperator/dns"|\
  "-n openshift-dns get all -o wide"|\
  "-n openshift-dns-operator get all -o wide"|\
  "-n openshift-dns get pods,daemonsets,deployments,services,endpoints -o wide"|\
  "-n openshift-dns-operator get pods,deployments,services -o wide"|\
  "-n openshift-dns get events --sort-by=.metadata.creationTimestamp"|\
  "-n openshift-dns-operator get events --sort-by=.metadata.creationTimestamp"|\
  "-n openshift-dns get endpointslices.discovery.k8s.io -o wide")
    echo "ok"
    exit 0
    ;;
  "get nodes -o wide")
    cat <<'NODES'
NAME     STATUS   ROLES    AGE   VERSION   INTERNAL-IP
node-a   Ready    worker   1d    v1.31.0   192.0.2.11
NODES
    exit 0
    ;;
  "-n openshift-dns get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase --no-headers")
    echo "dns-default-a node-a Running"
    exit 0
    ;;
  "get dns.operator/default -o jsonpath={range .spec.upstreamResolvers.upstreams[*]}{.type}{\" \"}{.address}{\" \"}{.port}{\"\\n\"}{end}")
    echo "SystemResolvConf  53"
    exit 0
    ;;
  "get ns dns-validation"|\
  "apply -f "*|\
  "-n dns-validation rollout status ds/dns-sweep --timeout=180s"|\
  "-n dns-validation delete pod/dnsperf configmap/dnsperf-queries --ignore-not-found=true"|\
  "-n dns-validation create configmap dnsperf-queries --from-file=queries.txt="*|\
  "-n dns-validation wait pod/dnsperf --for=condition=Ready --timeout=180s")
    echo "ok"
    exit 0
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

if [[ "${1:-}" == "get" && "${2:-}" == "dns.operator/default" && "${3:-}" == "-o" ]]; then
  case "${4:-}" in
    "jsonpath={.status.clusterIP}") echo "172.30.0.10" ;;
    "jsonpath={.status.clusterDomain}") echo "cluster.local" ;;
    *) echo "unexpected dns.operator jsonpath: ${4:-}" >&2; exit 2 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "ingresses.config.openshift.io/cluster" && "${3:-}" == "-o" ]]; then
  [[ "${4:-}" == "jsonpath={.spec.domain}" ]] || { echo "unexpected ingress jsonpath: ${4:-}" >&2; exit 2; }
  echo "apps.example.test"
  exit 0
fi

if [[ "${1:-}" == "-n" && "${2:-}" == "openshift-console" && "${3:-}" == "get" ]]; then
  [[ "${7:-}" == "jsonpath={.spec.host}" ]] || { echo "unexpected console jsonpath: ${7:-}" >&2; exit 2; }
  echo "console.apps.example.test"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "clusterversion" && "${3:-}" == "version" && "${4:-}" == "-o" ]]; then
  [[ "${5:-}" == "jsonpath={.status.desired.image}" ]] || { echo "unexpected clusterversion jsonpath: ${5:-}" >&2; exit 2; }
  echo "quay.io/openshift-release-dev/ocp-release:test"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "networks.config/cluster" && "${3:-}" == "-o" ]]; then
  [[ "${4:-}" == "jsonpath={.status.networkType}" ]] || { echo "unexpected network jsonpath: ${4:-}" >&2; exit 2; }
  echo "OVNKubernetes"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "clusteroperator/dns" && "${3:-}" == "-o" ]]; then
  case "${4:-}" in
    'jsonpath={.status.conditions[?(@.type=="Available")].status}') echo "True" ;;
    'jsonpath={.status.conditions[?(@.type=="Progressing")].status}') echo "False" ;;
    'jsonpath={.status.conditions[?(@.type=="Degraded")].status}') echo "False" ;;
    *) echo "unexpected clusteroperator jsonpath: ${4:-}" >&2; exit 2 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "-n" && "${2:-}" == "dns-validation" && "${3:-}" == "exec" && "${4:-}" == "dns-sweep-a" ]]; then
  cat <<'LOOKUPS'
Server: 172.30.0.10
Name: kubernetes.default.svc.cluster.local
Address: 172.30.0.1
Server: 172.30.0.10
Name: openshift.default.svc.cluster.local
Address: 172.30.0.1
Server: 172.30.0.10
Name: registry.redhat.io
Address: 192.0.2.10
LOOKUPS
  exit 0
fi

if [[ "${1:-}" == "-n" && "${2:-}" == "dns-validation" && "${3:-}" == "exec" && "${4:-}" == "dnsperf" ]]; then
  cat <<'DNSPERF'
Statistics:
  Queries sent:         6000
  Queries completed:    6000 (100.00%)
  Queries lost:         0 (0.00%)
  Response codes:       NOERROR 6000 (100.00%)
  Queries per second:   100.000000
  Average Latency (s):  0.000200 (min 0.000100, max 0.010000)
  Latency StdDev (s):   0.000300
DNSPERF
  exit 0
fi

echo "unexpected oc call: $args" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR/04-perf-tests"
echo "0" >"$ARTIFACT_DIR/04-perf-tests/perf-tests-run.rc"

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
PULL_SECRET_FILE="$TMP_DIR/missing-pull-secret.json"
DNSPERF_QPS_STEPS="100"
DNSPERF_DURATION_SECONDS="1"
DNSPERF_CLIENTS="1"
DNSPERF_THREADS="1"
DNSPERF_STATS_INTERVAL="1"
QUERY_REPEAT_COUNT="1"
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" all

# Sentinel must be created
[[ -f "$ARTIFACT_DIR/01-openshift-tests/pull-secret-skipped" ]] || {
  echo "pull-secret-skipped sentinel not created" >&2; exit 1
}

# Conformance binary must not exist
[[ ! -x "$ARTIFACT_DIR/01-openshift-tests/openshift-tests" ]] || {
  echo "openshift-tests binary should not exist after pull-secret skip" >&2; exit 1
}

# dnsperf and node-sweep must have produced output
test -s "$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
grep -Fq "### pod=dns-sweep-a node=node-a" "$ARTIFACT_DIR/02-node-sweep/node-dns-sweep.txt"

# Report must exist and contain skip notice and risk verdict
REPORT="$ARTIFACT_DIR/05-report/dns-validation-report.md"
test -s "$REPORT"
grep -Fq "Skipped — pull secret not configured" "$REPORT"
grep -Fq "Accepted with risks" "$REPORT"
! grep -Fq "Verdict: Blocked" "$REPORT" || {
  echo "report must not contain 'Blocked' verdict when tests were skipped due to missing pull secret" >&2; exit 1
}
