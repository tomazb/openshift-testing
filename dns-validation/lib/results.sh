#!/usr/bin/env bash
# Artifact parsing, verdict computation, and report rendering helpers.

set -Eeuo pipefail

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

results_reason_line() {
  local reason="$1"
  local artifact="${2:-}"
  if [[ -n "$artifact" ]]; then
    printf -- "- %s (artifact: \`%s\`)\n" "$reason" "$artifact"
  else
    printf -- '- %s\n' "$reason"
  fi
}

results_add_blocking_reason() {
  local reason="$1"
  local artifact="${2:-}"
  results_reason_line "$reason" "$artifact" >>"$ARTIFACT_DIR/05-report/verdict-blocking-reasons.txt"
}

results_add_risk_reason() {
  local reason="$1"
  local artifact="${2:-}"
  results_reason_line "$reason" "$artifact" >>"$ARTIFACT_DIR/05-report/verdict-risk-reasons.txt"
}

results_dns_operator_gate_values() {
  local file="$ARTIFACT_DIR/00-preflight/dns-operator-gate.txt"
  local available="unknown"
  local progressing="unknown"
  local degraded="unknown"

  if [[ -s "$file" ]]; then
    available="$(awk -F= '$1 == "Available" {print $2}' "$file")"
    progressing="$(awk -F= '$1 == "Progressing" {print $2}' "$file")"
    degraded="$(awk -F= '$1 == "Degraded" {print $2}' "$file")"
  fi

  printf '%s\t%s\t%s\n' "${available:-unknown}" "${progressing:-unknown}" "${degraded:-unknown}"
}

results_node_sweep_counts() {
  local file="$ARTIFACT_DIR/02-node-sweep/node-dns-sweep.txt"
  if [[ ! -s "$file" ]]; then
    printf '0\t0\t0\t0\n'
    return
  fi

  awk '
    function reset_query() {
      kubernetes_pending = 0
      openshift_pending = 0
      openshift_section = 0
      external_pending = 0
    }
    function reset_node(node_name) {
      current_node = node_name
      node_kubernetes = 0
      node_openshift = 0
      node_external = 0
      reset_query()
    }
    function flush_block() {
      if (!in_block) return
      if (current_node == "") return
      seen_nodes[current_node] = 1
      if (node_kubernetes) kubernetes_nodes[current_node] = 1
      if (node_openshift) openshift_nodes[current_node] = 1
      if (node_external) external_nodes[current_node] = 1
    }
    /^### pod=/ {
      node_name = ""
      header = $0
      if (sub(/^.*[[:space:]]node=/, "", header)) {
        split(header, header_parts, /[[:space:]]+/)
        node_name = header_parts[1]
      }
      flush_block()
      in_block = 1
      reset_node(node_name)
      next
    }
    !in_block {
      next
    }
    /^Server:/ {
      reset_query()
      next
    }
    /openshift\.default\.svc\.[^[:space:]]*[[:space:]]+canonical name/ {
      openshift_section = 1
      openshift_pending = 1
      next
    }
    /Name:[[:space:]]*openshift\.default\.svc\./ {
      openshift_section = 1
      openshift_pending = 1
      next
    }
    /Name:[[:space:]]*kubernetes\.default\.svc\./ {
      if (!openshift_section) kubernetes_pending = 1
      next
    }
    /^Address:[[:space:]]*/ {
      address = $0
      sub(/^Address:[[:space:]]*/, "", address)
      if (address != "" && address !~ /#/) {
        if (kubernetes_pending) node_kubernetes = 1
        if (openshift_pending) node_openshift = 1
        if (external_pending) node_external = 1
        if (kubernetes_pending || openshift_pending || external_pending) reset_query()
      }
      next
    }
    /registry\.redhat\.io[[:space:]]+canonical name/ || /Name:[[:space:]]*registry\.redhat\.io/ {
      external_pending = 1
    }
    END {
      flush_block()
      for (node in seen_nodes) {
        nodes++
        if (node in kubernetes_nodes) kubernetes++
        if (node in openshift_nodes) openshift++
        if (node in external_nodes) external++
      }
      printf "%d\t%d\t%d\t%d\n", nodes, kubernetes, openshift, external
    }
  ' "$file"
}

