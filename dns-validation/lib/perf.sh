#!/usr/bin/env bash
# Query generation, dnsperf, optional perf-tests, reporting, and cleanup.

generate_queries() {
  init_dirs
  read_runtime
  [[ -n "${CLUSTER_DOMAIN:-}" ]] || { preflight; read_runtime; }

  local d="$ARTIFACT_DIR/03-dnsperf"
  local seed="$d/queries.seed.txt"
  local query_file="$d/queries.ocp.txt"
  local repeat_count="${QUERY_REPEAT_COUNT:-1000}"

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
    for _ in $(seq 1 "$repeat_count"); do cat "$seed"; done | shuf >"$query_file"
  else
    for _ in $(seq 1 "$repeat_count"); do cat "$seed"; done >"$query_file"
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

  oc -n "$VALIDATION_NAMESPACE" delete pod/dnsperf configmap/dnsperf-queries --ignore-not-found=true >/dev/null 2>&1 || true
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
  # DNSPERF_EXTRA_ARGS is a space-separated list of extra dnsperf flags,
  # e.g. DNSPERF_EXTRA_ARGS="-c 10 -t 5"
  if [[ -n "${DNSPERF_EXTRA_ARGS:-}" ]]; then
    read -ra extra_args <<< "$DNSPERF_EXTRA_ARGS"
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
  local query_file_abs="$DNSPERF_QUERY_FILE"
  local maxqps="["
  local qps rc=0

  [[ "$repo" == /* ]] || repo="${PWD%/}/$repo"
  [[ "$query_file_abs" == /* ]] || query_file_abs="${PWD%/}/$query_file_abs"

  [[ -d "$repo/.git" ]] || run git clone --depth 1 --branch "$PERF_TESTS_REF" "$PERF_TESTS_REPO" "$repo"
  cp "$query_file_abs" "$repo/dns/queries/ocp-custom.txt"

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

results_count_file_lines() {
  local file="$1"
  if [[ -s "$file" ]]; then
    wc -l <"$file" | awk '{print $1}'
  else
    echo 0
  fi
}

results_count_dns_summary_status() {
  local status="$1"
  local file="$ARTIFACT_DIR/01-openshift-tests/dns-summary.txt"
  if [[ -f "$file" ]]; then
    grep -c "^${status}:" "$file" || true
  else
    echo 0
  fi
}

results_read_artifact_rc() {
  local file="$1"
  if [[ -s "$file" ]]; then
    tr -d '[:space:]' <"$file"
  else
    echo "not run"
  fi
}

results_dns_operator_gate_summary() {
  local file="$ARTIFACT_DIR/00-preflight/dns-operator-gate.txt"
  local available="unknown"
  local progressing="unknown"
  local degraded="unknown"

  if [[ -f "$file" ]]; then
    available="$(awk -F= '$1 == "Available" {print $2}' "$file")"
    progressing="$(awk -F= '$1 == "Progressing" {print $2}' "$file")"
    degraded="$(awk -F= '$1 == "Degraded" {print $2}' "$file")"
  fi

  echo "Available=${available:-unknown}, Progressing=${progressing:-unknown}, Degraded=${degraded:-unknown}"
}

results_dnsperf_summary() {
  local file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
  if [[ ! -s "$file" ]]; then
    echo "not run"
    return
  fi

  awk -F '\t' '
    NR > 1 {
      total++
      if ($2 == "0") {
        passed++
      } else {
        failed_qps = failed_qps ? failed_qps ", " $1 : $1
      }
    }
    END {
      if (total == 0) {
        print "not run"
      } else if (failed_qps == "") {
        printf "%d/%d qps steps passed", passed, total
      } else {
        printf "%d/%d qps steps passed (failures: %s)", passed, total, failed_qps
      }
    }
  ' "$file"
}

results_dnsperf_failure_qps() {
  local file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
  [[ -s "$file" ]] || return 0
  awk -F '\t' 'NR > 1 && $2 != "0" { failed = failed ? failed ", " $1 : $1 } END { print failed }' "$file"
}

results_resolve_artifact_path() {
  local path="$1"
  local base_dir="$2"

  if [[ -s "$path" ]]; then
    echo "$path"
  elif [[ -s "$base_dir/$path" ]]; then
    echo "$base_dir/$path"
  else
    echo "$path"
  fi
}

results_dnsperf_log_stats() {
  local dnsperf_log_file="$1"
  if [[ ! -s "$dnsperf_log_file" ]]; then
    printf 'unknown\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\tunknown\tunavailable\n'
    return
  fi

  awk '
    /Queries sent:/ { sent = $3 }
    /Queries completed:/ {
      completed = $3
      completed_pct = $4
      gsub(/[()]/, "", completed_pct)
    }
    /Queries lost:/ {
      lost = $3
      lost_pct = $4
      gsub(/[()]/, "", lost_pct)
    }
    /Response codes:/ {
      codes = $0
      sub(/^.*Response codes:[[:space:]]*/, "", codes)
    }
    /Queries per second:/ { achieved = $4 }
    /Average Latency \(s\):/ {
      avg = $4
      min = $6
      max = $8
      gsub(/,/, "", min)
      gsub(/[)]/, "", max)
    }
    /Latency StdDev \(s\):/ { stddev = $4 }
    END {
      if (sent == "") sent = "unknown"
      if (completed == "") completed = "unknown"
      if (completed_pct == "") completed_pct = "unknown"
      if (lost == "") lost = "unknown"
      if (lost_pct == "") lost_pct = "unknown"
      if (achieved == "") achieved = "unknown"
      if (avg == "") avg = "unknown"
      if (min == "") min = "unknown"
      if (max == "") max = "unknown"
      if (stddev == "") stddev = "unknown"
      if (codes == "") codes = "unavailable"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sent, completed, completed_pct, lost, lost_pct, achieved, avg, min, max, stddev, codes
    }
  ' "$dnsperf_log_file"
}

