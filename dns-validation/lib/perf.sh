#!/usr/bin/env bash
# Query generation, dnsperf, optional perf-tests, reporting, and cleanup.

generate_queries() {
  init_dirs
  read_runtime
  [[ -n "${CLUSTER_DOMAIN:-}" ]] || { preflight; read_runtime; }

  local d="$ARTIFACT_DIR/03-dnsperf"
  local seed="$d/queries.seed.txt"
  local query_file="$d/queries.ocp.txt"

  if [[ -f "$CUSTOM_QUERY_SEED" ]]; then
    cp "$CUSTOM_QUERY_SEED" "$seed"
  else
    cat >"$seed" <<EOF
kubernetes.default.svc.${CLUSTER_DOMAIN:-cluster.local} A
openshift.default.svc.${CLUSTER_DOMAIN:-cluster.local} A
openshift-apiserver.openshift-apiserver.svc.${CLUSTER_DOMAIN:-cluster.local} A
nonexistent-service.default.svc.${CLUSTER_DOMAIN:-cluster.local} A
EOF
    [[ -n "${CONSOLE_HOST:-}" ]] && echo "${CONSOLE_HOST} A" >>"$seed"
    [[ -n "${APPS_DOMAIN:-}" ]] && echo "thisdomaindoesnotexist12345.${APPS_DOMAIN} A" >>"$seed"
  fi

  if command -v shuf >/dev/null 2>&1; then
    for _ in $(seq 1 "$QUERY_REPEAT_COUNT"); do cat "$seed"; done | shuf >"$query_file"
  else
    for _ in $(seq 1 "$QUERY_REPEAT_COUNT"); do cat "$seed"; done >"$query_file"
  fi

  write_runtime_kv DNSPERF_QUERY_FILE "$query_file"
  log "Generated dnsperf query file: $query_file"
}

run_dnsperf() {
  init_dirs
  require_cmd oc
  read_runtime
  [[ -n "${CLUSTER_DNS_IP:-}" ]] || { preflight; read_runtime; }
  [[ -f "${DNSPERF_QUERY_FILE:-}" ]] || { generate_queries; read_runtime; }
  [[ -n "${CLUSTER_DNS_IP:-}" ]] || fail "Missing OpenShift DNS cluster IP."

  ensure_namespace
  local d="$ARTIFACT_DIR/03-dnsperf"
  local manifest="$d/dnsperf-pod.yaml"
  local rc=0

  oc -n "$VALIDATION_NAMESPACE" delete pod dnsperf configmap dnsperf-queries --ignore-not-found=true >/dev/null 2>&1 || true
  run oc -n "$VALIDATION_NAMESPACE" create configmap dnsperf-queries --from-file=queries.txt="$DNSPERF_QUERY_FILE"

  cat >"$manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: dnsperf
  namespace: ${VALIDATION_NAMESPACE}
  labels:
    app: dnsperf
spec:
  restartPolicy: Never
  containers:
  - name: dnsperf
    image: ${DNSPERF_IMAGE}
    command: ["/bin/sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: queries
      mountPath: /queries
  volumes:
  - name: queries
    configMap:
      name: dnsperf-queries
EOF

  run oc apply -f "$manifest"
  run_out "$d/dnsperf-pod-wait.txt" oc -n "$VALIDATION_NAMESPACE" wait pod/dnsperf --for=condition=Ready --timeout=180s

  echo -e "qps\trc\tlog" >"$d/dnsperf-summary.tsv"
  local extra_args=()
  if [[ -n "${DNSPERF_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra_args=($DNSPERF_EXTRA_ARGS)
  fi
  for qps in $DNSPERF_QPS_STEPS; do
    local out="$d/dnsperf-qps-${qps}.log"
    set +e
    oc -n "$VALIDATION_NAMESPACE" exec dnsperf -- dnsperf \
      -s "$CLUSTER_DNS_IP" \
      -d /queries/queries.txt \
      -l "$DNSPERF_DURATION_SECONDS" \
      -c "$DNSPERF_CLIENTS" \
      -T "$DNSPERF_THREADS" \
      -Q "$qps" \
      -S "$DNSPERF_STATS_INTERVAL" \
      "${extra_args[@]}" >"$out" 2>&1
    rc=$?
    set -e
    echo -e "${qps}\t${rc}\t${out}" >>"$d/dnsperf-summary.tsv"
  done

  log "dnsperf summary: $d/dnsperf-summary.tsv"
}

run_perf_tests() {
  init_dirs
  require_cmd git
  require_cmd python3
  require_cmd oc
  read_runtime
  [[ -n "${CLUSTER_DNS_IP:-}" ]] || { preflight; read_runtime; }
  [[ -f "${DNSPERF_QUERY_FILE:-}" ]] || { generate_queries; read_runtime; }

  local d="$ARTIFACT_DIR/04-perf-tests"
  local repo="$d/perf-tests"
  local maxqps="["
  local qps rc=0

  [[ -d "$repo/.git" ]] || run git clone --depth 1 --branch "$PERF_TESTS_REF" "$PERF_TESTS_REPO" "$repo"
  cp "$DNSPERF_QUERY_FILE" "$repo/dns/queries/ocp-custom.txt"

  for qps in $PERF_TESTS_MAX_QPS; do
    [[ "$maxqps" != "[" ]] && maxqps+=", "
    maxqps+="$qps"
  done
  maxqps+="]"

  cat >"$repo/dns/params/coredns/ocp-quick.yaml" <<EOF
run_length_seconds: [${PERF_TESTS_RUN_LENGTH_SECONDS}]
coredns_cpu: [200, 500, null]
coredns_cache: [0, 10000]
max_qps: ${maxqps}
query_file: ["ocp-custom.txt"]
EOF

  (cd "$repo/dns" && python3 -m venv .venv && .venv/bin/python -m pip install --upgrade pip && .venv/bin/python -m pip install numpy pyyaml) >"$d/perf-tests-setup.log" 2>&1
  mkdir -p "$repo/dns/.ocp-bin"
  ln -sf "$(command -v oc)" "$repo/dns/.ocp-bin/kubectl"

  local py="$repo/dns/.venv/bin/python"
  local cmd=("$py" py/run_perf.py --params params/coredns/ocp-quick.yaml --out-dir out/ocp-quick)
  case "$PERF_TESTS_MODE" in
    cluster-dns) cmd+=(--use-cluster-dns) ;;
    dns-ip) cmd+=(--dns-ip "$CLUSTER_DNS_IP") ;;
    isolated-coredns) cmd=("$py" py/run_perf.py --dns-server coredns --params params/coredns/ocp-quick.yaml --out-dir out/ocp-quick) ;;
    *) fail "Unsupported PERF_TESTS_MODE=$PERF_TESTS_MODE" ;;
  esac

  set +e
  (cd "$repo/dns" && PATH="$repo/dns/.ocp-bin:$PATH" "${cmd[@]}") >"$d/perf-tests-run.log" 2>&1
  rc=$?
  set -e
  echo "$rc" >"$d/perf-tests-run.rc"
  [[ $rc -eq 0 ]] || warn "perf-tests rc=$rc; see $d/perf-tests-run.log"
}

