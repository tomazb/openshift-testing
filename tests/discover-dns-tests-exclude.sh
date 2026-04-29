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

if [[ "${1:-}" == "run" && "${3:-}" == "--dry-run" ]]; then
  case "${2:-}" in
    openshift/conformance/parallel)
      cat <<'TESTS'
"[sig-network] DNS should provide DNS for services [Conformance] [Suite:openshift/conformance/parallel/minimal] [Suite:k8s]"
"[sig-network-edge] DNS should answer A and AAAA queries for a dual-stack service [apigroup:config.openshift.io] [Suite:openshift/conformance/parallel]"
"[sig-network-edge] DNS should answer queries using the local DNS endpoint [Suite:openshift/conformance/parallel]"
"[sig-network-edge] DNS should keep this non-excluded edge coverage [Suite:openshift/conformance/parallel]"
TESTS
      ;;
    kubernetes/conformance)
      echo '"[sig-network] DNS should provide DNS for services [Conformance] [Suite:k8s]"'
      ;;
    openshift/conformance/serial)
      echo '"[sig-network] DNS serial candidate should stay out unless enabled [Suite:openshift/conformance/serial]"'
      ;;
    *)
      echo "unexpected suite: ${2:-}" >&2
      exit 2
      ;;
  esac
  exit 0
fi

echo "unexpected openshift-tests call: $*" >&2
exit 2
EOF
chmod +x "$TESTS_DIR/openshift-tests"

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$TMP_DIR/artifacts"
DNS_TEST_EXCLUDE_REGEX="DNS should answer A and AAAA queries for a dual-stack service|DNS should answer queries using the local DNS endpoint"
EOF

bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" discover-dns-tests

grep -Fq "DNS should answer A and AAAA queries for a dual-stack service" "$TESTS_DIR/dns-tests.raw.txt"
grep -Fq "DNS should answer queries using the local DNS endpoint" "$TESTS_DIR/dns-tests.raw.txt"

grep -Fq "DNS should answer A and AAAA queries for a dual-stack service" "$TESTS_DIR/dns-tests.excluded.txt"
grep -Fq "DNS should answer queries using the local DNS endpoint" "$TESTS_DIR/dns-tests.excluded.txt"

if grep -Fq "DNS should answer A and AAAA queries for a dual-stack service" "$TESTS_DIR/dns-tests.txt"; then
  echo "dual-stack edge test was not excluded" >&2
  exit 1
fi

if grep -Fq "DNS should answer queries using the local DNS endpoint" "$TESTS_DIR/dns-tests.txt"; then
  echo "local DNS endpoint edge test was not excluded" >&2
  exit 1
fi

grep -Fq "DNS should provide DNS for services" "$TESTS_DIR/dns-tests.txt"
grep -Fq "DNS should keep this non-excluded edge coverage" "$TESTS_DIR/dns-tests.txt"
