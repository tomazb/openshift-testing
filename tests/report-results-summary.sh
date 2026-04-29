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
  "-n openshift-dns describe pod dns-default-a")
    echo "dns pod describe"
    exit 0
    ;;
  "-n openshift-dns-operator logs dns-operator-a --all-containers --tail=-1")
    echo "operator pod log"
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
mkdir -p \
  "$ARTIFACT_DIR/00-preflight" \
  "$ARTIFACT_DIR/01-openshift-tests" \
  "$ARTIFACT_DIR/02-node-sweep" \
  "$ARTIFACT_DIR/03-dnsperf" \
  "$ARTIFACT_DIR/04-perf-tests"

cat >"$ARTIFACT_DIR/runtime.env" <<'EOF'
RELEASE_IMAGE=quay.example/ocp-release:4.19
TESTS_IMAGE=quay.example/ocp-tests:4.19
NETWORK_TYPE=OVNKubernetes
CLUSTER_DNS_IP=172.30.0.10
CLUSTER_DOMAIN=cluster.local
APPS_DOMAIN=apps.example.test
EOF

cat >"$ARTIFACT_DIR/00-preflight/dns-operator-gate.txt" <<'EOF'
Available=True
Progressing=False
Degraded=False
Expected: Available=True, Progressing=False, Degraded=False
EOF

cat >"$ARTIFACT_DIR/00-preflight/dns-upstream-resolvers.txt" <<'EOF'
SystemResolvConf  53
Network 192.0.2.53 53
Network 2001:db8::53 5353
EOF

cat >"$ARTIFACT_DIR/01-openshift-tests/dns-summary.txt" <<'EOF'
passed: (12.3s) "dns service lookup"
failed: (800ms) "dns failing lookup"
skipped: (0s) "dns skipped lookup"
passed: (2.1s) "dns external name"
EOF
echo "1" >"$ARTIFACT_DIR/01-openshift-tests/dns-test-output.rc"

cat >"$ARTIFACT_DIR/01-openshift-tests/dns-tests.txt" <<'EOF'
"selected test 1"
"selected test 2"
"selected test 3"
EOF

cat >"$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt" <<'EOF'
"excluded test 1"
"excluded test 2"
EOF

cat >"$ARTIFACT_DIR/02-node-sweep/node-dns-sweep.txt" <<'EOF'
### pod=dns-sweep-a node=node-a
Server:		172.30.0.10
Address:	172.30.0.10#53

Name:	kubernetes.default.svc.cluster.local
Address: 172.30.0.1

Server:		172.30.0.10
Address:	172.30.0.10#53

openshift.default.svc.cluster.local	canonical name = kubernetes.default.svc.cluster.local.
Name:	kubernetes.default.svc.cluster.local
Address: 172.30.0.1

Server:		172.30.0.10
Address:	172.30.0.10#53

Non-authoritative answer:
registry.redhat.io	canonical name = registry-proxy.example.test.
Name:	registry-proxy.example.test
Address: 192.0.2.10

### pod=dns-sweep-b node=node-b
Server:		172.30.0.10
Address:	172.30.0.10#53

Name:	kubernetes.default.svc.cluster.local
Address: 172.30.0.1

Server:		172.30.0.10
Address:	172.30.0.10#53

openshift.default.svc.cluster.local	canonical name = kubernetes.default.svc.cluster.local.
Name:	kubernetes.default.svc.cluster.local
Address: 172.30.0.1

** server can't find registry.redhat.io: NXDOMAIN
EOF

cat >"$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-100.log" <<'EOF'
Statistics:

  Queries sent:         6000
  Queries completed:    6000 (100.00%)
  Queries lost:         0 (0.00%)

  Response codes:       NOERROR 4000 (66.67%), NXDOMAIN 2000 (33.33%)
  Run time (s):         60.000000
  Queries per second:   100.000000

  Average Latency (s):  0.000200 (min 0.000100, max 0.010000)
  Latency StdDev (s):   0.000300
EOF

cat >"$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-500.log" <<'EOF'
Statistics:

  Queries sent:         30000
  Queries completed:    29900 (99.67%)
  Queries lost:         100 (0.33%)

  Response codes:       NOERROR 19934 (66.67%), NXDOMAIN 9966 (33.33%)
  Run time (s):         60.000000
  Queries per second:   498.333333

  Average Latency (s):  0.003000 (min 0.000200, max 0.080000)
  Latency StdDev (s):   0.004000
EOF

cat >"$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-1000.log" <<'EOF'
Statistics:

  Queries sent:         60000
  Queries completed:    60000 (100.00%)
  Queries lost:         0 (0.00%)

  Response codes:       NOERROR 40000 (66.67%), NXDOMAIN 20000 (33.33%)
  Run time (s):         60.000000
  Queries per second:   1000.000000

  Average Latency (s):  0.004500 (min 0.000300, max 0.090000)
  Latency StdDev (s):   0.005000
EOF

{
  printf 'qps\trc\tlog\n'
  printf '100\t0\t%s\n' "$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-100.log"
  printf '500\t1\t%s\n' "$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-500.log"
  printf '1000\t0\t%s\n' "$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-1000.log"
} >"$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
echo "7" >"$ARTIFACT_DIR/04-perf-tests/perf-tests-run.rc"

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
EOF

PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" report >"$TMP_DIR/report.out"

REPORT="$ARTIFACT_DIR/05-report/dns-validation-report.md"

grep -Fq "## Results summary" "$REPORT"
grep -Fq -- "- DNS operator gate: Available=True, Progressing=False, Degraded=False" "$REPORT"
grep -Fq -- "- DNS upstream resolvers: SystemResolvConf  53; Network 192.0.2.53 53; Network 2001:db8::53 5353" "$REPORT"
grep -Fq -- "- openshift-tests DNS: rc=1, passed=2, failed=1, skipped=1" "$REPORT"
grep -Fq -- "- DNS tests: selected=3, excluded=2" "$REPORT"
grep -Fq -- "- dnsperf: 2/3 qps steps passed (failures: 500)" "$REPORT"
grep -Fq -- "- perf-tests: rc=7" "$REPORT"
grep -Fq -- "- Deep diagnostics: rc=0, artifacts=\`$ARTIFACT_DIR/05-report/deep-diagnostics\`" "$REPORT"
grep -Fq "## DNS conformance details" "$REPORT"
grep -Fq -- "- Slowest DNS tests:" "$REPORT"
grep -Fq -- "12.3s passed \"dns service lookup\"" "$REPORT"
grep -Fq "## dnsperf detailed stats" "$REPORT"
grep -Fq "| 500 | 1 | 29900/30000 (99.67%) | 100 (0.33%) | 498.333333 | avg 0.003000s, min 0.000200s, max 0.080000s, stddev 0.004000s | NOERROR 19934 (66.67%), NXDOMAIN 9966 (33.33%) |" "$REPORT"
grep -Fq "## Node DNS sweep stats" "$REPORT"
grep -Fq -- "- Nodes swept: 2" "$REPORT"
grep -Fq -- "- kubernetes.default.svc observed: 2/2" "$REPORT"
grep -Fq -- "- openshift.default.svc observed: 2/2" "$REPORT"
grep -Fq -- "- registry.redhat.io observed: 1/2" "$REPORT"
grep -Fq "## DNS validation verdict" "$REPORT"
grep -Fq -- "- Verdict: Blocked" "$REPORT"
grep -Fq -- "- Blocking reasons:" "$REPORT"
grep -Fq -- "- Risk reasons:" "$REPORT"
grep -Fq "Selected DNS conformance tests failed: failed=1" "$REPORT"
grep -Fq "dnsperf failed qps steps: 500" "$REPORT"
grep -Fq "Selected DNS conformance tests included skipped results: skipped=1" "$REPORT"
grep -Fq "DNS conformance tests were excluded: excluded=2" "$REPORT"
grep -Fq "External DNS lookup missing on 1 of 2 swept nodes" "$REPORT"
grep -Fq "Optional perf-tests returned rc=7" "$REPORT"

grep -Fq "## Results summary" "$TMP_DIR/report.out"
grep -Fq -- "- DNS upstream resolvers: SystemResolvConf  53; Network 192.0.2.53 53; Network 2001:db8::53 5353" "$TMP_DIR/report.out"
grep -Fq -- "- openshift-tests DNS: rc=1, passed=2, failed=1, skipped=1" "$TMP_DIR/report.out"
grep -Fq -- "- Deep diagnostics: rc=0, artifacts=\`$ARTIFACT_DIR/05-report/deep-diagnostics\`" "$TMP_DIR/report.out"
grep -Fq "## dnsperf detailed stats" "$TMP_DIR/report.out"

cat >"$ARTIFACT_DIR/00-preflight/dns-upstream-resolvers.txt" <<'EOF'
error: failed to fetch dns upstream resolvers
EOF
echo "1" >"$ARTIFACT_DIR/00-preflight/dns-upstream-resolvers.txt.rc"

PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" report >"$TMP_DIR/report-upstream-rc.out"

grep -Fq -- "- DNS upstream resolvers: not captured (rc=1)" "$REPORT"
grep -Fq -- "- DNS upstream resolvers: not captured (rc=1)" "$TMP_DIR/report-upstream-rc.out"
if grep -Fq -- "- DNS upstream resolvers: error: failed to fetch dns upstream resolvers" "$REPORT"; then
  echo "report should not render failed upstream capture stderr as resolver data" >&2
  exit 1
fi
if grep -Fq -- "- DNS upstream resolvers: error: failed to fetch dns upstream resolvers" "$TMP_DIR/report-upstream-rc.out"; then
  echo "terminal output should not render failed upstream capture stderr as resolver data" >&2
  exit 1
fi

if [[ "$(tail -n 1 "$REPORT")" != *"Optional perf-tests returned rc=7"* ]]; then
  echo "report should end with the structured verdict reasons" >&2
  tail -n 20 "$REPORT" >&2
  exit 1
fi

if [[ "$(tail -n 1 "$TMP_DIR/report.out")" != *"Optional perf-tests returned rc=7"* ]]; then
  echo "terminal output should end with the structured verdict reasons" >&2
  tail -n 20 "$TMP_DIR/report.out" >&2
  exit 1
fi
