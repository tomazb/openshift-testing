#!/usr/bin/env bash
# Cluster baseline and openshift-tests actions.

init_action() {
  init_dirs
  require_cmd oc
  require_cmd awk
  require_cmd grep
  require_cmd sort
  run_out "$ARTIFACT_DIR/00-preflight/oc-version.txt" oc version
  run_out "$ARTIFACT_DIR/00-preflight/whoami.txt" oc whoami
  cat >"$ARTIFACT_DIR/run-info.txt" <<EOF
RUN_ID=$RUN_ID
ARTIFACT_DIR=$ARTIFACT_DIR
CONFIG_FILE=$CONFIG_FILE
VALIDATION_NAMESPACE=$VALIDATION_NAMESPACE
EOF
  log "Initialization complete. Artifacts: $ARTIFACT_DIR"
}

preflight() {
  init_dirs
  require_cmd oc
  log "Capturing OpenShift DNS and cluster baseline."

  run_out "$ARTIFACT_DIR/00-preflight/oc-version.txt" oc version
  run_out "$ARTIFACT_DIR/00-preflight/whoami.txt" oc whoami
  run_out "$ARTIFACT_DIR/00-preflight/clusterversion.yaml" oc get clusterversion version -o yaml
  run_out "$ARTIFACT_DIR/00-preflight/clusteroperators.txt" oc get clusteroperators
  run_out "$ARTIFACT_DIR/00-preflight/nodes-wide.txt" oc get nodes -o wide
  run_out "$ARTIFACT_DIR/00-preflight/network-config.yaml" oc get networks.config/cluster -o yaml
  run_out "$ARTIFACT_DIR/00-preflight/dns-operator-default.yaml" oc get dns.operator/default -o yaml
  run_out "$ARTIFACT_DIR/00-preflight/dns-operator-default.describe.txt" oc describe dns.operator/default
  run_out "$ARTIFACT_DIR/00-preflight/clusteroperator-dns.describe.txt" oc describe clusteroperator/dns
  run_out "$ARTIFACT_DIR/00-preflight/openshift-dns-all.txt" oc -n openshift-dns get all -o wide
  run_out "$ARTIFACT_DIR/00-preflight/openshift-dns-operator-all.txt" oc -n openshift-dns-operator get all -o wide

  local cluster_dns_ip cluster_domain apps_domain console_host release_image network_type
  cluster_dns_ip="$(oc get dns.operator/default -o jsonpath='{.status.clusterIP}' 2>/dev/null || true)"
  cluster_domain="$(oc get dns.operator/default -o jsonpath='{.status.clusterDomain}' 2>/dev/null || true)"
  apps_domain="$(oc get ingresses.config.openshift.io/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  console_host="$(oc -n openshift-console get route console -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  release_image="$(oc get clusterversion version -o jsonpath='{.status.desired.image}' 2>/dev/null || true)"
  network_type="$(oc get networks.config/cluster -o jsonpath='{.status.networkType}' 2>/dev/null || true)"

  write_runtime_kv CLUSTER_DNS_IP "$cluster_dns_ip"
  write_runtime_kv CLUSTER_DOMAIN "$cluster_domain"
  write_runtime_kv APPS_DOMAIN "$apps_domain"
  write_runtime_kv CONSOLE_HOST "$console_host"
  write_runtime_kv RELEASE_IMAGE "$release_image"
  write_runtime_kv NETWORK_TYPE "$network_type"

  cat >"$ARTIFACT_DIR/00-preflight/dns-baseline.env" <<EOF
CLUSTER_DNS_IP=$cluster_dns_ip
CLUSTER_DOMAIN=$cluster_domain
APPS_DOMAIN=$apps_domain
CONSOLE_HOST=$console_host
RELEASE_IMAGE=$release_image
NETWORK_TYPE=$network_type
EOF

  local dns_available dns_progressing dns_degraded
  dns_available="$(oc get clusteroperator/dns -o 'jsonpath={.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  dns_progressing="$(oc get clusteroperator/dns -o 'jsonpath={.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)"
  dns_degraded="$(oc get clusteroperator/dns -o 'jsonpath={.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)"

  {
    echo "Available=$dns_available"
    echo "Progressing=$dns_progressing"
    echo "Degraded=$dns_degraded"
    echo "Expected: Available=True, Progressing=False, Degraded=False"
  } >"$ARTIFACT_DIR/00-preflight/dns-operator-gate.txt"

  collect_lightweight_diagnostics

  log "Detected cluster DNS IP: ${cluster_dns_ip:-unknown}; domain: ${cluster_domain:-unknown}."
}

collect_lightweight_diagnostics() {
  init_dirs
  require_cmd oc
  local d="$ARTIFACT_DIR/00-preflight"

  log "Capturing lightweight DNS diagnostics."
  run_out "$d/openshift-dns-workloads.txt" oc -n openshift-dns get pods,daemonsets,deployments,services,endpoints -o wide
  run_out "$d/openshift-dns-operator-workloads.txt" oc -n openshift-dns-operator get pods,deployments,services -o wide
  run_out "$d/openshift-dns-events.txt" oc -n openshift-dns get events --sort-by=.metadata.creationTimestamp
  run_out "$d/openshift-dns-operator-events.txt" oc -n openshift-dns-operator get events --sort-by=.metadata.creationTimestamp
  run_out "$d/openshift-dns-endpointslices.txt" oc -n openshift-dns get endpointslices.discovery.k8s.io -o wide
  run_out "$d/coredns-pod-placement.txt" oc -n openshift-dns get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase --no-headers
  run_out "$d/dns-upstream-resolvers.txt" oc get dns.operator/default -o 'jsonpath={range .spec.upstreamResolvers.upstreams[*]}{.type}{" "}{.address}{" "}{.port}{"\n"}{end}'
}

collect_deep_run_out() {
  local out="$1"
  shift

  run_out_checked "$out" "$@"
}

collect_deep_diagnostics() {
  init_dirs
  local d="$ARTIFACT_DIR/05-report/deep-diagnostics"
  local rc=0
  local pod pod_file
  mkdir -p "$d"

  log "Capturing deep DNS diagnostics."

  if ! command -v oc >/dev/null 2>&1; then
    echo "oc command not found" >"$d/deep-diagnostics-error.txt"
    echo "1" >"$ARTIFACT_DIR/05-report/deep-diagnostics.rc"
    warn "Deep DNS diagnostics incomplete; see $d"
    return 0
  fi

  pod_file="$d/openshift-dns-pods.txt"
  if collect_deep_run_out "$pod_file" oc -n openshift-dns get pods -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}'; then
    while IFS= read -r pod; do
      [[ -n "$pod" ]] || continue
      collect_deep_run_out "$d/openshift-dns-${pod}.log" oc -n openshift-dns logs "$pod" --all-containers --tail=-1 || rc=1
      collect_deep_run_out "$d/openshift-dns-${pod}.describe.txt" oc -n openshift-dns describe pod "$pod" || rc=1
    done <"$pod_file"
  else
    rc=1
  fi

  pod_file="$d/openshift-dns-operator-pods.txt"
  if collect_deep_run_out "$pod_file" oc -n openshift-dns-operator get pods -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}'; then
    while IFS= read -r pod; do
      [[ -n "$pod" ]] || continue
      collect_deep_run_out "$d/openshift-dns-operator-${pod}.log" oc -n openshift-dns-operator logs "$pod" --all-containers --tail=-1 || rc=1
    done <"$pod_file"
  else
    rc=1
  fi

  collect_deep_run_out "$d/openshift-dns-events.txt" oc -n openshift-dns get events --sort-by=.metadata.creationTimestamp || rc=1
  collect_deep_run_out "$d/openshift-dns-operator-events.txt" oc -n openshift-dns-operator get events --sort-by=.metadata.creationTimestamp || rc=1
  collect_deep_run_out "$d/validation-namespace-events.txt" oc -n "$VALIDATION_NAMESPACE" get events --sort-by=.metadata.creationTimestamp || rc=1

  echo "$rc" >"$ARTIFACT_DIR/05-report/deep-diagnostics.rc"
  if [[ "$rc" -eq 0 ]]; then
    log "Deep DNS diagnostics captured: $d"
  else
    warn "Deep DNS diagnostics incomplete; see $d"
  fi
  return 0
}

