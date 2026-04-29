#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TESTS_DIR="$TMP_DIR/artifacts/01-openshift-tests"
mkdir -p "$TESTS_DIR"

cat >"$TESTS_DIR/openshift-tests" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "run-test" ]]; then
  shift
  printf '%s\n' "$*" >"$(dirname "$0")/single-test-name.txt"
  echo "single test ran"
  exit 0
fi

echo "unexpected openshift-tests call: $*" >&2
exit 2
EOF
chmod +x "$TESTS_DIR/openshift-tests"

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$TMP_DIR/artifacts"
EOF

test_name="[sig-network] DNS should provide DNS for services [Suite:k8s]"
bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" run-single-test "$test_name"

grep -Fxq "$test_name" "$TESTS_DIR/single-test-name.txt"
single_log="$(find "$TESTS_DIR" -name 'single-test-*.log' -print -quit)"
test -n "$single_log"
grep -Fq "single test ran" "$single_log"
grep -Fxq "0" "$single_log.rc"
