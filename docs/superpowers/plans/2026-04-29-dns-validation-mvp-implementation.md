# DNS Validation MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add artifact-based DNS validation verdicts and diagnostics so the tool produces actionable `Accepted`, `Accepted with risks`, or `Blocked` outcomes.

**Architecture:** Keep the existing Bash CLI and artifact layout. Move result parsing and report rendering into `dns-validation/lib/results.sh`, keep live cluster collection in `cluster.sh`, keep workload execution in `perf.sh`, and make report generation compute a preliminary verdict before optionally collecting deep diagnostics.

**Tech Stack:** Bash, OpenShift `oc`, `awk`, `grep`, `sort`, shellcheck, existing shell regression tests.

---

## File Structure

- Create `dns-validation/lib/results.sh`
  - Owns artifact parsing, node-sweep parsing, dnsperf log parsing, verdict computation, and report section rendering.
  - Reads only files under `ARTIFACT_DIR`.
  - Does not call `oc`.

- Modify `dns-validation/bin/ocp-dns-validate`
  - Source `results.sh` after `cluster.sh` and before `perf.sh`.
  - Keep existing CLI action names stable.

- Modify `dns-validation/lib/cluster.sh`
  - Add `collect_lightweight_diagnostics`.
  - Add `collect_deep_diagnostics`.
  - Call lightweight diagnostics from `preflight` and after `node_sweep`.
  - Deep diagnostics are called by report generation only after a preliminary risky or blocked verdict.

- Modify `dns-validation/lib/perf.sh`
  - Remove result parsing and rendering functions that move to `results.sh`.
  - Update `report` to call verdict helpers from `results.sh`.
  - Keep dnsperf, perf-tests, cleanup, and `all_actions` responsibilities.

- Modify `dns-validation/config/validation.env.example`
  - Add opt-in dnsperf threshold settings.

- Modify `dns-validation/README.md`
  - Document verdicts, diagnostics levels, and threshold settings.

- Modify `scripts/check-static.sh`
  - Syntax-check and shellcheck `dns-validation/lib/results.sh`.
  - Guard that result functions do not drift back into `perf.sh`.

- Modify existing tests:
  - `tests/report-results-summary.sh`
  - `tests/preflight-dns-operator-gate.sh`

- Create `tests/results-verdict.sh`
  - Synthetic artifact tests for verdict classification.

---

### Task 1: Extract Result Parsing Into `results.sh`

**Files:**
- Create: `dns-validation/lib/results.sh`
- Modify: `dns-validation/bin/ocp-dns-validate:91-99`
- Modify: `dns-validation/lib/perf.sh:162-501`
- Modify: `scripts/check-static.sh`
- Test: `tests/report-results-summary.sh`

- [ ] **Step 1: Add a failing static check for the new results library**

Modify `scripts/check-static.sh` so the syntax section includes `dns-validation/lib/results.sh`:

```bash
bash -n dns-validation/lib/results.sh
```

Modify the shellcheck block so it includes `dns-validation/lib/results.sh`:

```bash
shellcheck -x \
  dns-validation/bin/ocp-dns-validate \
  dns-validation/lib/common.sh \
  dns-validation/lib/cluster.sh \
  dns-validation/lib/perf.sh \
  dns-validation/lib/results.sh \
  scripts/check-static.sh \
  tests/discover-dns-tests-exclude.sh \
  tests/extract-tests-empty-target.sh \
  tests/preflight-dns-operator-gate.sh \
  tests/report-results-summary.sh
```

Add this guard near the existing static policy checks:

```bash
if ! grep -Fq 'source "$PROJECT_DIR/lib/results.sh"' dns-validation/bin/ocp-dns-validate; then
  echo "ocp-dns-validate must source dns-validation/lib/results.sh" >&2
  exit 1
fi

if rg -n '^(results_|render_)' dns-validation/lib/perf.sh >/dev/null; then
  echo "result parsing/rendering helpers belong in dns-validation/lib/results.sh" >&2
  rg -n '^(results_|render_)' dns-validation/lib/perf.sh >&2
  exit 1
fi
```

- [ ] **Step 2: Run the static check and verify it fails**

Run:

```bash
bash scripts/check-static.sh
```

Expected: FAIL because `dns-validation/lib/results.sh` does not exist and `ocp-dns-validate` does not source it yet.

- [ ] **Step 3: Create `results.sh` by moving existing result helpers**

Create `dns-validation/lib/results.sh` with this header:

```bash
#!/usr/bin/env bash
# Artifact parsing, verdict computation, and report rendering helpers.

set -Eeuo pipefail
```

Move the existing functions from `dns-validation/lib/perf.sh` into `results.sh` without changing behavior in this task:

```text
results_count_file_lines
results_count_dns_summary_status
results_read_artifact_rc
results_dns_operator_gate_summary
results_dnsperf_summary
results_dnsperf_failure_qps
results_resolve_artifact_path
results_dnsperf_log_stats
render_dnsperf_details
results_perf_tests_summary
render_dns_conformance_details
render_node_sweep_stats
render_dns_validation_verdict
render_results_summary
```

Remove those function definitions from `dns-validation/lib/perf.sh`. After this step, `perf.sh` should still contain:

```text
generate_queries
run_dnsperf
run_perf_tests
report
cleanup
all_actions
```

