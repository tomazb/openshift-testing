#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$REPO_ROOT/dns-validation/lib/results.sh"

write_common_success_artifacts() {
  local dir="$1"
  mkdir -p \
    "$dir/00-preflight" \
    "$dir/01-openshift-tests" \
    "$dir/02-node-sweep" \
    "$dir/03-dnsperf" \
    "$dir/04-perf-tests" \
    "$dir/05-report"

  cat >"$dir/00-preflight/dns-operator-gate.txt" <<'EOF'
Available=True
Progressing=False
Degraded=False
Expected: Available=True, Progressing=False, Degraded=False
EOF
  cat >"$dir/00-preflight/nodes-wide.txt" <<'EOF'
NAME     STATUS   ROLES    AGE   VERSION   INTERNAL-IP
node-a   Ready    worker   1d    v1.31.0   192.0.2.11
EOF

  cat >"$dir/01-openshift-tests/dns-summary.txt" <<'EOF'
passed: (2.1s) "dns service lookup"
EOF
  echo "0" >"$dir/01-openshift-tests/dns-test-output.rc"
  echo '"[sig-network] DNS should provide DNS for services [Suite:k8s]"' >"$dir/01-openshift-tests/dns-tests.txt"
  : >"$dir/01-openshift-tests/dns-tests.excluded.txt"

  cat >"$dir/02-node-sweep/node-dns-sweep.txt" <<'EOF'
### pod=dns-sweep-a node=node-a
Server: 172.30.0.10
Name: kubernetes.default.svc.cluster.local
Address: 172.30.0.1
Name: openshift.default.svc.cluster.local
Address: 172.30.0.1
Name: registry.redhat.io
Address: 192.0.2.10
EOF

  cat >"$dir/03-dnsperf/dnsperf-qps-100.log" <<'EOF'
Statistics:
  Queries sent:         6000
  Queries completed:    6000 (100.00%)
  Queries lost:         0 (0.00%)
  Response codes:       NOERROR 6000 (100.00%)
  Queries per second:   100.000000
  Average Latency (s):  0.000200 (min 0.000100, max 0.010000)
  Latency StdDev (s):   0.000300
EOF

  {
    printf 'qps\trc\tlog\n'
    printf '100\t0\t%s\n' "$dir/03-dnsperf/dnsperf-qps-100.log"
  } >"$dir/03-dnsperf/dnsperf-summary.tsv"

  echo "0" >"$dir/04-perf-tests/perf-tests-run.rc"
}

assert_verdict() {
  local dir="$1"
  local expected="$2"
  ARTIFACT_DIR="$dir" results_compute_verdict >/dev/null
  actual="$(cat "$dir/05-report/verdict.txt")"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected verdict '$expected', got '$actual'" >&2
    echo "blocking reasons:" >&2
    cat "$dir/05-report/verdict-blocking-reasons.txt" >&2 || true
    echo "risk reasons:" >&2
    cat "$dir/05-report/verdict-risk-reasons.txt" >&2 || true
    exit 1
  fi
}

case_dir="$TMP_DIR/accepted"
write_common_success_artifacts "$case_dir"
assert_verdict "$case_dir" "Accepted"

case_dir="$TMP_DIR/ipv6-accepted"
write_common_success_artifacts "$case_dir"
cat >"$case_dir/02-node-sweep/node-dns-sweep.txt" <<'EOF'
### pod=dns-sweep-a node=node-a
Server:		fd00:10::10
Address:	fd00:10::10#53

Name:	kubernetes.default.svc.cluster.local
Address: fd00:10::1

Server:		fd00:10::10
Address:	fd00:10::10#53

Name:	openshift.default.svc.cluster.local
Address: fd00:20::1

Server:		fd00:10::10
Address:	fd00:10::10#53

Non-authoritative answer:
registry.redhat.io	canonical name = registry-proxy.example.test.
Name:	registry-proxy.example.test
Address: 2001:db8::10
EOF
assert_verdict "$case_dir" "Accepted"

case_dir="$TMP_DIR/perf-tests-missing-risk"
write_common_success_artifacts "$case_dir"
rm "$case_dir/04-perf-tests/perf-tests-run.rc"
assert_verdict "$case_dir" "Accepted with risks"
grep -Fq "Optional perf-tests not run" "$case_dir/05-report/verdict-risk-reasons.txt"

case_dir="$TMP_DIR/deep-diagnostics-ignored"
write_common_success_artifacts "$case_dir"
echo "7" >"$case_dir/05-report/deep-diagnostics.rc"
assert_verdict "$case_dir" "Accepted"

