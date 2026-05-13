#!/usr/bin/env bash
# Smoke test: iperf3/iperf3-network-metrics-collector.sh runs in client role,
# creates expected artifact files, and exits 0.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDALONE="$REPO_ROOT/iperf3/iperf3-network-metrics-collector.sh"

MOCKS_DIR="$(mktemp -d)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCKS_DIR" "$OUT_DIR"' EXIT

# Mock iperf3 — client writes valid JSON, server exits 0
cat > "$MOCKS_DIR/iperf3" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == "-s" ]] && exit 0; done
cat <<'JSON'
{"start":{},"intervals":[],"end":{"sum_received":{"bits_per_second":10000000000,"bytes":100000000,"seconds":1},"sum_sent":{"retransmits":0}}}
JSON
MOCK
chmod +x "$MOCKS_DIR/iperf3"

for cmd in mpstat ethtool; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKS_DIR/$cmd"
  chmod +x "$MOCKS_DIR/$cmd"
done

# Run collector: client role, loopback interface (no auto-detect needed), 1s duration
PATH="$MOCKS_DIR:$PATH" timeout 15 bash "$STANDALONE" \
  -r client -t 127.0.0.1 -i lo -d 1 -o "$OUT_DIR"

pass=0; fail=0
check_file() {
  if [[ -f "$OUT_DIR/$1" ]]; then
    echo "PASS: $1 exists"
    (( pass++ )) || true
  else
    echo "FAIL: $1 missing"
    (( fail++ )) || true
  fi
}

check_file "iperf3_client.json"
check_file "00_baseline.txt"
check_file "01_cpu_usage.log"
check_file "09_netdev.log"
check_file "99_posttest.txt"

if (( fail > 0 )); then
  echo "SMOKE TEST FAILED: $fail check(s) failed, $pass passed"
  exit 1
fi
echo "SMOKE TEST PASSED: $pass checks"