render_dnsperf_details() {
  local file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
  local qps rc log_path resolved stats
  local sent completed completed_pct lost lost_pct achieved avg min max stddev codes

  cat <<EOF
## dnsperf detailed stats

EOF

  if [[ ! -s "$file" ]]; then
    echo "- Not run"
    return
  fi

  cat <<EOF
| Requested QPS | RC | Completed | Lost | Achieved QPS | Latency | Response codes |
| --- | --- | --- | --- | --- | --- | --- |
EOF

  while IFS=$'\t' read -r qps rc log_path; do
    resolved="$(results_resolve_artifact_path "$log_path" "$ARTIFACT_DIR/03-dnsperf")"
    stats="$(results_dnsperf_log_stats "$resolved")"
    IFS=$'\t' read -r sent completed completed_pct lost lost_pct achieved avg min max stddev codes <<<"$stats"
    printf '| %s | %s | %s/%s (%s) | %s (%s) | %s | avg %ss, min %ss, max %ss, stddev %ss | %s |\n' \
      "$qps" "$rc" "$completed" "$sent" "$completed_pct" "$lost" "$lost_pct" "$achieved" \
      "$avg" "$min" "$max" "$stddev" "$codes"
  done < <(awk -F '\t' 'NR > 1 { print $1 "\t" $2 "\t" $3 }' "$file")
}

results_perf_tests_summary() {
  local file="$ARTIFACT_DIR/04-perf-tests/perf-tests-run.rc"
  if [[ -s "$file" ]]; then
    printf 'rc=%s\n' "$(tr -d '[:space:]' <"$file")"
  else
    echo "not run"
  fi
}

render_dns_conformance_details() {
  local file="$ARTIFACT_DIR/01-openshift-tests/dns-summary.txt"
  local passed failed skipped selected excluded slowest

  passed="$(results_count_dns_summary_status passed)"
  failed="$(results_count_dns_summary_status failed)"
  skipped="$(results_count_dns_summary_status skipped)"
  selected="$(results_count_file_lines "$ARTIFACT_DIR/01-openshift-tests/dns-tests.txt")"
  excluded="$(results_count_file_lines "$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt")"

  cat <<EOF
## DNS conformance details

- Result counts: passed=$passed, failed=$failed, skipped=$skipped
- Selected tests: $selected
- Excluded tests: $excluded
- Slowest DNS tests:
EOF

  if [[ ! -s "$file" ]]; then
    echo "  - Not run"
    return
  fi

  slowest="$(
    sed -n 's/^\(passed\|failed\|skipped\): (\([^)]*\)).*"\(.*\)"$/\2\t\1\t"\3"/p' "$file" |
      awk -F '\t' '
        function seconds(raw, value) {
          value = raw
          if (value ~ /ms$/) {
            sub(/ms$/, "", value)
            return value / 1000
          }
          if (value ~ /s$/) {
            sub(/s$/, "", value)
            return value + 0
          }
          return value + 0
        }
        { printf "%012.6f\t%s\t%s\t%s\n", seconds($1), $1, $2, $3 }
      ' |
      sort -r -n |
      head -n 3 |
      awk -F '\t' '{ printf "  - %s %s %s\n", $2, $3, $4 }'
  )"

  if [[ -n "$slowest" ]]; then
    printf '%s\n' "$slowest"
  else
    echo "  - No timed DNS test entries"
  fi
}

