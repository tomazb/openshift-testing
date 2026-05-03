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
case "$*" in
  version|whoami)
    echo "ok"
    exit 0
    ;;
esac
echo "unexpected oc call: $*" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

write_config() {
  local file="$1" artifact_dir="$2"
  cat >"$file" <<EOF_CONFIG
ARTIFACT_DIR="$artifact_dir"
VALIDATION_NAMESPACE="dns-validation"
EOF_CONFIG
}

run_init() {
  local config_file="$1"
  shift
  PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$config_file" "$@" init
}

CONFIG_FILE="$TMP_DIR/default.env"
ARTIFACT_DIR="$TMP_DIR/default-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
run_init "$CONFIG_FILE" --profile day1 >"$TMP_DIR/day1.out"
grep -Fq "Initialization complete" "$TMP_DIR/day1.out"
grep -Fxq "VALIDATION_PROFILE=day1" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "INCLUDE_SERIAL_DNS_TESTS=true" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNSPERF_DURATION_SECONDS=120" "$ARTIFACT_DIR/run-info.txt"

CONFIG_FILE="$TMP_DIR/env-profile.env"
ARTIFACT_DIR="$TMP_DIR/env-profile-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
DNS_VALIDATION_PROFILE=ci run_init "$CONFIG_FILE" >"$TMP_DIR/ci.out"
grep -Fq "Initialization complete" "$TMP_DIR/ci.out"
grep -Fxq "VALIDATION_PROFILE=ci" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "AUTO_YES=true" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNS_VALIDATION_REPORT_MODE=ci" "$ARTIFACT_DIR/run-info.txt"

CONFIG_FILE="$TMP_DIR/config-profile.env"
ARTIFACT_DIR="$TMP_DIR/config-profile-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
printf '%s\n' 'VALIDATION_PROFILE="customer-evidence"' >>"$CONFIG_FILE"
run_init "$CONFIG_FILE" >"$TMP_DIR/customer-evidence.out"
grep -Fq "Initialization complete" "$TMP_DIR/customer-evidence.out"
grep -Fxq "VALIDATION_PROFILE=customer-evidence" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNSPERF_CLIENTS=10" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNS_VALIDATION_DEEP_DIAGNOSTICS=always" "$ARTIFACT_DIR/run-info.txt"

CONFIG_FILE="$TMP_DIR/override.env"
ARTIFACT_DIR="$TMP_DIR/override-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
cat >>"$CONFIG_FILE" <<'EOF_CONFIG'
VALIDATION_PROFILE="day1"
DNSPERF_DURATION_SECONDS="999"
EOF_CONFIG
run_init "$CONFIG_FILE" >"$TMP_DIR/override.out"
grep -Fq "Initialization complete" "$TMP_DIR/override.out"
grep -Fxq "VALIDATION_PROFILE=day1" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNSPERF_DURATION_SECONDS=999" "$ARTIFACT_DIR/run-info.txt"

CONFIG_FILE="$TMP_DIR/precedence.env"
ARTIFACT_DIR="$TMP_DIR/precedence-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
printf '%s\n' 'VALIDATION_PROFILE="customer-evidence"' >>"$CONFIG_FILE"
DNS_VALIDATION_PROFILE=ci run_init "$CONFIG_FILE" --profile day2 >"$TMP_DIR/precedence.out"
grep -Fq "Initialization complete" "$TMP_DIR/precedence.out"
grep -Fxq "VALIDATION_PROFILE=day2" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNS_VALIDATION_REPORT_MODE=condensed" "$ARTIFACT_DIR/run-info.txt"

set +e
PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" --profile does-not-exist init >"$TMP_DIR/unknown.out" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "unknown profile should fail" >&2
  exit 1
fi
grep -Fq "Unknown validation profile 'does-not-exist'" "$TMP_DIR/unknown.out"

echo "profile-loading: PASS"
