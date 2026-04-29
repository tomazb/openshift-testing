#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
FAKE_STATE_DIR="$TMP_DIR/state"
export FAKE_STATE_DIR
mkdir -p "$FAKE_BIN" "$FAKE_STATE_DIR"

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "unexpected git call: $*" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/git"

cat >"$FAKE_BIN/oc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "unexpected oc call: $*" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

cat >"$FAKE_BIN/python3" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
  venv_dir="${3:-}"
  mkdir -p "$venv_dir/bin"
  cat >"$venv_dir/bin/python" <<'PYEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "-m" && "${2:-}" == "pip" ]]; then
  exit 0
fi

if [[ "${1:-}" == "py/run_perf.py" ]]; then
  printf '%s\n' "$*" >"$FAKE_STATE_DIR/perf-command.txt"
  echo "perf-tests fake run"
  exit 0
fi

echo "unexpected venv python call: $*" >&2
exit 2
PYEOF
  chmod +x "$venv_dir/bin/python"
  exit 0
fi

echo "unexpected python3 call: $*" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/python3"

ARTIFACT_DIR="$TMP_DIR/artifacts"
PERF_REPO="$ARTIFACT_DIR/04-perf-tests/perf-tests"
mkdir -p \
  "$ARTIFACT_DIR/03-dnsperf" \
  "$ARTIFACT_DIR/04-perf-tests" \
  "$PERF_REPO/.git" \
  "$PERF_REPO/dns/queries" \
  "$PERF_REPO/dns/params/coredns" \
  "$PERF_REPO/dns/py"

QUERY_FILE="$ARTIFACT_DIR/03-dnsperf/queries.ocp.txt"
cat >"$QUERY_FILE" <<'EOF'
kubernetes.default.svc.cluster.local A
EOF

cat >"$ARTIFACT_DIR/runtime.env" <<EOF
CLUSTER_DNS_IP=172.30.0.10
CLUSTER_DOMAIN=cluster.local
DNSPERF_QUERY_FILE=$QUERY_FILE
EOF

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
PERF_TESTS_MODE="dns-ip"
PERF_TESTS_RUN_LENGTH_SECONDS="15"
PERF_TESTS_MAX_QPS="500 1000"
EOF

PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" perf-tests

grep -Fxq "0" "$ARTIFACT_DIR/04-perf-tests/perf-tests-run.rc"
grep -Fq -- "--dns-ip" "$FAKE_STATE_DIR/perf-command.txt"
grep -Fq -- "172.30.0.10" "$FAKE_STATE_DIR/perf-command.txt"
grep -Fxq "kubernetes.default.svc.cluster.local A" "$PERF_REPO/dns/queries/ocp-custom.txt"
grep -Fq "run_length_seconds: [15]" "$PERF_REPO/dns/params/coredns/ocp-quick.yaml"
grep -Fq "max_qps: [500, 1000]" "$PERF_REPO/dns/params/coredns/ocp-quick.yaml"