results_cluster_node_count() {
  local file="$ARTIFACT_DIR/00-preflight/nodes-wide.txt"
  local rc_file="$file.rc"
  local rc count

  if [[ -s "$rc_file" ]]; then
    rc="$(results_read_artifact_rc "$rc_file")"
    if [[ "$rc" != "0" ]]; then
      echo "unavailable"
      return
    fi
  fi

  if [[ ! -s "$file" ]]; then
    echo "unavailable"
    return
  fi

  if ! awk 'NR == 1 { exit ($1 == "NAME" ? 0 : 1) }' "$file"; then
    echo "unavailable"
    return
  fi

  count="$(awk 'NR > 1 && NF > 0 { count++ } END { print count + 0 }' "$file")"
  if [[ "$count" == "0" ]]; then
    echo "unavailable"
  else
    echo "$count"
  fi
}

results_compute_verdict() {
  local report_dir="$ARTIFACT_DIR/05-report"
  mkdir -p "$report_dir"
  : >"$report_dir/verdict-blocking-reasons.txt"
  : >"$report_dir/verdict-risk-reasons.txt"

  local gate="$ARTIFACT_DIR/00-preflight/dns-operator-gate.txt"
  local available progressing degraded gate_values
  gate_values="$(results_dns_operator_gate_values)"
  IFS=$'\t' read -r available progressing degraded <<<"$gate_values"
  if [[ ! -s "$gate" ]]; then
    results_add_blocking_reason "DNS operator gate artifact missing" "$gate"
  elif [[ "$available" != "True" || "$progressing" != "False" || "$degraded" != "False" ]]; then
    results_add_blocking_reason "DNS operator gate unhealthy: Available=$available, Progressing=$progressing, Degraded=$degraded" "$gate"
  fi

  local dns_summary="$ARTIFACT_DIR/01-openshift-tests/dns-summary.txt"
  local dns_rc_file="$ARTIFACT_DIR/01-openshift-tests/dns-test-output.rc"
  local failed skipped excluded dns_rc
  failed="$(results_count_dns_summary_status failed)"
  skipped="$(results_count_dns_summary_status skipped)"
  excluded="$(results_count_file_lines "$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt")"
  dns_rc="$(results_read_artifact_rc "$dns_rc_file")"
  if [[ ! -s "$dns_summary" ]]; then
    results_add_blocking_reason "DNS conformance summary artifact missing" "$dns_summary"
  elif [[ "$failed" != "0" ]]; then
    results_add_blocking_reason "Selected DNS conformance tests failed: failed=$failed" "$dns_summary"
  fi
  if [[ "$dns_rc" != "0" && "$dns_rc" != "not run" && "$failed" == "0" ]]; then
    results_add_risk_reason "openshift-tests returned rc=$dns_rc with no selected DNS test failures" "$dns_rc_file"
  fi
  if [[ "$skipped" != "0" ]]; then
    results_add_risk_reason "Selected DNS conformance tests included skipped results: skipped=$skipped" "$dns_summary"
  fi
  if [[ "$excluded" != "0" ]]; then
    results_add_risk_reason "DNS conformance tests were excluded: excluded=$excluded" "$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt"
  fi

  local nodes kubernetes openshift external node_counts node_file cluster_nodes
  node_file="$ARTIFACT_DIR/02-node-sweep/node-dns-sweep.txt"
  node_counts="$(results_node_sweep_counts)"
  IFS=$'\t' read -r nodes kubernetes openshift external <<<"$node_counts"
  cluster_nodes="$(results_cluster_node_count)"
  if [[ "$cluster_nodes" == "unavailable" ]]; then
    results_add_blocking_reason "Cluster node count unavailable" "$ARTIFACT_DIR/00-preflight/nodes-wide.txt"
  fi
  if [[ ! -s "$node_file" ]]; then
    results_add_blocking_reason "Node DNS sweep artifact missing" "$node_file"
  elif [[ "$cluster_nodes" != "unavailable" && "$nodes" != "$cluster_nodes" ]]; then
    results_add_blocking_reason "Node sweep did not cover all nodes: swept=$nodes, cluster-nodes=$cluster_nodes" "$node_file"
  elif [[ "$nodes" == "0" || "$kubernetes" != "$nodes" || "$openshift" != "$nodes" ]]; then
    results_add_blocking_reason "Node sweep internal lookups incomplete: kubernetes=$kubernetes/$nodes, openshift=$openshift/$nodes" "$node_file"
  elif [[ "$external" != "$nodes" ]]; then
    results_add_risk_reason "External DNS lookup missing on $((nodes - external)) of $nodes swept nodes" "$node_file"
  fi

  local dnsperf_file failed_qps dnsperf_qps_count
  dnsperf_file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
  failed_qps="$(results_dnsperf_failure_qps)"
  dnsperf_qps_count="$(results_dnsperf_qps_count)"
  if [[ ! -s "$dnsperf_file" ]]; then
    results_add_blocking_reason "dnsperf summary artifact missing" "$dnsperf_file"
  elif [[ "$dnsperf_qps_count" == "0" ]]; then
    results_add_blocking_reason "dnsperf summary has no qps results" "$dnsperf_file"
  elif [[ -n "$failed_qps" ]]; then
    results_add_blocking_reason "dnsperf failed qps steps: $failed_qps" "$dnsperf_file"
  fi

  local perf_rc_file perf_rc
  perf_rc_file="$ARTIFACT_DIR/04-perf-tests/perf-tests-run.rc"
  perf_rc="$(results_read_artifact_rc "$perf_rc_file")"
  if [[ "$perf_rc" != "0" && "$perf_rc" != "not run" ]]; then
    results_add_risk_reason "Optional perf-tests returned rc=$perf_rc" "$perf_rc_file"
  fi

  if [[ -s "$report_dir/verdict-blocking-reasons.txt" ]]; then
    echo "Blocked" >"$report_dir/verdict.txt"
  elif [[ -s "$report_dir/verdict-risk-reasons.txt" ]]; then
    echo "Accepted with risks" >"$report_dir/verdict.txt"
  else
    echo "Accepted" >"$report_dir/verdict.txt"
  fi
}