- [ ] **Step 4: Source `results.sh` from the CLI entrypoint**

Modify `dns-validation/bin/ocp-dns-validate` between the existing `cluster.sh` and `perf.sh` source blocks:

```bash
# shellcheck source=../lib/results.sh
# shellcheck disable=SC1091
source "$PROJECT_DIR/lib/results.sh"
```

- [ ] **Step 5: Run the report regression test**

Run:

```bash
bash tests/report-results-summary.sh
```

Expected: PASS. This proves the extraction preserved the current report output.

- [ ] **Step 6: Run the static check**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add dns-validation/bin/ocp-dns-validate dns-validation/lib/perf.sh dns-validation/lib/results.sh scripts/check-static.sh tests/report-results-summary.sh
git commit -m "refactor: split DNS result rendering"
```

---

### Task 2: Add Verdict Engine And Verdict Tests

**Files:**
- Modify: `dns-validation/lib/results.sh`
- Modify: `dns-validation/lib/perf.sh:503-561`
- Create: `tests/results-verdict.sh`
- Modify: `scripts/check-static.sh`

- [ ] **Step 1: Write the failing verdict test**

Create `tests/results-verdict.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$REPO_ROOT/dns-validation/lib/results.sh"

write_common_success_artifacts() {
  local dir="$1"
  mkdir -p \
    "$dir/00-preflight" \
    "$dir/01-openshift-tests" \
    "$dir/02-node-sweep" \
    "$dir/03-dnsperf" \
    "$dir/04-perf-tests" \
    "$dir/05-report"

  cat >"$dir/00-preflight/dns-operator-gate.txt" <<'EOF'
Available=True
Progressing=False
Degraded=False
Expected: Available=True, Progressing=False, Degraded=False
EOF
  cat >"$dir/00-preflight/nodes-wide.txt" <<'EOF'
NAME     STATUS   ROLES    AGE   VERSION   INTERNAL-IP
node-a   Ready    worker   1d    v1.31.0   192.0.2.11
EOF

  cat >"$dir/01-openshift-tests/dns-summary.txt" <<'EOF'
passed: (2.1s) "dns service lookup"
EOF
  echo "0" >"$dir/01-openshift-tests/dns-test-output.rc"
  echo '"[sig-network] DNS should provide DNS for services [Suite:k8s]"' >"$dir/01-openshift-tests/dns-tests.txt"
  : >"$dir/01-openshift-tests/dns-tests.excluded.txt"

  cat >"$dir/02-node-sweep/node-dns-sweep.txt" <<'EOF'
### pod=dns-sweep-a node=node-a
Server: 172.30.0.10
Name: kubernetes.default.svc.cluster.local
Address: 172.30.0.1
Name: openshift.default.svc.cluster.local
Address: 172.30.0.1
Name: registry.redhat.io
Address: 192.0.2.10
EOF

  cat >"$dir/03-dnsperf/dnsperf-qps-100.log" <<'EOF'
Statistics:
  Queries sent:         6000
  Queries completed:    6000 (100.00%)
  Queries lost:         0 (0.00%)
  Response codes:       NOERROR 6000 (100.00%)
  Queries per second:   100.000000
  Average Latency (s):  0.000200 (min 0.000100, max 0.010000)
  Latency StdDev (s):   0.000300
EOF

  {
    printf 'qps\trc\tlog\n'
    printf '100\t0\t%s\n' "$dir/03-dnsperf/dnsperf-qps-100.log"
  } >"$dir/03-dnsperf/dnsperf-summary.tsv"

  echo "0" >"$dir/04-perf-tests/perf-tests-run.rc"
}

assert_verdict() {
  local dir="$1"
  local expected="$2"
  ARTIFACT_DIR="$dir" results_compute_verdict >/dev/null
  actual="$(cat "$dir/05-report/verdict.txt")"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected verdict '$expected', got '$actual'" >&2
    echo "blocking reasons:" >&2
    cat "$dir/05-report/verdict-blocking-reasons.txt" >&2 || true
    echo "risk reasons:" >&2
    cat "$dir/05-report/verdict-risk-reasons.txt" >&2 || true
    exit 1
  fi
}

case_dir="$TMP_DIR/accepted"
write_common_success_artifacts "$case_dir"
assert_verdict "$case_dir" "Accepted"

case_dir="$TMP_DIR/dns-operator-blocked"
write_common_success_artifacts "$case_dir"
sed -i 's/Available=True/Available=False/' "$case_dir/00-preflight/dns-operator-gate.txt"
assert_verdict "$case_dir" "Blocked"
grep -Fq "DNS operator gate unhealthy" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/dns-test-failed"
write_common_success_artifacts "$case_dir"
cat >"$case_dir/01-openshift-tests/dns-summary.txt" <<'EOF'
failed: (800ms) "dns failing lookup"
EOF
echo "1" >"$case_dir/01-openshift-tests/dns-test-output.rc"
assert_verdict "$case_dir" "Blocked"
grep -Fq "Selected DNS conformance tests failed" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/monitor-risk"
write_common_success_artifacts "$case_dir"
echo "1" >"$case_dir/01-openshift-tests/dns-test-output.rc"
assert_verdict "$case_dir" "Accepted with risks"
grep -Fq "openshift-tests returned rc=1 with no selected DNS test failures" "$case_dir/05-report/verdict-risk-reasons.txt"

