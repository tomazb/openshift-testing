#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p \
  "$ARTIFACT_DIR/00-preflight" \
  "$ARTIFACT_DIR/01-openshift-tests" \
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

cat >"$ARTIFACT_DIR/01-openshift-tests/dns-summary.txt" <<'EOF'
passed: "dns service lookup"
failed: "dns failing lookup"
skipped: "dns skipped lookup"
passed: "dns external name"
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

{
  printf 'qps\trc\tlog\n'
  printf '100\t0\tdnsperf-qps-100.log\n'
  printf '500\t1\tdnsperf-qps-500.log\n'
  printf '1000\t0\tdnsperf-qps-1000.log\n'
} >"$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
echo "7" >"$ARTIFACT_DIR/04-perf-tests/perf-tests-run.rc"

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
EOF

bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" report >"$TMP_DIR/report.out"

REPORT="$ARTIFACT_DIR/05-report/dns-validation-report.md"

grep -Fq "## Results summary" "$REPORT"
grep -Fq -- "- DNS operator gate: Available=True, Progressing=False, Degraded=False" "$REPORT"
grep -Fq -- "- openshift-tests DNS: rc=1, passed=2, failed=1, skipped=1" "$REPORT"
grep -Fq -- "- DNS tests: selected=3, excluded=2" "$REPORT"
grep -Fq -- "- dnsperf: 2/3 qps steps passed (failures: 500)" "$REPORT"
grep -Fq -- "- perf-tests: rc=7" "$REPORT"

grep -Fq "## Results summary" "$TMP_DIR/report.out"
grep -Fq -- "- openshift-tests DNS: rc=1, passed=2, failed=1, skipped=1" "$TMP_DIR/report.out"

if [[ "$(tail -n 1 "$REPORT")" != "- perf-tests: rc=7" ]]; then
  echo "report should end with the results summary" >&2
  tail -n 20 "$REPORT" >&2
  exit 1
fi

if [[ "$(tail -n 1 "$TMP_DIR/report.out")" != "- perf-tests: rc=7" ]]; then
  echo "terminal output should end with the results summary" >&2
  tail -n 20 "$TMP_DIR/report.out" >&2
  exit 1
fi
