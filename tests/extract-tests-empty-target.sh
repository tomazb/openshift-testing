#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
mkdir -p "$TMP_DIR/home/.kube"
: >"$TMP_DIR/home/.kube/config"

cat >"$FAKE_BIN/oc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$*" == "adm release info --image-for=tests quay.io/openshift-release-dev/ocp-release:test" ]]; then
  echo "quay.io/openshift-release-dev/ocp-tests:test"
  exit 0
fi

if [[ "${1:-}" == "image" && "${2:-}" == "extract" ]]; then
  if [[ -n "$(find "$PWD" -mindepth 1 -print -quit)" ]]; then
    echo "error: directory $PWD must be empty, pass --confirm to overwrite contents of directory" >&2
    exit 1
  fi

  cat >"$PWD/openshift-tests" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "version" ]]; then
  expected_kubeconfig="$HOME/.kube/config"
  if [[ "${KUBECONFIG:-}" != "$expected_kubeconfig" ]]; then
    echo "KUBECONFIG not exported to openshift-tests: ${KUBECONFIG:-<unset>}" >&2
    exit 3
  fi
  echo "openshift-tests fake"
else
  echo "unexpected openshift-tests call: $*" >&2
  exit 2
fi
SCRIPT
  chmod +x "$PWD/openshift-tests"
  exit 0
fi

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

VALIDATOR_BASH=(bash)
if [[ "${TRACE_UNDER_TEST:-false}" == "true" ]]; then
  VALIDATOR_BASH=(bash -x)
fi

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  "${VALIDATOR_BASH[@]}" "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" extract-tests

test -x "$TMP_DIR/artifacts/01-openshift-tests/openshift-tests"
grep -Fxq "0" "$TMP_DIR/artifacts/01-openshift-tests/openshift-tests-version.txt.rc"
grep -Fxq "quay.io/openshift-release-dev/ocp-release:test" "$TMP_DIR/artifacts/01-openshift-tests/release-image.txt"
grep -Fxq "quay.io/openshift-release-dev/ocp-tests:test" "$TMP_DIR/artifacts/01-openshift-tests/tests-image.txt"
