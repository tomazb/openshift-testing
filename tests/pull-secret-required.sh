#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/home/.kube"
: >"$TMP_DIR/home/.kube/config"

cat >"$FAKE_BIN/oc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  version|whoami) echo "ok"; exit 0 ;;
esac
echo "unexpected oc call: $*" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$TMP_DIR/artifacts"
RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:test"
PULL_SECRET_FILE="$TMP_DIR/missing-pull-secret.json"
EOF

set +e
env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" extract-tests \
  >"$TMP_DIR/out.txt" 2>&1
rc=$?
set -e

[[ "$rc" -eq 0 ]] || { echo "extract-tests should exit 0 when PULL_SECRET_FILE is missing (graceful skip), got rc=$rc" >&2; cat "$TMP_DIR/out.txt" >&2; exit 1; }
grep -Fq "PULL_SECRET_FILE not found" "$TMP_DIR/out.txt"
[[ -f "$TMP_DIR/artifacts/01-openshift-tests/pull-secret-skipped" ]] || { echo "sentinel pull-secret-skipped not created" >&2; exit 1; }
[[ ! -x "$TMP_DIR/artifacts/01-openshift-tests/openshift-tests" ]] || { echo "openshift-tests binary should not exist after pull-secret skip" >&2; exit 1; }
