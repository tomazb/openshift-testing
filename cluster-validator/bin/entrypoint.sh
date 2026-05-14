#!/usr/bin/env bash
# Entrypoint for the cluster-validator container image.
# Selects which OpenShift validation tool to run and wires in-cluster credentials.
set -Eeuo pipefail

DNS_VALIDATE="${DNS_VALIDATE:-/opt/openshift-testing/dns-validation/bin/ocp-dns-validate}"
NETWORK_VALIDATE="${NETWORK_VALIDATE:-/opt/openshift-testing/network-validation/bin/ocp-network-validate}"
VALIDATOR="${VALIDATOR:-dns}"
CONFIG_DIR="${CONFIG_DIR:-/config}"

# Allow --config-dir override (used by smoke tests to inject a custom config dir)
if [[ "${1:-}" == "--config-dir" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "ERROR: --config-dir requires an argument." >&2
    exit 2
  fi
  CONFIG_DIR="$2"
  shift 2
fi

# Build ~/.kube/config from the pod's service account token when running in-cluster.
_SA_TOKEN="/var/run/secrets/kubernetes.io/serviceaccount/token"
_SA_CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
_SA_NS_FILE="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
if [[ -f "$_SA_TOKEN" && -f "$_SA_CA" && -f "$_SA_NS_FILE" ]]; then
  HOME_DIR="${HOME:-/tmp}"
  export HOME="$HOME_DIR"
  mkdir -p "$HOME_DIR/.kube"
  _ns="$(cat "$_SA_NS_FILE")"
  cat >"$HOME_DIR/.kube/config" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: $_SA_CA
    server: https://kubernetes.default.svc
  name: in-cluster
contexts:
- context:
    cluster: in-cluster
    namespace: $_ns
    user: validator
  name: in-cluster
current-context: in-cluster
users:
- name: validator
  user:
    tokenFile: $_SA_TOKEN
KUBECONFIG
fi

export ARTIFACT_DIR="${ARTIFACT_DIR:-/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Build the common argument list; prepend --config if a config file is present.
args=(--yes all)
if [[ -f "$CONFIG_DIR/validation.env" ]]; then
  args=(--config "$CONFIG_DIR/validation.env" --yes all)
fi

run_dns() {
  echo "=== cluster-validator: running dns-validation ==="
  "$DNS_VALIDATE" "${args[@]}"
}

run_network() {
  echo "=== cluster-validator: running network-validation ==="
  "$NETWORK_VALIDATE" "${args[@]}"
}

case "$VALIDATOR" in
  dns)
    run_dns
    ;;
  network)
    run_network
    ;;
  all)
    dns_rc=0
    network_rc=0
    run_dns     || dns_rc=$?
    run_network || network_rc=$?
    if [[ $dns_rc -ne 0 || $network_rc -ne 0 ]]; then
      echo "=== cluster-validator: one or more validators failed (dns=$dns_rc network=$network_rc) ===" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: unknown VALIDATOR='$VALIDATOR'. Valid values: dns, network, all." >&2
    exit 2
    ;;
esac