case_dir="$TMP_DIR/external-risk"
write_common_success_artifacts "$case_dir"
sed -i '/registry.redhat.io/,$d' "$case_dir/02-node-sweep/node-dns-sweep.txt"
assert_verdict "$case_dir" "Accepted with risks"
grep -Fq "External DNS lookup missing on 1 of 1 swept nodes" "$case_dir/05-report/verdict-risk-reasons.txt"

case_dir="$TMP_DIR/internal-blocked"
write_common_success_artifacts "$case_dir"
sed -i '/openshift.default.svc/,+1d' "$case_dir/02-node-sweep/node-dns-sweep.txt"
assert_verdict "$case_dir" "Blocked"
grep -Fq "Node sweep internal lookups incomplete" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/node-count-blocked"
write_common_success_artifacts "$case_dir"
cat >>"$case_dir/00-preflight/nodes-wide.txt" <<'EOF'
node-b   Ready    worker   1d    v1.31.0   192.0.2.12
EOF
assert_verdict "$case_dir" "Blocked"
grep -Fq "Node sweep did not cover all nodes: swept=1, cluster-nodes=2" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/dnsperf-blocked"
write_common_success_artifacts "$case_dir"
sed -i $'s/100\\t0/100\\t1/' "$case_dir/03-dnsperf/dnsperf-summary.tsv"
assert_verdict "$case_dir" "Blocked"
grep -Fq "dnsperf failed qps steps: 100" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/perf-tests-risk"
write_common_success_artifacts "$case_dir"
echo "7" >"$case_dir/04-perf-tests/perf-tests-run.rc"
assert_verdict "$case_dir" "Accepted with risks"
grep -Fq "Optional perf-tests returned rc=7" "$case_dir/05-report/verdict-risk-reasons.txt"
```

Make it executable:

```bash
chmod +x tests/results-verdict.sh
```

Add it to `scripts/check-static.sh` syntax checks and shellcheck block:

```bash
bash -n tests/results-verdict.sh
```

```bash
tests/results-verdict.sh
```

- [ ] **Step 2: Run the new test and verify it fails**

Run:

```bash
bash tests/results-verdict.sh
```

Expected: FAIL with `results_compute_verdict: command not found`.

- [ ] **Step 3: Add verdict helper functions to `results.sh`**

Add these functions after `results_read_artifact_rc` in `dns-validation/lib/results.sh`:

```bash
results_reason_line() {
  local reason="$1"
  local artifact="${2:-}"
  if [[ -n "$artifact" ]]; then
    printf -- '- %s (artifact: `%s`)\n' "$reason" "$artifact"
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
    function flush_block() {
      if (!in_block) return
      nodes++
      if (block ~ /kubernetes\.default\.svc\./ && block ~ /Address:[[:space:]]*[0-9]/) kubernetes++
      if (block ~ /openshift\.default\.svc\./ && block ~ /Address:[[:space:]]*[0-9]/) openshift++
      if (block ~ /registry\.redhat\.io[[:space:]]+canonical name/ || block ~ /Name:[[:space:]]*registry\.redhat\.io/ || block ~ /registry-proxy/ || block ~ /registry\.redhat\.io/ && block ~ /Address:[[:space:]]*[0-9]/) external++
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
      printf "%d\t%d\t%d\t%d\n", nodes, kubernetes, openshift, external
    }
  ' "$file"
}

