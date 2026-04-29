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