extract_tests() {
  init_dirs
  require_cmd oc
  require_cmd mktemp
  read_runtime

  local release_image tests_image tests_dir extract_dir
  local auth=()
  tests_dir="$ARTIFACT_DIR/01-openshift-tests"
  release_image="${RELEASE_IMAGE:-$(oc get clusterversion version -o jsonpath='{.status.desired.image}')}"
  [[ -n "$release_image" ]] || fail "Cannot detect release image. Run preflight first."
  [[ -f "$PULL_SECRET_FILE" ]] && auth=(-a "$PULL_SECRET_FILE")

  tests_image="$(oc adm release info --image-for=tests "${auth[@]}" "$release_image")"
  write_runtime_kv RELEASE_IMAGE "$release_image"
  write_runtime_kv TESTS_IMAGE "$tests_image"

  extract_dir="$(mktemp -d "$ARTIFACT_DIR/tmp/openshift-tests.XXXXXX")"
  (cd "$extract_dir" && oc image extract "$tests_image" "${auth[@]}" --path /usr/bin/openshift-tests:.) 2>&1 | tee -a "$LOG_FILE"
  mv "$extract_dir/openshift-tests" "$OPENSHIFT_TESTS_BIN"
  rmdir "$extract_dir"
  chmod +x "$OPENSHIFT_TESTS_BIN"
  echo "$release_image" >"$tests_dir/release-image.txt"
  echo "$tests_image" >"$tests_dir/tests-image.txt"
  run_out "$tests_dir/openshift-tests-version.txt" "$OPENSHIFT_TESTS_BIN" version
}