report() {
  init_dirs
  read_runtime

  local f="$ARTIFACT_DIR/05-report/dns-validation-report.md"
  cat >"$f" <<EOF
# OpenShift DNS Validation Report

Generated: $(date -Iseconds)

## Runtime

- Artifact directory: \`$ARTIFACT_DIR\`
- Validation namespace: \`$VALIDATION_NAMESPACE\`
- Release image: \`${RELEASE_IMAGE:-unknown}\`
- Tests image: \`${TESTS_IMAGE:-unknown}\`
- Network type: \`${NETWORK_TYPE:-unknown}\`
- Cluster DNS IP: \`${CLUSTER_DNS_IP:-unknown}\`
- Cluster domain: \`${CLUSTER_DOMAIN:-unknown}\`
- Apps domain: \`${APPS_DOMAIN:-unknown}\`

## DNS Operator gate

\`\`\`
$(cat "$ARTIFACT_DIR/00-preflight/dns-operator-gate.txt" 2>/dev/null || echo "Not captured")
\`\`\`

## openshift-tests DNS summary

\`\`\`
$(cat "$ARTIFACT_DIR/01-openshift-tests/dns-summary.txt" 2>/dev/null || echo "Not run")
\`\`\`

## dnsperf summary

\`\`\`
$(cat "$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv" 2>/dev/null || echo "Not run")
\`\`\`

## Decision

- [ ] Accepted
- [ ] Accepted with risks
- [ ] Blocked
EOF

  log "Report written: $f"
}

cleanup() {
  init_dirs
  if confirm "Delete namespace '$VALIDATION_NAMESPACE'?"; then
    run oc delete namespace "$VALIDATION_NAMESPACE" --ignore-not-found=true
  else
    log "Cleanup skipped."
  fi
}

all_actions() {
  preflight
  extract_tests
  discover_dns_tests
  run_dns_tests
  node_sweep
  generate_queries
  run_dnsperf
  report
}