results_verdict() {
  local file="$ARTIFACT_DIR/05-report/verdict.txt"
  [[ -s "$file" ]] || results_compute_verdict
  cat "$file"
}

render_verdict_section() {
  local verdict
  verdict="$(results_verdict)"
  cat <<EOF
## DNS validation verdict

- Verdict: $verdict
EOF
  if [[ -s "$ARTIFACT_DIR/05-report/verdict-blocking-reasons.txt" ]]; then
    echo "- Blocking reasons:"
    sed 's/^/  /' "$ARTIFACT_DIR/05-report/verdict-blocking-reasons.txt"
  fi
  if [[ -s "$ARTIFACT_DIR/05-report/verdict-risk-reasons.txt" ]]; then
    echo "- Risk reasons:"
    sed 's/^/  /' "$ARTIFACT_DIR/05-report/verdict-risk-reasons.txt"
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

results_dns_upstream_summary() {
  local file="$ARTIFACT_DIR/00-preflight/dns-upstream-resolvers.txt"
  if [[ -s "$file" ]]; then
    paste -sd '; ' "$file"
  else
    echo "not captured"
  fi
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

results_dnsperf_qps_count() {
  local file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
  if [[ ! -s "$file" ]]; then
    echo 0
    return
  fi

  awk -F '\t' 'NR > 1 && NF > 0 { count++ } END { print count + 0 }' "$file"
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
  local cluster_nodes node_counts nodes kubernetes openshift external
  cluster_nodes="$(results_cluster_node_count)"

  cat <<EOF
## Node DNS sweep stats

EOF
  echo "- Cluster nodes from preflight: $cluster_nodes"

  if [[ ! -s "$file" ]]; then
    echo "- Not run"
    return
  fi

  node_counts="$(results_node_sweep_counts)"
  IFS=$'\t' read -r nodes kubernetes openshift external <<<"$node_counts"
  if [[ "$nodes" == "0" ]]; then
    echo "- No node sweep pod blocks found"
  else
    echo "- Nodes swept: $nodes"
    echo "- kubernetes.default.svc observed: $kubernetes/$nodes"
    echo "- openshift.default.svc observed: $openshift/$nodes"
    echo "- registry.redhat.io observed: $external/$nodes"
  fi
}

render_dns_validation_verdict() {
  render_verdict_section
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
- DNS upstream resolvers: $(results_dns_upstream_summary)
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