results_cluster_node_count() {
  local file="$ARTIFACT_DIR/00-preflight/nodes-wide.txt"
  if [[ -s "$file" ]]; then
    awk 'NR > 1 && NF > 0 { count++ } END { print count + 0 }' "$file"
  else
    echo 0
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
  if [[ ! -s "$node_file" ]]; then
    results_add_blocking_reason "Node DNS sweep artifact missing" "$node_file"
  elif [[ "$cluster_nodes" != "0" && "$nodes" != "$cluster_nodes" ]]; then
    results_add_blocking_reason "Node sweep did not cover all nodes: swept=$nodes, cluster-nodes=$cluster_nodes" "$node_file"
  elif [[ "$nodes" == "0" || "$kubernetes" != "$nodes" || "$openshift" != "$nodes" ]]; then
    results_add_blocking_reason "Node sweep internal lookups incomplete: kubernetes=$kubernetes/$nodes, openshift=$openshift/$nodes" "$node_file"
  elif [[ "$external" != "$nodes" ]]; then
    results_add_risk_reason "External DNS lookup missing on $((nodes - external)) of $nodes swept nodes" "$node_file"
  fi

  local dnsperf_file failed_qps
  dnsperf_file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
  failed_qps="$(results_dnsperf_failure_qps)"
  if [[ ! -s "$dnsperf_file" ]]; then
    results_add_blocking_reason "dnsperf summary artifact missing" "$dnsperf_file"
  elif [[ -n "$failed_qps" ]]; then
    results_add_blocking_reason "dnsperf failed qps steps: $failed_qps" "$dnsperf_file"
  fi

  local perf_rc_file perf_rc deep_rc_file deep_rc
  perf_rc_file="$ARTIFACT_DIR/04-perf-tests/perf-tests-run.rc"
  perf_rc="$(results_read_artifact_rc "$perf_rc_file")"
  if [[ "$perf_rc" == "not run" ]]; then
    results_add_risk_reason "Optional perf-tests not run" "$perf_rc_file"
  elif [[ "$perf_rc" != "0" ]]; then
    results_add_risk_reason "Optional perf-tests returned rc=$perf_rc" "$perf_rc_file"
  fi

  deep_rc_file="$ARTIFACT_DIR/05-report/deep-diagnostics.rc"
  deep_rc="$(results_read_artifact_rc "$deep_rc_file")"
  if [[ "$deep_rc" != "0" && "$deep_rc" != "not run" ]]; then
    results_add_risk_reason "deep diagnostics incomplete: rc=$deep_rc" "$deep_rc_file"
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
```

- [ ] **Step 4: Replace the old verdict renderer**

Replace the body of `render_dns_validation_verdict` in `dns-validation/lib/results.sh` with:

```bash
render_dns_validation_verdict() {
  render_verdict_section
}
```

In `render_node_sweep_stats`, add the cluster node count immediately after the section header:

```bash
  local cluster_nodes
  cluster_nodes="$(results_cluster_node_count)"
  echo "- Cluster nodes from preflight: $cluster_nodes"
```

- [ ] **Step 5: Update `report` to compute verdicts before rendering**

In `dns-validation/lib/perf.sh`, update `report` before `summary="$(render_results_summary "$f")"`:

```bash
  results_compute_verdict
```

- [ ] **Step 6: Run the verdict tests**

Run:

```bash
bash tests/results-verdict.sh
```

Expected: PASS.

- [ ] **Step 7: Run report regression and static checks**

Run:

```bash
bash tests/report-results-summary.sh
bash scripts/check-static.sh
```

Expected: PASS. If `tests/report-results-summary.sh` fails because the final verdict text changed, update only the expected verdict assertions to check `- Verdict: Blocked` plus the relevant blocking/risk reasons.

- [ ] **Step 8: Commit**

```bash
git add dns-validation/lib/results.sh dns-validation/lib/perf.sh scripts/check-static.sh tests/results-verdict.sh tests/report-results-summary.sh
git commit -m "feat: compute DNS validation verdicts"
```

---

### Task 3: Report DNS Upstream Mode And Lightweight Diagnostics

**Files:**
- Modify: `dns-validation/lib/cluster.sh`
- Modify: `dns-validation/lib/results.sh`
- Modify: `tests/preflight-dns-operator-gate.sh`
- Modify: `tests/report-results-summary.sh`

- [ ] **Step 1: Extend the preflight fake `oc` test with expected diagnostic calls**

In `tests/preflight-dns-operator-gate.sh`, teach the fake `oc` script to return successful output for these calls:

```bash
"-n openshift-dns get pods,daemonsets,deployments,services,endpoints -o wide"|\
"-n openshift-dns-operator get pods,deployments,services -o wide"|\
"-n openshift-dns get events --sort-by=.metadata.creationTimestamp"|\
"-n openshift-dns-operator get events --sort-by=.metadata.creationTimestamp"|\
"-n openshift-dns get endpointslices.discovery.k8s.io -o wide")
  echo "ok"
  exit 0
  ;;
```

Add this jsonpath case to the fake `oc` script:

```bash
if [[ "$args" == "get dns.operator/default -o jsonpath={range .spec.upstreamResolvers.upstreams[*]}{.type}{\" \"}{.address}{\" \"}{.port}{\"\\n\"}{end}" ]]; then
  echo "SystemResolvConf  53"
  exit 0
fi

if [[ "$args" == "-n openshift-dns get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase --no-headers" ]]; then
  echo "dns-default-a node-a Running"
  exit 0
fi
```

After the existing `diff` assertion, add:

```bash
test -s "$TMP_DIR/artifacts/00-preflight/dns-upstream-resolvers.txt"
grep -Fq "SystemResolvConf" "$TMP_DIR/artifacts/00-preflight/dns-upstream-resolvers.txt"
test -s "$TMP_DIR/artifacts/00-preflight/openshift-dns-events.txt"
test -s "$TMP_DIR/artifacts/00-preflight/coredns-pod-placement.txt"
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
bash tests/preflight-dns-operator-gate.sh
```

Expected: FAIL because the new diagnostic artifact files are not created yet.

- [ ] **Step 3: Add lightweight diagnostics collection**

Add this function to `dns-validation/lib/cluster.sh` after `preflight`:

```bash
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
```

Call it near the end of `preflight`, before the final `log`:

```bash
  collect_lightweight_diagnostics
```

Call it near the end of `node_sweep`, before the final `log`, so diagnostics include post-sweep DNS pod placement and recent events:

```bash
  collect_lightweight_diagnostics