discover_dns_tests() {
  init_dirs
  ensure_tests

  local d="$ARTIFACT_DIR/01-openshift-tests"
  local raw="$ARTIFACT_DIR/01-openshift-tests/dns-tests.raw.txt"
  local candidates="$ARTIFACT_DIR/01-openshift-tests/dns-tests.candidates.txt"
  local excluded="$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt"
  : >"$raw"
  : >"$excluded"

  "$OPENSHIFT_TESTS_BIN" run openshift/conformance/parallel --dry-run 2>"$d/dry-run-parallel.stderr.log" | grep -Ei "$DNS_TEST_REGEX" >>"$raw" || true
  "$OPENSHIFT_TESTS_BIN" run kubernetes/conformance --dry-run 2>"$d/dry-run-k8s.stderr.log" | grep -Ei "$DNS_TEST_REGEX" >>"$raw" || true
  "$OPENSHIFT_TESTS_BIN" run openshift/conformance/serial --dry-run 2>"$d/dry-run-serial.stderr.log" | grep -Ei "$DNS_TEST_REGEX" >"$d/dns-serial-candidates.txt" || true

  if [[ "$INCLUDE_SERIAL_DNS_TESTS" == true ]]; then
    cat "$d/dns-serial-candidates.txt" >>"$raw"
  fi
  sort -u "$raw" >"$candidates"
  if [[ -n "$DNS_TEST_EXCLUDE_REGEX" ]]; then
    local exclude_rc=0 filter_rc=0
    grep -E "$DNS_TEST_EXCLUDE_REGEX" "$candidates" >"$excluded" || exclude_rc=$?
    grep -Ev "$DNS_TEST_EXCLUDE_REGEX" "$candidates" >"$d/dns-tests.txt" || filter_rc=$?
    [[ $exclude_rc -eq 0 || $exclude_rc -eq 1 ]] || fail "Invalid DNS_TEST_EXCLUDE_REGEX='$DNS_TEST_EXCLUDE_REGEX'."
    [[ $filter_rc -eq 0 || $filter_rc -eq 1 ]] || fail "Invalid DNS_TEST_EXCLUDE_REGEX='$DNS_TEST_EXCLUDE_REGEX'."
  else
    cp "$candidates" "$d/dns-tests.txt"
  fi
  if [[ ! -s "$d/dns-tests.txt" ]]; then
    fail "DNS test discovery produced no matches. Check $d/dry-run-*.stderr.log and DNS_TEST_REGEX='$DNS_TEST_REGEX'."
  fi
  if [[ -s "$excluded" ]]; then
    log "Excluded $(wc -l <"$excluded" | awk '{print $1}') DNS tests. Review: $excluded"
  fi
  log "Discovered $(wc -l <"$d/dns-tests.txt" | awk '{print $1}') DNS tests. Review: $d/dns-tests.txt"
}