case_dir="$TMP_DIR/missing-node-count-blocked"
write_common_success_artifacts "$case_dir"
rm "$case_dir/00-preflight/nodes-wide.txt"
assert_verdict "$case_dir" "Blocked"
grep -Fq "Cluster node count unavailable" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/node-count-rc-blocked"
write_common_success_artifacts "$case_dir"
echo "1" >"$case_dir/00-preflight/nodes-wide.txt.rc"
assert_verdict "$case_dir" "Blocked"
grep -Fq "Cluster node count unavailable" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/malformed-node-count-blocked"
write_common_success_artifacts "$case_dir"
cat >"$case_dir/00-preflight/nodes-wide.txt" <<'EOF'
node-a   Ready    worker   1d    v1.31.0   192.0.2.11
EOF
assert_verdict "$case_dir" "Blocked"
grep -Fq "Cluster node count unavailable" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/dns-operator-blocked"
write_common_success_artifacts "$case_dir"
sed -i 's/Available=True/Available=False/' "$case_dir/00-preflight/dns-operator-gate.txt"
assert_verdict "$case_dir" "Blocked"
grep -Fq "DNS operator gate unhealthy" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/dns-test-failed"
write_common_success_artifacts "$case_dir"
cat >"$case_dir/01-openshift-tests/dns-summary.txt" <<'EOF'
failed: (800ms) "dns failing lookup"
EOF
echo "1" >"$case_dir/01-openshift-tests/dns-test-output.rc"
assert_verdict "$case_dir" "Blocked"
grep -Fq "Selected DNS conformance tests failed" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/monitor-risk"
write_common_success_artifacts "$case_dir"
echo "1" >"$case_dir/01-openshift-tests/dns-test-output.rc"
assert_verdict "$case_dir" "Accepted with risks"
grep -Fq "openshift-tests returned rc=1 with no selected DNS test failures" "$case_dir/05-report/verdict-risk-reasons.txt"

case_dir="$TMP_DIR/external-risk"
write_common_success_artifacts "$case_dir"
sed -i '/registry.redhat.io/,$d' "$case_dir/02-node-sweep/node-dns-sweep.txt"
assert_verdict "$case_dir" "Accepted with risks"
grep -Fq "External DNS lookup missing on 1 of 1 swept nodes" "$case_dir/05-report/verdict-risk-reasons.txt"

case_dir="$TMP_DIR/external-cname-only-risk"
write_common_success_artifacts "$case_dir"
cat >"$case_dir/02-node-sweep/node-dns-sweep.txt" <<'EOF'
### pod=dns-sweep-a node=node-a
Server: 172.30.0.10
Name: kubernetes.default.svc.cluster.local
Address: 172.30.0.1
Server: 172.30.0.10
Name: openshift.default.svc.cluster.local
Address: 172.30.0.1
Server: 172.30.0.10
registry.redhat.io canonical name = registry-proxy.example.test.
** server can't find registry-proxy.example.test: NXDOMAIN
EOF
assert_verdict "$case_dir" "Accepted with risks"
grep -Fq "External DNS lookup missing on 1 of 1 swept nodes" "$case_dir/05-report/verdict-risk-reasons.txt"

case_dir="$TMP_DIR/internal-blocked"
write_common_success_artifacts "$case_dir"
sed -i '/openshift.default.svc/,+1d' "$case_dir/02-node-sweep/node-dns-sweep.txt"
assert_verdict "$case_dir" "Blocked"
grep -Fq "Node sweep internal lookups incomplete" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/internal-resolver-address-only-blocked"
write_common_success_artifacts "$case_dir"
cat >"$case_dir/02-node-sweep/node-dns-sweep.txt" <<'EOF'
### pod=dns-sweep-a node=node-a
Server:		172.30.0.10
Address:	172.30.0.10#53

** server can't find kubernetes.default.svc.cluster.local: NXDOMAIN

Server:		172.30.0.10
Address:	172.30.0.10#53

** server can't find openshift.default.svc.cluster.local: NXDOMAIN

Server:		172.30.0.10
Address:	172.30.0.10#53

Name: registry.redhat.io
Address: 192.0.2.10
EOF
assert_verdict "$case_dir" "Blocked"
grep -Fq "Node sweep internal lookups incomplete: kubernetes=0/1, openshift=0/1" \
  "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/node-count-blocked"
