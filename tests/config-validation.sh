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

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$TMP_DIR/artifacts"
DNSPERF_DURATION_SECONDS="abc"
EOF

set +e
PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" init >"$TMP_DIR/out.txt" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "invalid config should fail before running init" >&2
  exit 1
fi

grep -Fq "Invalid config: DNSPERF_DURATION_SECONDS must be a positive integer" "$TMP_DIR/out.txt"
if [[ -f "$TMP_DIR/artifacts/00-preflight/oc-version.txt" ]]; then
  echo "init should not run after config validation fails" >&2
  exit 1
fi

set +e
PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config --yes init >"$TMP_DIR/missing-config-value.out" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "--config without a file path should fail" >&2
  exit 1
fi
grep -Fq -- "--config requires a file path" "$TMP_DIR/missing-config-value.out"

UNREADABLE_CONFIG="$TMP_DIR/unreadable.env"
printf 'ARTIFACT_DIR=%q\n' "$TMP_DIR/unreadable-artifacts" >"$UNREADABLE_CONFIG"
chmod 000 "$UNREADABLE_CONFIG"
set +e
PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$UNREADABLE_CONFIG" init >"$TMP_DIR/unreadable-config.out" 2>&1
rc=$?
chmod 600 "$UNREADABLE_CONFIG"
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "unreadable explicit config should fail" >&2
  exit 1
fi
grep -Fq "config file not found or not readable" "$TMP_DIR/unreadable-config.out"
