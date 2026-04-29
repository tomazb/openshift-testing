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
  "-n openshift-dns get pods -o jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
    echo "dns-default-a"
    exit 0
    ;;
  "-n openshift-dns-operator get pods -o jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
    echo "dns-operator-a"
    exit 0
    ;;
  "-n openshift-dns logs dns-default-a --all-containers --tail=-1")
    echo "dns pod log"
    exit 0
    ;;
  "-n openshift-dns-operator logs dns-operator-a --all-containers --tail=-1")
    echo "operator pod log"
    exit 0
    ;;
  "-n openshift-dns describe pod dns-default-a")
    echo "dns pod describe"
    exit 0
    ;;
  "-n openshift-dns get events --sort-by=.metadata.creationTimestamp"|\
  "-n openshift-dns-operator get events --sort-by=.metadata.creationTimestamp"|\
  "-n dns-validation get events --sort-by=.metadata.creationTimestamp")
    echo "events"
    exit 0
    ;;
esac

echo "unexpected oc call: $args" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR/00-preflight" "$ARTIFACT_DIR/01-openshift-tests" "$ARTIFACT_DIR/02-node-sweep" "$ARTIFACT_DIR/03-dnsperf" "$ARTIFACT_DIR/04-perf-tests" "$ARTIFACT_DIR/05-report"

cat >"$ARTIFACT_DIR/00-preflight/dns-operator-gate.txt" <<'EOF'
Available=False
Progressing=False
Degraded=True
Expected: Available=True, Progressing=False, Degraded=False
EOF

cat >"$ARTIFACT_DIR/01-openshift-tests/dns-summary.txt" <<'EOF'
passed: (1s) "dns lookup"
EOF
echo "0" >"$ARTIFACT_DIR/01-openshift-tests/dns-test-output.rc"
echo '"dns lookup"' >"$ARTIFACT_DIR/01-openshift-tests/dns-tests.txt"
: >"$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt"

cat >"$ARTIFACT_DIR/02-node-sweep/node-dns-sweep.txt" <<'EOF'
### pod=dns-sweep-a node=node-a
Name: kubernetes.default.svc.cluster.local
Address: 172.30.0.1
Name: openshift.default.svc.cluster.local
Address: 172.30.0.1
Name: registry.redhat.io
Address: 192.0.2.10
EOF

cat >"$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv" <<EOF
qps	rc	log
100	0	$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-100.log
EOF
cat >"$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-100.log" <<'EOF'
Statistics:
  Queries sent:         6000
  Queries completed:    6000 (100.00%)
  Queries lost:         0 (0.00%)
  Response codes:       NOERROR 6000 (100.00%)
  Queries per second:   100.000000
  Average Latency (s):  0.000200 (min 0.000100, max 0.010000)
  Latency StdDev (s):   0.000300
EOF

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
EOF

PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" report

test -s "$ARTIFACT_DIR/05-report/deep-diagnostics/openshift-dns-dns-default-a.log"
test -s "$ARTIFACT_DIR/05-report/deep-diagnostics/openshift-dns-operator-dns-operator-a.log"
test -s "$ARTIFACT_DIR/05-report/deep-diagnostics/openshift-dns-events.txt"
grep -Fxq "0" "$ARTIFACT_DIR/05-report/deep-diagnostics.rc"
grep -Fq -- "- Verdict: Blocked" "$ARTIFACT_DIR/05-report/dns-validation-report.md"