run_dns_tests() {
  init_dirs
  ensure_tests

  local d="$ARTIFACT_DIR/01-openshift-tests"
  local rc=0
  [[ -s "$d/dns-tests.txt" ]] || discover_dns_tests

  log "+ $OPENSHIFT_TESTS_BIN run -f $d/dns-tests.txt --junit-dir $d/junit > $d/dns-test-output.log"
  run_capture "$d/dns-test-output.log" "$d/dns-test-output.rc" \
    "$OPENSHIFT_TESTS_BIN" run -f "$d/dns-tests.txt" --junit-dir "$d/junit" || rc=$?
  grep -E '^(passed|failed|skipped):' "$d/dns-test-output.log" >"$d/dns-summary.txt" || true
  if [[ $rc -eq 0 ]]; then
    log "DNS conformance passed."
  else
    warn "DNS conformance rc=$rc; see $d/dns-test-output.log"
  fi
}

run_single_test() {
  init_dirs
  ensure_tests

  local test_name="${*:-}"
  if [[ -z "$test_name" ]]; then
    read -r -p "Full openshift-tests test name: " test_name || fail "No test name provided."
  fi
  [[ -n "$test_name" ]] || fail "No test name provided."

  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  local f="$ARTIFACT_DIR/01-openshift-tests/single-test-${timestamp}.log"
  local rc=0

  log "+ $OPENSHIFT_TESTS_BIN run-test $test_name > $f"
  run_capture "$f" "$f.rc" "$OPENSHIFT_TESTS_BIN" run-test "$test_name" || rc=$?
  if [[ $rc -eq 0 ]]; then
    log "Single test passed."
  else
    warn "Single test rc=$rc; see $f"
  fi
}

node_sweep() {
  init_dirs
  require_cmd oc
  read_runtime
  [[ -n "${CLUSTER_DOMAIN:-}" ]] || { preflight; read_runtime; }
  ensure_namespace

  local d="$ARTIFACT_DIR/02-node-sweep"
  local manifest="$d/dns-sweep-daemonset.yaml"
  local result="$d/node-dns-sweep.txt"
  # domain is sourced from oc get dns.operator/default (.status.clusterDomain)
  # and constrained to [a-z0-9.\-] by RFC 1123 — safe to interpolate into sh -c string.
  local domain="${CLUSTER_DOMAIN:-cluster.local}"

  cat >"$manifest" <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dns-sweep
  namespace: ${VALIDATION_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: dns-sweep
  template:
    metadata:
      labels:
        app: dns-sweep
    spec:
      tolerations:
      - operator: Exists
      containers:
      - name: dnsutils
        image: ${DNS_SWEEP_IMAGE}
        command: ["sleep", "3600"]
EOF

  run oc apply -f "$manifest"
  run_out "$d/dns-sweep-rollout.txt" oc -n "$VALIDATION_NAMESPACE" rollout status ds/dns-sweep --timeout=180s
  local rollout_rc
  rollout_rc="$(results_read_artifact_rc "$d/dns-sweep-rollout.txt.rc")"
  [[ "$rollout_rc" == "0" ]] || fail "dns-sweep rollout failed (rc=$rollout_rc). See $d/dns-sweep-rollout.txt"

  : >"$result"
  for pod in $(oc -n "$VALIDATION_NAMESPACE" get pod -l app=dns-sweep -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true); do
    node="$(oc -n "$VALIDATION_NAMESPACE" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
    echo "### pod=$pod node=$node" >>"$result"
    oc -n "$VALIDATION_NAMESPACE" exec "$pod" -- sh -c "nslookup \"kubernetes.default.svc.\$1\"; nslookup \"openshift.default.svc.\$1\" || true; nslookup registry.redhat.io || true" -- "$domain" >>"$result" 2>&1 || true
    echo >>"$result"
  done

  collect_lightweight_diagnostics

  log "Node sweep results: $result"
}