```

- [ ] **Step 4: Render upstream resolver mode in the report**

Add this helper to `dns-validation/lib/results.sh`:

```bash
results_dns_upstream_summary() {
  local file="$ARTIFACT_DIR/00-preflight/dns-upstream-resolvers.txt"
  if [[ -s "$file" ]]; then
    paste -sd '; ' "$file"
  else
    echo "not captured"
  fi
}
```

Add this line to `render_results_summary` after the DNS operator gate line:

```bash
- DNS upstream resolvers: $(results_dns_upstream_summary)
```

- [ ] **Step 5: Update report regression expected output**

In `tests/report-results-summary.sh`, create the synthetic upstream artifact:

```bash
cat >"$ARTIFACT_DIR/00-preflight/dns-upstream-resolvers.txt" <<'EOF'
SystemResolvConf  53
EOF
```

Add report assertions:

```bash
grep -Fq -- "- DNS upstream resolvers: SystemResolvConf  53" "$REPORT"
grep -Fq -- "- DNS upstream resolvers: SystemResolvConf  53" "$TMP_DIR/report.out"
```

- [ ] **Step 6: Run the focused tests**

Run:

```bash
bash tests/preflight-dns-operator-gate.sh
bash tests/report-results-summary.sh
```

Expected: PASS.

- [ ] **Step 7: Run static checks**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add dns-validation/lib/cluster.sh dns-validation/lib/results.sh tests/preflight-dns-operator-gate.sh tests/report-results-summary.sh
git commit -m "feat: capture DNS lightweight diagnostics"
```

---

### Task 4: Add Deep Diagnostics Triggered By Risky Or Blocked Verdicts

**Files:**
- Modify: `dns-validation/lib/cluster.sh`
- Modify: `dns-validation/lib/perf.sh`
- Modify: `dns-validation/lib/results.sh`
- Create: `tests/deep-diagnostics-trigger.sh`
- Modify: `scripts/check-static.sh`

- [ ] **Step 1: Write the failing deep diagnostics test**

Create `tests/deep-diagnostics-trigger.sh`:

```bash
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
args="$*"

case "$args" in
  "-n openshift-dns get pods -o jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
    echo "dns-default-a"
    exit 0
    ;;
  "-n openshift-dns-operator get pods -o jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
    echo "dns-operator-a"
    exit 0
    ;;
  "-n openshift-dns logs dns-default-a --all-containers --tail=-1")
    echo "dns pod log"
    exit 0
    ;;
  "-n openshift-dns-operator logs dns-operator-a --all-containers --tail=-1")
    echo "operator pod log"
    exit 0
    ;;
  "-n openshift-dns describe pod dns-default-a")
    echo "dns pod describe"
    exit 0
    ;;
  "-n openshift-dns get events --sort-by=.metadata.creationTimestamp"|\
  "-n openshift-dns-operator get events --sort-by=.metadata.creationTimestamp"|\
  "-n dns-validation get events --sort-by=.metadata.creationTimestamp")
    echo "events"
    exit 0
    ;;
esac

echo "unexpected oc call: $args" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR/00-preflight" "$ARTIFACT_DIR/01-openshift-tests" "$ARTIFACT_DIR/02-node-sweep" "$ARTIFACT_DIR/03-dnsperf" "$ARTIFACT_DIR/04-perf-tests" "$ARTIFACT_DIR/05-report"

cat >"$ARTIFACT_DIR/00-preflight/dns-operator-gate.txt" <<'EOF'
Available=False
Progressing=False
Degraded=True
Expected: Available=True, Progressing=False, Degraded=False
EOF

cat >"$ARTIFACT_DIR/01-openshift-tests/dns-summary.txt" <<'EOF'
passed: (1s) "dns lookup"
EOF
echo "0" >"$ARTIFACT_DIR/01-openshift-tests/dns-test-output.rc"
echo '"dns lookup"' >"$ARTIFACT_DIR/01-openshift-tests/dns-tests.txt"
: >"$ARTIFACT_DIR/01-openshift-tests/dns-tests.excluded.txt"

cat >"$ARTIFACT_DIR/02-node-sweep/node-dns-sweep.txt" <<'EOF'
### pod=dns-sweep-a node=node-a
Name: kubernetes.default.svc.cluster.local
Address: 172.30.0.1
Name: openshift.default.svc.cluster.local
Address: 172.30.0.1
Name: registry.redhat.io
Address: 192.0.2.10
EOF

cat >"$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv" <<EOF
qps	rc	log
100	0	$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-100.log
EOF
cat >"$ARTIFACT_DIR/03-dnsperf/dnsperf-qps-100.log" <<'EOF'
Statistics:
  Queries sent:         6000
  Queries completed:    6000 (100.00%)
  Queries lost:         0 (0.00%)
  Response codes:       NOERROR 6000 (100.00%)
  Queries per second:   100.000000
  Average Latency (s):  0.000200 (min 0.000100, max 0.010000)
  Latency StdDev (s):   0.000300
EOF

CONFIG_FILE="$TMP_DIR/validation.env"
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
EOF

PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" report

test -s "$ARTIFACT_DIR/05-report/deep-diagnostics/openshift-dns-dns-default-a.log"
test -s "$ARTIFACT_DIR/05-report/deep-diagnostics/openshift-dns-operator-dns-operator-a.log"
test -s "$ARTIFACT_DIR/05-report/deep-diagnostics/openshift-dns-events.txt"
grep -Fxq "0" "$ARTIFACT_DIR/05-report/deep-diagnostics.rc"
grep -Fq -- "- Verdict: Blocked" "$ARTIFACT_DIR/05-report/dns-validation-report.md"
```

Make it executable:

```bash
chmod +x tests/deep-diagnostics-trigger.sh
```

Add it to `scripts/check-static.sh` syntax checks, execution checks, and shellcheck block.

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
bash tests/deep-diagnostics-trigger.sh
```

Expected: FAIL because `collect_deep_diagnostics` has not been implemented and the report does not collect deep artifacts.

- [ ] **Step 3: Implement deep diagnostics collection**

Add this function to `dns-validation/lib/cluster.sh`:

```bash
collect_deep_diagnostics() {
  init_dirs
  require_cmd oc
  local d="$ARTIFACT_DIR/05-report/deep-diagnostics"
  local rc=0
  mkdir -p "$d"

  log "Capturing deep DNS diagnostics."

  local pod
  for pod in $(oc -n openshift-dns get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true); do
    run_out "$d/openshift-dns-${pod}.log" oc -n openshift-dns logs "$pod" --all-containers --tail=-1 || rc=1
    run_out "$d/openshift-dns-${pod}.describe.txt" oc -n openshift-dns describe pod "$pod" || rc=1
  done

  for pod in $(oc -n openshift-dns-operator get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true); do
    run_out "$d/openshift-dns-operator-${pod}.log" oc -n openshift-dns-operator logs "$pod" --all-containers --tail=-1 || rc=1
  done

  run_out "$d/openshift-dns-events.txt" oc -n openshift-dns get events --sort-by=.metadata.creationTimestamp || rc=1
  run_out "$d/openshift-dns-operator-events.txt" oc -n openshift-dns-operator get events --sort-by=.metadata.creationTimestamp || rc=1
  run_out "$d/validation-namespace-events.txt" oc -n "$VALIDATION_NAMESPACE" get events --sort-by=.metadata.creationTimestamp || rc=1

  echo "$rc" >"$ARTIFACT_DIR/05-report/deep-diagnostics.rc"
  if [[ "$rc" -eq 0 ]]; then
    log "Deep DNS diagnostics captured: $d"
  else
    warn "Deep DNS diagnostics incomplete; see $d"
  fi
  return 0
}
```

- [ ] **Step 4: Trigger deep diagnostics from report generation**

In `dns-validation/lib/perf.sh`, update `report` so the top of the function looks like this:

```bash
report() {
  init_dirs
  read_runtime

  local f="$ARTIFACT_DIR/05-report/dns-validation-report.md"
  local summary verdict

  results_compute_verdict
  verdict="$(results_verdict)"
  if [[ "$verdict" != "Accepted" ]]; then
    collect_deep_diagnostics
    results_compute_verdict
  fi

  summary="$(render_results_summary "$f")"
```

- [ ] **Step 5: Render deep diagnostics location**

Add this helper to `dns-validation/lib/results.sh`:

```bash
results_deep_diagnostics_summary() {
  local d="$ARTIFACT_DIR/05-report/deep-diagnostics"
  local rc
  rc="$(results_read_artifact_rc "$ARTIFACT_DIR/05-report/deep-diagnostics.rc")"
  if [[ -d "$d" ]]; then
    printf 'rc=%s, artifacts=`%s`\n' "$rc" "$d"
  else
    echo "not collected"
  fi
}
```

Add this line to `render_results_summary` after the perf-tests line:

```bash
- Deep diagnostics: $(results_deep_diagnostics_summary)
```

- [ ] **Step 6: Run the focused test**

Run:

```bash
bash tests/deep-diagnostics-trigger.sh
```

Expected: PASS.

- [ ] **Step 7: Run all shell tests**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add dns-validation/lib/cluster.sh dns-validation/lib/perf.sh dns-validation/lib/results.sh scripts/check-static.sh tests/deep-diagnostics-trigger.sh
git commit -m "feat: collect DNS deep diagnostics on risky verdicts"
```

---

### Task 5: Add Opt-In dnsperf Loss And Latency Thresholds

**Files:**
- Modify: `dns-validation/bin/ocp-dns-validate:67-73`
- Modify: `dns-validation/config/validation.env.example`
- Modify: `dns-validation/lib/results.sh`
- Modify: `tests/results-verdict.sh`

- [ ] **Step 1: Add failing threshold cases to the verdict test**

Append these cases to `tests/results-verdict.sh`:

```bash
case_dir="$TMP_DIR/dnsperf-loss-threshold"
write_common_success_artifacts "$case_dir"
DNSPERF_MAX_LOST_PERCENT="0.0" ARTIFACT_DIR="$case_dir" results_compute_verdict >/dev/null
grep -Fxq "Accepted" "$case_dir/05-report/verdict.txt"

cat >"$case_dir/03-dnsperf/dnsperf-qps-100.log" <<'EOF'
Statistics:
  Queries sent:         6000
  Queries completed:    5990 (99.83%)
  Queries lost:         10 (0.17%)
  Response codes:       NOERROR 5990 (100.00%)
  Queries per second:   99.833333
  Average Latency (s):  0.000200 (min 0.000100, max 0.010000)
  Latency StdDev (s):   0.000300
EOF
DNSPERF_MAX_LOST_PERCENT="0.0" ARTIFACT_DIR="$case_dir" results_compute_verdict >/dev/null
grep -Fxq "Blocked" "$case_dir/05-report/verdict.txt"
grep -Fq "dnsperf threshold failures: 100qps lost=0.17%" "$case_dir/05-report/verdict-blocking-reasons.txt"

case_dir="$TMP_DIR/dnsperf-latency-threshold"
write_common_success_artifacts "$case_dir"
DNSPERF_MAX_AVG_LATENCY_SECONDS="0.000100" ARTIFACT_DIR="$case_dir" results_compute_verdict >/dev/null
grep -Fxq "Blocked" "$case_dir/05-report/verdict.txt"
grep -Fq "100qps avg-latency=0.000200s" "$case_dir/05-report/verdict-blocking-reasons.txt"
```

- [ ] **Step 2: Run the threshold test and verify it fails**

Run:

```bash
bash tests/results-verdict.sh
```

Expected: FAIL because `DNSPERF_MAX_LOST_PERCENT` and `DNSPERF_MAX_AVG_LATENCY_SECONDS` are not honored yet.

- [ ] **Step 3: Add default threshold configuration**

In `dns-validation/bin/ocp-dns-validate`, after `DNSPERF_EXTRA_ARGS` defaults, add:

```bash
DNSPERF_MAX_LOST_PERCENT="${DNSPERF_MAX_LOST_PERCENT:-}"
DNSPERF_MAX_AVG_LATENCY_SECONDS="${DNSPERF_MAX_AVG_LATENCY_SECONDS:-}"
```

In `dns-validation/config/validation.env.example`, after `DNSPERF_EXTRA_ARGS`, add:

```bash
# Optional dnsperf verdict thresholds. Leave empty to gate only on dnsperf command rc per QPS step.
DNSPERF_MAX_LOST_PERCENT=""
DNSPERF_MAX_AVG_LATENCY_SECONDS=""
```

- [ ] **Step 4: Add threshold parsing to the verdict engine**

Add this function to `dns-validation/lib/results.sh` after `results_dnsperf_log_stats`:

```bash
results_dnsperf_log_threshold_failures() {
  local file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
  local loss_threshold="${DNSPERF_MAX_LOST_PERCENT:-}"
  local latency_threshold="${DNSPERF_MAX_AVG_LATENCY_SECONDS:-}"
  local failures=""
  local qps rc log_path resolved stats
  local sent completed completed_pct lost lost_pct achieved avg min max stddev codes

  [[ -s "$file" ]] || return 0
  [[ -n "$loss_threshold" || -n "$latency_threshold" ]] || return 0

  while IFS=$'\t' read -r qps rc log_path; do
    resolved="$(results_resolve_artifact_path "$log_path" "$ARTIFACT_DIR/03-dnsperf")"
    stats="$(results_dnsperf_log_stats "$resolved")"
    IFS=$'\t' read -r sent completed completed_pct lost lost_pct achieved avg min max stddev codes <<<"$stats"
    lost_pct="${lost_pct%%%}"
    if [[ -n "$loss_threshold" && "$lost_pct" != "unknown" ]]; then
      awk -v actual="$lost_pct" -v limit="$loss_threshold" 'BEGIN { exit !(actual > limit) }' &&
        failures="${failures}${failures:+, }${qps}qps lost=${lost_pct}%"
    fi
    if [[ -n "$latency_threshold" && "$avg" != "unknown" ]]; then
      awk -v actual="$avg" -v limit="$latency_threshold" 'BEGIN { exit !(actual > limit) }' &&
        failures="${failures}${failures:+, }${qps}qps avg-latency=${avg}s"
    fi
  done < <(awk -F '\t' 'NR > 1 { print $1 "\t" $2 "\t" $3 }' "$file")

  printf '%s\n' "$failures"
}
```

In `results_compute_verdict`, replace the dnsperf block:

```bash
  local dnsperf_file failed_qps
  dnsperf_file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
  failed_qps="$(results_dnsperf_failure_qps)"
  if [[ ! -s "$dnsperf_file" ]]; then
    results_add_blocking_reason "dnsperf summary artifact missing" "$dnsperf_file"
  elif [[ -n "$failed_qps" ]]; then
    results_add_blocking_reason "dnsperf failed qps steps: $failed_qps" "$dnsperf_file"
  fi
```

with:

```bash
  local dnsperf_file failed_qps threshold_failures
  dnsperf_file="$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv"
  failed_qps="$(results_dnsperf_failure_qps)"
  threshold_failures="$(results_dnsperf_log_threshold_failures)"
  if [[ ! -s "$dnsperf_file" ]]; then
    results_add_blocking_reason "dnsperf summary artifact missing" "$dnsperf_file"
  elif [[ -n "$failed_qps" ]]; then
    results_add_blocking_reason "dnsperf failed qps steps: $failed_qps" "$dnsperf_file"
  fi
  if [[ -n "$threshold_failures" ]]; then
    results_add_blocking_reason "dnsperf threshold failures: $threshold_failures" "$dnsperf_file"
  fi
```

- [ ] **Step 5: Run focused verdict tests**

Run:

```bash
bash tests/results-verdict.sh
```

Expected: PASS.

- [ ] **Step 6: Run static checks**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add dns-validation/bin/ocp-dns-validate dns-validation/config/validation.env.example dns-validation/lib/results.sh tests/results-verdict.sh
git commit -m "feat: add dnsperf verdict thresholds"
```

---

### Task 6: Update Report Regression And User Documentation

**Files:**
- Modify: `tests/report-results-summary.sh`
- Modify: `dns-validation/README.md`
- Modify: `README.md`

- [ ] **Step 1: Update report regression to assert structured verdict sections**

In `tests/report-results-summary.sh`, replace the final verdict assertion:

```bash
grep -Fq "## DNS validation verdict" "$REPORT"
grep -Fq -- "- Verdict: Blocked" "$REPORT"
grep -Fq -- "- Blocking reasons:" "$REPORT"
grep -Fq -- "Selected DNS conformance tests failed: failed=1" "$REPORT"
grep -Fq -- "dnsperf failed qps steps: 500" "$REPORT"
```

Update the final-line assertion to match the new final verdict line:

```bash
if [[ "$(tail -n 1 "$REPORT")" != "  - dnsperf failed qps steps: 500 (artifact: \`$ARTIFACT_DIR/03-dnsperf/dnsperf-summary.tsv\`)" ]]; then
  echo "report should end with the structured verdict reasons" >&2
  tail -n 20 "$REPORT" >&2
  exit 1
fi
```

Use the same expected final line for `$TMP_DIR/report.out`.

- [ ] **Step 2: Run the report test and verify failure before docs/report updates are complete**

Run:

```bash
bash tests/report-results-summary.sh
```

Expected: PASS if earlier tasks already render structured verdicts. If it fails, update only assertions that refer to changed wording and keep the semantic checks for verdict, blocking reasons, and artifact paths.

- [ ] **Step 3: Document verdicts and diagnostics in `dns-validation/README.md`**

Add this section after `## Artifacts`:

```markdown
## Verdicts and diagnostics

The report computes a structured DNS validation verdict:

- `Accepted`: required DNS checks passed and no risk-only conditions were found.
- `Accepted with risks`: DNS appears usable, but evidence is incomplete or adjacent symptoms were found.
- `Blocked`: a direct DNS validation failure was found.

The tool captures lightweight diagnostics during normal validation, including DNS operator state, DNS workloads, DNS events, CoreDNS pod placement, upstream resolver mode, and node-sweep lookup summaries.

When the preliminary verdict is `Blocked` or `Accepted with risks`, report generation also captures deep diagnostics under:

```text
runs/<timestamp>/05-report/deep-diagnostics/
```

Deep diagnostics include DNS pod logs, DNS operator logs, pod descriptions, and relevant events. If deep diagnostics collection is incomplete, the original verdict remains intact and the report adds a risk reason.
```

Add this threshold note under the existing dnsperf configuration example:

```markdown
Optional dnsperf verdict thresholds can block the verdict on loss or average latency while still keeping the per-QPS command return code gate:

```text
DNSPERF_MAX_LOST_PERCENT="0.0"
DNSPERF_MAX_AVG_LATENCY_SECONDS="0.005"
```

Leave these values empty to use only the dnsperf command return code per QPS step.
```

- [ ] **Step 4: Update top-level README summary**

In `README.md`, update the DNS validation bullet list to include:

```markdown
- structured `Accepted`, `Accepted with risks`, or `Blocked` verdicts
- lightweight and failure-triggered DNS diagnostics
```

- [ ] **Step 5: Run static checks**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add README.md dns-validation/README.md tests/report-results-summary.sh
git commit -m "docs: explain DNS validation verdicts"
```

---

### Task 7: Final Verification

**Files:**
- No new code files expected.
- Review all changed files from Tasks 1-6.

- [ ] **Step 1: Run the full static and regression suite**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 2: Run the CLI report action against synthetic report fixture**

Run:

```bash
bash tests/report-results-summary.sh
```

Expected: PASS and report contains:

```text
## DNS validation verdict
- Verdict: Blocked
```

- [ ] **Step 3: Inspect the final diff**

Run:

```bash
git --no-pager diff --stat HEAD~6..HEAD
git --no-pager diff HEAD~6..HEAD -- dns-validation/bin/ocp-dns-validate dns-validation/lib/cluster.sh dns-validation/lib/perf.sh dns-validation/lib/results.sh scripts/check-static.sh tests README.md dns-validation/README.md
```

Expected:

- `results.sh` contains all `results_*` and `render_*` helpers.
- `perf.sh` no longer contains `results_*` or `render_*` helper definitions.
- `cluster.sh` contains live `oc` collection helpers.
- Tests cover verdict, diagnostics, and report regression behavior.

- [ ] **Step 4: Verify shellcheck has no source ordering issues**

Run:

```bash
shellcheck -x dns-validation/bin/ocp-dns-validate dns-validation/lib/common.sh dns-validation/lib/cluster.sh dns-validation/lib/results.sh dns-validation/lib/perf.sh
```

Expected: PASS.

- [ ] **Step 5: Commit final verification fixes if any were needed**

If Step 1-4 required fixes, commit them:

```bash
git add dns-validation/bin/ocp-dns-validate dns-validation/lib/cluster.sh dns-validation/lib/perf.sh dns-validation/lib/results.sh scripts/check-static.sh tests README.md dns-validation/README.md
git commit -m "test: verify DNS validation MVP"
```

If no fixes were needed, do not create an empty commit.
