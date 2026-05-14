#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- Stub validator scripts ---
DNS_STUB="$TMP_DIR/dns-stub"
NETWORK_STUB="$TMP_DIR/network-stub"
DNS_CALLS="$TMP_DIR/dns-calls"
NETWORK_CALLS="$TMP_DIR/network-calls"

cat >"$DNS_STUB" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$DNS_CALLS_FILE"
STUB
chmod +x "$DNS_STUB"

cat >"$NETWORK_STUB" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$NETWORK_CALLS_FILE"
STUB
chmod +x "$NETWORK_STUB"

# Helper: run entrypoint with stubs wired in
run_ep() {
  DNS_CALLS_FILE="$DNS_CALLS" NETWORK_CALLS_FILE="$NETWORK_CALLS" \
  DNS_VALIDATE="$DNS_STUB" NETWORK_VALIDATE="$NETWORK_STUB" \
  ARTIFACT_DIR="$TMP_DIR/artifacts" \
  HOME="$TMP_DIR/home" \
    bash "$REPO_ROOT/cluster-validator/bin/entrypoint.sh" "$@"
}

# Reset call logs between tests
reset_calls() {
  rm -f "$DNS_CALLS" "$NETWORK_CALLS"
}

mkdir -p "$TMP_DIR/home"

# --- Test 1: VALIDATOR=dns calls only the dns validator with --yes all ---
reset_calls
VALIDATOR=dns run_ep

grep -Fq -- "--yes all" "$DNS_CALLS"
if [[ -f "$NETWORK_CALLS" ]]; then
  echo "FAIL: network validator should not have been called for VALIDATOR=dns" >&2
  exit 1
fi

# --- Test 2: VALIDATOR=network calls only the network validator with --yes all ---
reset_calls
VALIDATOR=network run_ep

grep -Fq -- "--yes all" "$NETWORK_CALLS"
if [[ -f "$DNS_CALLS" ]]; then
  echo "FAIL: dns validator should not have been called for VALIDATOR=network" >&2
  exit 1
fi

# --- Test 3: VALIDATOR=all calls both validators ---
reset_calls
VALIDATOR=all run_ep

grep -Fq -- "--yes all" "$DNS_CALLS"
grep -Fq -- "--yes all" "$NETWORK_CALLS"

# --- Test 4: Default VALIDATOR is dns ---
reset_calls
run_ep

grep -Fq -- "--yes all" "$DNS_CALLS"
if [[ -f "$NETWORK_CALLS" ]]; then
  echo "FAIL: default should be dns, not network" >&2
  exit 1
fi

# --- Test 5: ConfigMap mount passes --config to the validator ---
reset_calls
mkdir -p "$TMP_DIR/config"
echo "# config" > "$TMP_DIR/config/validation.env"

VALIDATOR=dns run_ep --config-dir "$TMP_DIR/config"

grep -Fq -- "--config $TMP_DIR/config/validation.env --yes all" "$DNS_CALLS"

# --- Test 6: VALIDATOR=all continues past a dns failure ---
reset_calls
FAIL_DNS_STUB="$TMP_DIR/fail-dns-stub"
cat >"$FAIL_DNS_STUB" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$DNS_CALLS_FILE"
exit 1
STUB
chmod +x "$FAIL_DNS_STUB"

_saved_dns_stub="$DNS_STUB"
DNS_STUB="$FAIL_DNS_STUB"
set +e
VALIDATOR=all run_ep
overall_rc=$?
set -e
DNS_STUB="$_saved_dns_stub"

if [[ "$overall_rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit when a validator fails" >&2
  exit 1
fi
# network must still have been called even though dns failed
grep -Fq -- "--yes all" "$NETWORK_CALLS"

# --- Test 7: Unknown VALIDATOR value exits 2 ---
reset_calls
set +e
VALIDATOR=bogus run_ep >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "FAIL: unknown VALIDATOR should exit 2, got $rc" >&2
  exit 1
fi

# --- Test 8: --config-dir without argument exits 2 ---
reset_calls
set +e
run_ep --config-dir >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "FAIL: --config-dir without argument should exit 2, got $rc" >&2
  exit 1
fi

echo "All cluster-validator-entrypoint tests passed."
