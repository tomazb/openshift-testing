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

args="$*"

case "$args" in
  version|whoami|\
  "get clusterversion version -o yaml"|\
  "get clusteroperators"|\
  "get nodes -o wide"|\
  "get networks.config/cluster -o yaml"|\
  "get dns.operator/default -o yaml"|\
  "describe dns.operator/default"|\
  "describe clusteroperator/dns"|\
  "-n openshift-dns get all -o wide"|\
  "-n openshift-dns-operator get all -o wide")
    echo "ok"
    exit 0
    ;;
esac

if [[ "${1:-}" == "get" && "${2:-}" == "dns.operator/default" && "${3:-}" == "-o" ]]; then
  case "${4:-}" in
    "jsonpath={.status.clusterIP}") echo "172.30.0.10" ;;
    "jsonpath={.status.clusterDomain}") echo "cluster.local" ;;
    *) echo "unexpected dns.operator jsonpath: ${4:-}" >&2; exit 2 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "ingresses.config.openshift.io/cluster" && "${3:-}" == "-o" ]]; then
  [[ "${4:-}" == "jsonpath={.spec.domain}" ]] || { echo "unexpected ingress jsonpath: ${4:-}" >&2; exit 2; }
  echo "apps.example.test"
  exit 0
fi

if [[ "${1:-}" == "-n" && "${2:-}" == "openshift-console" && "${3:-}" == "get" ]]; then
  [[ "${7:-}" == "jsonpath={.spec.host}" ]] || { echo "unexpected console jsonpath: ${7:-}" >&2; exit 2; }
  echo "console.apps.example.test"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "clusterversion" && "${3:-}" == "version" && "${4:-}" == "-o" ]]; then
  [[ "${5:-}" == "jsonpath={.status.desired.image}" ]] || { echo "unexpected clusterversion jsonpath: ${5:-}" >&2; exit 2; }
  echo "quay.io/openshift-release-dev/ocp-release:test"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "networks.config/cluster" && "${3:-}" == "-o" ]]; then
  [[ "${4:-}" == "jsonpath={.status.networkType}" ]] || { echo "unexpected network jsonpath: ${4:-}" >&2; exit 2; }
  echo "OVNKubernetes"
  exit 0
fi

if [[ "${1:-}" == "get" && "${2:-}" == "clusteroperator/dns" && "${3:-}" == "-o" ]]; then
  case "${4:-}" in
    'jsonpath={.status.conditions[?(@.type=="Available")].status}') echo "True" ;;
    'jsonpath={.status.conditions[?(@.type=="Progressing")].status}') echo "False" ;;
    'jsonpath={.status.conditions[?(@.type=="Degraded")].status}') echo "False" ;;
    *) echo "unexpected clusteroperator jsonpath: ${4:-}" >&2; exit 2 ;;
  esac
  exit 0
fi

echo "unexpected oc call: $args" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$TMP_DIR/artifacts"
PULL_SECRET_FILE="$TMP_DIR/missing-pull-secret.json"
EOF

env -u KUBECONFIG HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" \
  bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" preflight

cat >"$TMP_DIR/expected-gate.txt" <<'EOF'
Available=True
Progressing=False
Degraded=False
Expected: Available=True, Progressing=False, Degraded=False
EOF

diff -u "$TMP_DIR/expected-gate.txt" "$TMP_DIR/artifacts/00-preflight/dns-operator-gate.txt"