write_common_success_artifacts "$case_dir"
cat >>"$case_dir/00-preflight/nodes-wide.txt" <<'EOF'
node-b   Ready    worker   1d    v1.31.0   192.0.2.12
EOF
assert_verdict "$case_dir" "Blocked"
grep -Fq "Node sweep did not cover all nodes: swept=1, cluster-nodes=2" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/duplicate-node-blocked"
write_common_success_artifacts "$case_dir"
cat >>"$case_dir/00-preflight/nodes-wide.txt" <<'EOF'
node-b   Ready    worker   1d    v1.31.0   192.0.2.12
EOF
cat >"$case_dir/02-node-sweep/node-dns-sweep.txt" <<'EOF'
### pod=dns-sweep-a node=node-a
Server: 172.30.0.10
Name: kubernetes.default.svc.cluster.local
Address: 172.30.0.1
Name: openshift.default.svc.cluster.local
Address: 172.30.0.1
Name: registry.redhat.io
Address: 192.0.2.10
### pod=dns-sweep-b node=node-a
Server: 172.30.0.10
Name: kubernetes.default.svc.cluster.local
Address: 172.30.0.1
Name: openshift.default.svc.cluster.local
Address: 172.30.0.1
Name: registry.redhat.io
Address: 192.0.2.10
EOF
assert_verdict "$case_dir" "Blocked"
grep -Fq "Node sweep did not cover all nodes: swept=1, cluster-nodes=2" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/dnsperf-blocked"
write_common_success_artifacts "$case_dir"
sed -i $'s/100\\t0/100\\t1/' "$case_dir/03-dnsperf/dnsperf-summary.tsv"
assert_verdict "$case_dir" "Blocked"
grep -Fq "dnsperf failed qps steps: 100" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/dnsperf-header-only-blocked"
write_common_success_artifacts "$case_dir"
printf 'qps\trc\tlog\n' >"$case_dir/03-dnsperf/dnsperf-summary.tsv"
assert_verdict "$case_dir" "Blocked"
grep -Fq "dnsperf summary has no qps results" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/perf-tests-risk"
write_common_success_artifacts "$case_dir"
echo "7" >"$case_dir/04-perf-tests/perf-tests-run.rc"
assert_verdict "$case_dir" "Accepted with risks"
grep -Fq "Optional perf-tests returned rc=7" "$case_dir/05-report/verdict-risk-reasons.txt"

case_dir="$TMP_DIR/dnsperf-loss-threshold"
write_common_success_artifacts "$case_dir"
DNSPERF_MAX_LOST_PERCENT="0.0" ARTIFACT_DIR="$case_dir" results_compute_verdict >/dev/null
grep -Fxq "Accepted" "$case_dir/05-report/verdict.txt"

cat >"$case_dir/03-dnsperf/dnsperf-qps-100.log" <<'EOF'
Statistics:
  Queries sent:         6000
  Queries completed:    5990 (99.83%)
  Queries lost:         10 (0.17%)
  Response codes:       NOERROR 5990 (100.00%)
  Queries per second:   99.833333
  Average Latency (s):  0.000200 (min 0.000100, max 0.010000)
  Latency StdDev (s):   0.000300
EOF
DNSPERF_MAX_LOST_PERCENT="0.0" ARTIFACT_DIR="$case_dir" results_compute_verdict >/dev/null
grep -Fxq "Blocked" "$case_dir/05-report/verdict.txt"
grep -Fq "dnsperf threshold failures: 100qps lost=0.17%" "$case_dir/05-report/verdict-blocking-reasons.txt"
summary="$(DNSPERF_MAX_LOST_PERCENT="0.0" ARTIFACT_DIR="$case_dir" results_dnsperf_summary)"
grep -Fq "0/1 qps steps passed" <<<"$summary"
grep -Fq "100qps lost=0.17%" <<<"$summary"

case_dir="$TMP_DIR/dnsperf-threshold-missing-log"
write_common_success_artifacts "$case_dir"
printf 'qps\trc\tlog\n100\t0\tdnsperf-qps-100.log\n' >"$case_dir/03-dnsperf/dnsperf-summary.tsv"
rm "$case_dir/03-dnsperf/dnsperf-qps-100.log"
DNSPERF_MAX_LOST_PERCENT="0.0" ARTIFACT_DIR="$case_dir" results_compute_verdict >/dev/null
grep -Fxq "Blocked" "$case_dir/05-report/verdict.txt"
grep -Fq "dnsperf threshold failures: 100qps log unavailable: dnsperf-qps-100.log" \
  "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/dnsperf-latency-threshold"
write_common_success_artifacts "$case_dir"
DNSPERF_MAX_AVG_LATENCY_SECONDS="0.000100" ARTIFACT_DIR="$case_dir" results_compute_verdict >/dev/null
grep -Fxq "Blocked" "$case_dir/05-report/verdict.txt"
grep -Fq "100qps avg-latency=0.000200s" "$case_dir/05-report/verdict-blocking-reasons.txt"