render_node_sweep_stats() {
  local file="$ARTIFACT_DIR/02-node-sweep/node-dns-sweep.txt"

  cat <<EOF
## Node DNS sweep stats

EOF

  if [[ ! -s "$file" ]]; then
    echo "- Not run"
    return
  fi

  awk '
    function flush_block() {
      if (!in_block) return
      nodes++
      if (block ~ /kubernetes\.default\.svc\./ && block ~ /Address:[[:space:]]*[0-9]/) kubernetes++
      if (block ~ /openshift\.default\.svc\.[^[:space:]]*[[:space:]]+canonical name/ || block ~ /Name:[[:space:]]*openshift\.default\.svc\./) openshift++
      if (block ~ /registry\.redhat\.io[[:space:]]+canonical name/ || block ~ /Name:[[:space:]]*registry\.redhat\.io/ || block ~ /registry-proxy/) external++
    }
    /^### pod=/ {
      flush_block()
      in_block = 1
      block = $0 "\n"
      next
    }
    {
      if (in_block) block = block $0 "\n"
    }
    END {
      flush_block()
      if (nodes == 0) {
        print "- No node sweep pod blocks found"
      } else {
        print "- Nodes swept: " nodes
        print "- kubernetes.default.svc observed: " kubernetes "/" nodes
        print "- openshift.default.svc observed: " openshift "/" nodes
        print "- registry.redhat.io observed: " external "/" nodes
      }
    }
  ' "$file"
}

render_dns_validation_verdict() {
  local dns_rc failed failed_qps dnsperf_file dns_phrase dnsperf_phrase monitor_phrase

  dns_rc="$(results_read_artifact_rc "$ARTIFACT_DIR/01-openshift-tests/dns-test-output.rc")"
  failed="$(results_count_dns_summary_status failed)"
  failed_qps="$(results_dnsperf_failure_qps)"
  dnsperf_file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"

  if [[ "$failed" != "0" ]]; then
    dns_phrase="DNS tests have failures"
  else
    dns_phrase="DNS tests passed"
  fi

  if [[ ! -s "$dnsperf_file" ]]; then
    dnsperf_phrase="dnsperf not run"
  elif [[ -n "$failed_qps" ]]; then
    dnsperf_phrase="dnsperf has qps failures: $failed_qps"
  else
    dnsperf_phrase="dnsperf clean"
  fi

  monitor_phrase=""
  if [[ "$dns_rc" != "0" && "$dns_rc" != "not run" && "$failed" == "0" ]]; then
    monitor_phrase="openshift-tests rc=$dns_rc with no DNS test failures (monitor/invariant failures outside DNS scope)"
  fi

  cat <<EOF
## DNS validation verdict

- DNS validation: $dns_phrase; $dnsperf_phrase${monitor_phrase:+; $monitor_phrase}.
EOF
}

render_results_summary() {
  local report_path="$1"
  local dns_rc passed failed skipped selected excluded

  dns_rc="$(results_read_artifact_rc "$ARTIFACT_DIR/01-openshift-tests/dns-test-output.rc")"
  passed="$(results_count_dns_summary_status passed)"
  failed="$(results_count_dns_summary_status failed)"
  skipped="$(results_count_dns_summary_status skipped)"
  selected="$(results_count_file_lines "$ARTIFACT_DIR/01-openshift-tests/dns-tests.txt")"
  excluded="$(results_count_file_lines "$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt")"

  cat <<EOF
## Results summary

- Artifact directory: \`$ARTIFACT_DIR\`
- Report: \`$report_path\`
- DNS operator gate: $(results_dns_operator_gate_summary)
- openshift-tests DNS: rc=$dns_rc, passed=$passed, failed=$failed, skipped=$skipped
- DNS tests: selected=$selected, excluded=$excluded
- dnsperf: $(results_dnsperf_summary)
- perf-tests: $(results_perf_tests_summary)
EOF
  echo
  render_dns_conformance_details
  echo
  render_dnsperf_details
  echo
  render_node_sweep_stats
  echo
  render_dns_validation_verdict
}

report() {
  init_dirs
  read_runtime

  local f="$ARTIFACT_DIR/05-report/dns-validation-report.md"
  local summary
  summary="$(render_results_summary "$f")"
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

## openshift-tests DNS exclusions

\`\`\`
$(if [[ -s "$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt" ]]; then cat "$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt"; else echo "None"; fi)
\`\`\`

## dnsperf summary

\`\`\`
$(cat "$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv" 2>/dev/null || echo "Not run")
\`\`\`

## Decision

- [ ] Accepted
- [ ] Accepted with risks
- [ ] Blocked

$summary
EOF

  log "Report written: $f"
  printf '%s\n' "$summary" | tee -a "$LOG_FILE"
}

cleanup() {
  init_dirs
  read_runtime
  require_cmd oc
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
