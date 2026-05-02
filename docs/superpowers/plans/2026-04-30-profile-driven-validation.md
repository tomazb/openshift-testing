# Profile-Driven DNS Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add named DNS validation profiles (`day1`, `day2`, `ci`, `customer-evidence`) that select validation defaults while preserving user override control through `validation.env`.

**Architecture:** Keep the existing Bash CLI and environment-file configuration model. Add profile `.env` files that contain baseline and override settings, resolve the selected profile before normal config validation, then source user `validation.env` last so concrete settings there win. Report behavior is controlled by reusable settings (`DNS_VALIDATION_REPORT_MODE`, `DNS_VALIDATION_DEEP_DIAGNOSTICS`) rather than hardcoded profile-name branches.

**Tech Stack:** Bash, existing shell regression tests, `bash -n`, ShellCheck through `scripts/check-static.sh`.

---

## File Structure

- **Create:** `dns-validation/config/profiles/default.env` - baseline settings for the default profile and shared profile defaults
- **Create:** `dns-validation/config/profiles/day1.env` - conservative post-install overrides
- **Create:** `dns-validation/config/profiles/day2.env` - operational-health overrides
- **Create:** `dns-validation/config/profiles/ci.env` - deterministic CI overrides
- **Create:** `dns-validation/config/profiles/customer-evidence.env` - customer evidence collection overrides
- **Create:** `tests/profile-loading.sh` - CLI-level profile selection, precedence, and override tests
- **Modify:** `dns-validation/bin/ocp-dns-validate` - parse `--profile`, resolve/load profiles, validate new settings
- **Modify:** `dns-validation/lib/cluster.sh` - expose resolved profile settings in `init` artifacts for tests
- **Modify:** `dns-validation/lib/perf.sh` - add report profile header and deep-diagnostics trigger setting
- **Modify:** `dns-validation/lib/results.sh` - render full, condensed, and CI report modes
- **Modify:** `dns-validation/config/validation.env.example` - document `VALIDATION_PROFILE` and profile-controlled settings
- **Modify:** `dns-validation/README.md` - document profile usage and override precedence
- **Modify:** `scripts/check-static.sh` - syntax-check profile files
- **Modify:** `tests/report-results-summary.sh` - assert profile header and report modes

---

### Task 1: Add Profile Files and Static Syntax Checks

**Files:**
- Create: `dns-validation/config/profiles/default.env`
- Create: `dns-validation/config/profiles/day1.env`
- Create: `dns-validation/config/profiles/day2.env`
- Create: `dns-validation/config/profiles/ci.env`
- Create: `dns-validation/config/profiles/customer-evidence.env`
- Modify: `scripts/check-static.sh`

- [ ] **Step 1: Create the profile directory**

Run:

```bash
mkdir -p dns-validation/config/profiles
```

Expected: `dns-validation/config/profiles/` exists.

- [ ] **Step 2: Create the default profile baseline**

Create `dns-validation/config/profiles/default.env`:

```bash
# Default DNS validation profile.
# The CLI loader sources this before any named profile and before validation.env.

DNSPERF_QPS_STEPS="100 500 1000 2000"
DNSPERF_DURATION_SECONDS="60"
DNSPERF_CLIENTS="5"
DNSPERF_THREADS="2"
DNSPERF_STATS_INTERVAL="10"
DNSPERF_MAX_LOST_PERCENT=""
DNSPERF_MAX_AVG_LATENCY_SECONDS=""

QUERY_REPEAT_COUNT="1000"

PERF_TESTS_RUN_LENGTH_SECONDS="60"
PERF_TESTS_MAX_QPS="500 1000 2000"

INCLUDE_SERIAL_DNS_TESTS="false"
DNS_TEST_EXCLUDE_REGEX="DNS should answer A and AAAA queries for a dual-stack service|DNS should answer queries using the local DNS endpoint"

DNS_VALIDATION_REPORT_MODE="full"
DNS_VALIDATION_DEEP_DIAGNOSTICS="on-risk"
```

- [ ] **Step 3: Create `day1.env`**

Create `dns-validation/config/profiles/day1.env`:

```bash
# day1: conservative post-install validation.

DNSPERF_DURATION_SECONDS="120"
DNSPERF_MAX_LOST_PERCENT="0.0"
INCLUDE_SERIAL_DNS_TESTS="true"
DNS_TEST_EXCLUDE_REGEX=""
DNS_VALIDATION_REPORT_MODE="full"
DNS_VALIDATION_DEEP_DIAGNOSTICS="on-risk"
```

- [ ] **Step 4: Create `day2.env`**

Create `dns-validation/config/profiles/day2.env`:

```bash
# day2: operational health for existing clusters.

DNSPERF_QPS_STEPS="100 500"
DNSPERF_DURATION_SECONDS="30"
DNSPERF_MAX_AVG_LATENCY_SECONDS="0.003"
INCLUDE_SERIAL_DNS_TESTS="false"
DNS_VALIDATION_REPORT_MODE="condensed"
DNS_VALIDATION_DEEP_DIAGNOSTICS="on-risk"
```

- [ ] **Step 5: Create `ci.env`**

Create `dns-validation/config/profiles/ci.env`:

```bash
# ci: deterministic noninteractive behavior.

AUTO_YES="true"
DNSPERF_MAX_LOST_PERCENT="0.0"
DNSPERF_MAX_AVG_LATENCY_SECONDS="0.005"
INCLUDE_SERIAL_DNS_TESTS="false"
DNS_TEST_EXCLUDE_REGEX=""
DNS_VALIDATION_REPORT_MODE="ci"
DNS_VALIDATION_DEEP_DIAGNOSTICS="on-risk"
```

- [ ] **Step 6: Create `customer-evidence.env`**

Create `dns-validation/config/profiles/customer-evidence.env`:

```bash
# customer-evidence: broader diagnostics and polished evidence.

DNSPERF_QPS_STEPS="100 500 1000 2000 5000"
DNSPERF_DURATION_SECONDS="120"
DNSPERF_CLIENTS="10"
DNSPERF_THREADS="4"
DNSPERF_MAX_LOST_PERCENT="0.5"
DNSPERF_MAX_AVG_LATENCY_SECONDS="0.010"
INCLUDE_SERIAL_DNS_TESTS="true"
DNS_VALIDATION_REPORT_MODE="full"
DNS_VALIDATION_DEEP_DIAGNOSTICS="always"
```

- [ ] **Step 7: Add profile syntax checks**

In `scripts/check-static.sh`, after the existing fixed `bash -n` checks and before the loop over `tests/*.sh`, add:

```bash
for profile_file in dns-validation/config/profiles/*.env; do
  bash -n "$profile_file"
done
```

Expected: static checks validate all profile files without listing each one manually.

- [ ] **Step 8: Run static checks**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add dns-validation/config/profiles scripts/check-static.sh
git commit -m "feat: add DNS validation profiles"
```

---

### Task 2: Resolve and Load Profiles in the CLI

**Files:**
- Modify: `dns-validation/bin/ocp-dns-validate`
- Modify: `dns-validation/lib/cluster.sh`
- Modify: `dns-validation/config/validation.env.example`
- Create: `tests/profile-loading.sh`

- [ ] **Step 1: Add profile state and profile helpers**

In `dns-validation/bin/ocp-dns-validate`, after the existing variable block:

```bash
CONFIG_FILE="$PROJECT_DIR/config/validation.env"
CONFIG_FILE_EXPLICIT="false"
ACTION="menu"
ACTION_ARGS=()
export AUTO_YES="false"
```

change it to:

```bash
CONFIG_FILE="$PROJECT_DIR/config/validation.env"
CONFIG_FILE_EXPLICIT="false"
PROFILE_NAME=""
RESOLVED_PROFILE="default"
ACTION="menu"
ACTION_ARGS=()
export AUTO_YES="false"
```

Then add these helper functions after `usage()`:

```bash
profile_names() {
  printf 'default day1 day2 ci customer-evidence'
}

is_valid_profile() {
  case "$1" in
    default|day1|day2|ci|customer-evidence) return 0 ;;
    *) return 1 ;;
  esac
}

read_config_profile() {
  local file="$1"
  [[ -f "$file" && -r "$file" ]] || return 0
  (
    set +u
    # shellcheck disable=SC1090
    source "$file"
    printf '%s\n' "${VALIDATION_PROFILE:-}"
  )
}

source_profile_file() {
  local file="$1" label="$2"
  [[ -f "$file" && -r "$file" ]] || { echo "ERROR: Missing $label profile file: $file" >&2; exit 2; }
  bash -n "$file" || { echo "ERROR: Invalid syntax in $label profile file: $file" >&2; exit 2; }
  # shellcheck disable=SC1090
  source "$file"
}

load_validation_profile() {
  local config_profile="" profile_dir default_profile profile_file

  if [[ -z "$PROFILE_NAME" && -z "${DNS_VALIDATION_PROFILE:-}" ]]; then
    config_profile="$(read_config_profile "$CONFIG_FILE")"
  fi

  RESOLVED_PROFILE="${PROFILE_NAME:-${DNS_VALIDATION_PROFILE:-${config_profile:-default}}}"
  [[ -n "$RESOLVED_PROFILE" ]] || RESOLVED_PROFILE="default"

  if ! is_valid_profile "$RESOLVED_PROFILE"; then
    echo "ERROR: Unknown validation profile '$RESOLVED_PROFILE'. Valid profiles: $(profile_names)" >&2
    exit 2
  fi

  profile_dir="$PROJECT_DIR/config/profiles"
  default_profile="$profile_dir/default.env"
  source_profile_file "$default_profile" "default"

  if [[ "$RESOLVED_PROFILE" != "default" ]]; then
    profile_file="$profile_dir/$RESOLVED_PROFILE.env"
    source_profile_file "$profile_file" "$RESOLVED_PROFILE"
  fi
}
```

- [ ] **Step 2: Parse `--profile`**

In the CLI argument `case` block in `dns-validation/bin/ocp-dns-validate`, add this branch before `-y|--yes`:

```bash
    -p|--profile)
      [[ $# -ge 2 && -n "${2:-}" && "${2:0:1}" != "-" ]] || { echo "ERROR: --profile requires a profile name" >&2; exit 2; }
      PROFILE_NAME="$2"
      shift 2
      ;;
```

Update the usage header:

```bash
Usage: $SCRIPT_NAME [--config FILE] [--profile NAME] [--yes] <action>
```

Add this section under the usage action list:

```bash
Profiles:
  default              Current baseline behavior
  day1                 Conservative post-install validation
  day2                 Operational health for existing clusters
  ci                   Deterministic noninteractive behavior
  customer-evidence    Broader diagnostics and polished evidence
```

- [ ] **Step 3: Load profiles before user config**

In `dns-validation/bin/ocp-dns-validate`, immediately after the CLI argument parsing loop and before the existing `if [[ -f "$CONFIG_FILE"` config block, add:

```bash
load_validation_profile
```

Immediately after the existing user config loading block, add:

```bash
VALIDATION_PROFILE="$RESOLVED_PROFILE"
export VALIDATION_PROFILE
```

Expected load order:

1. Resolve profile from `--profile`, `DNS_VALIDATION_PROFILE`, `VALIDATION_PROFILE` from config, or `default`.
2. Source `config/profiles/default.env`.
3. Source `config/profiles/<resolved-profile>.env` when the resolved profile is not `default`.
4. Source user `validation.env`.
5. Set `VALIDATION_PROFILE` back to the resolved profile name for reporting.

- [ ] **Step 4: Add fallback defaults and validation for new settings**

In `dns-validation/bin/ocp-dns-validate`, after the existing threshold fallback assignments:

```bash
DNSPERF_MAX_LOST_PERCENT="${DNSPERF_MAX_LOST_PERCENT:-}"
DNSPERF_MAX_AVG_LATENCY_SECONDS="${DNSPERF_MAX_AVG_LATENCY_SECONDS:-}"
```

add:

```bash
DNS_VALIDATION_REPORT_MODE="${DNS_VALIDATION_REPORT_MODE:-full}"
DNS_VALIDATION_DEEP_DIAGNOSTICS="${DNS_VALIDATION_DEEP_DIAGNOSTICS:-on-risk}"
```

In `validate_config()`, after the `INCLUDE_SERIAL_DNS_TESTS` case block, add:

```bash
  case "$DNS_VALIDATION_REPORT_MODE" in
    full|condensed|ci) ;;
    *) config_error "DNS_VALIDATION_REPORT_MODE must be one of: full, condensed, ci" ;;
  esac

  case "$DNS_VALIDATION_DEEP_DIAGNOSTICS" in
    on-risk|always) ;;
    *) config_error "DNS_VALIDATION_DEEP_DIAGNOSTICS must be one of: on-risk, always" ;;
  esac
```

- [ ] **Step 5: Include resolved profile settings in `init` run info**

In `dns-validation/lib/cluster.sh`, update the `init_action()` `run-info.txt` block from:

```bash
cat >"$ARTIFACT_DIR/run-info.txt" <<EOF
RUN_ID=$RUN_ID
ARTIFACT_DIR=$ARTIFACT_DIR
CONFIG_FILE=$CONFIG_FILE
VALIDATION_NAMESPACE=$VALIDATION_NAMESPACE
EOF
```

to:

```bash
cat >"$ARTIFACT_DIR/run-info.txt" <<EOF
RUN_ID=$RUN_ID
ARTIFACT_DIR=$ARTIFACT_DIR
CONFIG_FILE=$CONFIG_FILE
VALIDATION_NAMESPACE=$VALIDATION_NAMESPACE
VALIDATION_PROFILE=${VALIDATION_PROFILE:-default}
AUTO_YES=${AUTO_YES:-false}
INCLUDE_SERIAL_DNS_TESTS=$INCLUDE_SERIAL_DNS_TESTS
DNS_TEST_EXCLUDE_REGEX=$DNS_TEST_EXCLUDE_REGEX
DNSPERF_QPS_STEPS=$DNSPERF_QPS_STEPS
DNSPERF_DURATION_SECONDS=$DNSPERF_DURATION_SECONDS
DNSPERF_CLIENTS=$DNSPERF_CLIENTS
DNSPERF_THREADS=$DNSPERF_THREADS
DNSPERF_MAX_LOST_PERCENT=$DNSPERF_MAX_LOST_PERCENT
DNSPERF_MAX_AVG_LATENCY_SECONDS=$DNSPERF_MAX_AVG_LATENCY_SECONDS
DNS_VALIDATION_REPORT_MODE=$DNS_VALIDATION_REPORT_MODE
DNS_VALIDATION_DEEP_DIAGNOSTICS=$DNS_VALIDATION_DEEP_DIAGNOSTICS
EOF
```

Expected: `init` artifacts expose the resolved profile and concrete settings for regression tests.

- [ ] **Step 6: Document `VALIDATION_PROFILE` in the example config**

In `dns-validation/config/validation.env.example`, after the artifact location block, add:

```bash
# Validation profile. Used only when --profile and DNS_VALIDATION_PROFILE are not set.
# Supported: default, day1, day2, ci, customer-evidence.
# Profile values are defaults; settings later in this file override them.
# VALIDATION_PROFILE="default"
```

After the dnsperf threshold settings, add:

```bash
# Report rendering: full, condensed, or ci.
DNS_VALIDATION_REPORT_MODE="full"
# Deep diagnostics: on-risk or always.
DNS_VALIDATION_DEEP_DIAGNOSTICS="on-risk"
```

- [ ] **Step 7: Write CLI-level profile-loading tests**

Create `tests/profile-loading.sh`:

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
case "$*" in
  version|whoami)
    echo "ok"
    exit 0
    ;;
esac
echo "unexpected oc call: $*" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/oc"

write_config() {
  local file="$1" artifact_dir="$2"
  cat >"$file" <<EOF_CONFIG
ARTIFACT_DIR="$artifact_dir"
VALIDATION_NAMESPACE="dns-validation"
EOF_CONFIG
}

run_init() {
  local config_file="$1"
  shift
  PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$config_file" "$@" init
}

CONFIG_FILE="$TMP_DIR/default.env"
ARTIFACT_DIR="$TMP_DIR/default-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
run_init "$CONFIG_FILE" --profile day1 >"$TMP_DIR/day1.out"
grep -Fq "Initialization complete" "$TMP_DIR/day1.out"
grep -Fxq "VALIDATION_PROFILE=day1" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "INCLUDE_SERIAL_DNS_TESTS=true" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNSPERF_DURATION_SECONDS=120" "$ARTIFACT_DIR/run-info.txt"

CONFIG_FILE="$TMP_DIR/env-profile.env"
ARTIFACT_DIR="$TMP_DIR/env-profile-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
DNS_VALIDATION_PROFILE=ci run_init "$CONFIG_FILE" >"$TMP_DIR/ci.out"
grep -Fq "Initialization complete" "$TMP_DIR/ci.out"
grep -Fxq "VALIDATION_PROFILE=ci" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "AUTO_YES=true" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNS_VALIDATION_REPORT_MODE=ci" "$ARTIFACT_DIR/run-info.txt"

CONFIG_FILE="$TMP_DIR/config-profile.env"
ARTIFACT_DIR="$TMP_DIR/config-profile-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
printf '%s\n' 'VALIDATION_PROFILE="customer-evidence"' >>"$CONFIG_FILE"
run_init "$CONFIG_FILE" >"$TMP_DIR/customer-evidence.out"
grep -Fq "Initialization complete" "$TMP_DIR/customer-evidence.out"
grep -Fxq "VALIDATION_PROFILE=customer-evidence" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNSPERF_CLIENTS=10" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNS_VALIDATION_DEEP_DIAGNOSTICS=always" "$ARTIFACT_DIR/run-info.txt"

CONFIG_FILE="$TMP_DIR/override.env"
ARTIFACT_DIR="$TMP_DIR/override-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
cat >>"$CONFIG_FILE" <<'EOF_CONFIG'
VALIDATION_PROFILE="day1"
DNSPERF_DURATION_SECONDS="999"
EOF_CONFIG
run_init "$CONFIG_FILE" >"$TMP_DIR/override.out"
grep -Fq "Initialization complete" "$TMP_DIR/override.out"
grep -Fxq "VALIDATION_PROFILE=day1" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNSPERF_DURATION_SECONDS=999" "$ARTIFACT_DIR/run-info.txt"

CONFIG_FILE="$TMP_DIR/precedence.env"
ARTIFACT_DIR="$TMP_DIR/precedence-artifacts"
write_config "$CONFIG_FILE" "$ARTIFACT_DIR"
printf '%s\n' 'VALIDATION_PROFILE="customer-evidence"' >>"$CONFIG_FILE"
DNS_VALIDATION_PROFILE=ci run_init "$CONFIG_FILE" --profile day2 >"$TMP_DIR/precedence.out"
grep -Fq "Initialization complete" "$TMP_DIR/precedence.out"
grep -Fxq "VALIDATION_PROFILE=day2" "$ARTIFACT_DIR/run-info.txt"
grep -Fxq "DNS_VALIDATION_REPORT_MODE=condensed" "$ARTIFACT_DIR/run-info.txt"

set +e
PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" --profile does-not-exist init >"$TMP_DIR/unknown.out" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "unknown profile should fail" >&2
  exit 1
fi
grep -Fq "Unknown validation profile 'does-not-exist'" "$TMP_DIR/unknown.out"

echo "profile-loading: PASS"
```

- [ ] **Step 8: Make the test executable**

Run:

```bash
chmod +x tests/profile-loading.sh
```

- [ ] **Step 9: Run the new test**

Run:

```bash
bash tests/profile-loading.sh
```

Expected: `profile-loading: PASS`.

- [ ] **Step 10: Run full static checks**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS. The existing `test_scripts=(tests/*.sh)` loop picks up `tests/profile-loading.sh`.

- [ ] **Step 11: Commit**

```bash
git add dns-validation/bin/ocp-dns-validate \
  dns-validation/lib/cluster.sh \
  dns-validation/config/validation.env.example \
  tests/profile-loading.sh
git commit -m "feat: load DNS validation profiles"
```

---

### Task 3: Add Profile-Aware Report Rendering and Deep Diagnostics Control

**Files:**
- Modify: `dns-validation/lib/perf.sh`
- Modify: `dns-validation/lib/results.sh`
- Modify: `tests/report-results-summary.sh`

- [ ] **Step 1: Add profile header and diagnostics setting in `report()`**

In `dns-validation/lib/perf.sh`, replace the deep diagnostics trigger:

```bash
  if [[ "$verdict" != "$VERDICT_ACCEPTED" ]]; then
    collect_deep_diagnostics
    results_compute_verdict
  fi
```

with:

```bash
  if [[ "${DNS_VALIDATION_DEEP_DIAGNOSTICS:-on-risk}" == "always" || "$verdict" != "$VERDICT_ACCEPTED" ]]; then
    collect_deep_diagnostics
    results_compute_verdict
  fi
```

In the report header here-doc, replace:

```bash
# OpenShift DNS Validation Report

Generated: $(date -Iseconds)
```

with:

```bash
# OpenShift DNS Validation Report

Profile: ${VALIDATION_PROFILE:-default}
Generated: $(date -Iseconds)
```

- [ ] **Step 2: Rename the current full renderer**

In `dns-validation/lib/results.sh`, rename the existing function:

```bash
render_results_summary() {
```

to:

```bash
render_results_summary_full() {
```

Leave the function body unchanged.

- [ ] **Step 3: Add condensed and CI renderers**

In `dns-validation/lib/results.sh`, after `render_results_summary_full()`, add:

```bash
render_results_summary_condensed() {
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
- Profile: \`${VALIDATION_PROFILE:-default}\`
- DNS operator gate: $(results_dns_operator_gate_summary)
- openshift-tests DNS: rc=$dns_rc, passed=$passed, failed=$failed, skipped=$skipped
- DNS tests: selected=$selected, excluded=$excluded
- dnsperf: $(results_dnsperf_summary)
- perf-tests: $(results_perf_tests_summary)
- Deep diagnostics: $(results_deep_diagnostics_summary)
EOF
  echo
  render_dns_validation_verdict
}

render_results_summary_ci() {
  local report_path="$1"
  local dns_rc verdict

  dns_rc="$(results_read_artifact_rc "$ARTIFACT_DIR/01-openshift-tests/dns-test-output.rc")"
  verdict="$(results_verdict)"

  cat <<EOF
## Results summary

- CI summary: profile=${VALIDATION_PROFILE:-default}; verdict=$verdict; openshift-tests-rc=$dns_rc; dnsperf="$(results_dnsperf_summary)"; perf-tests="$(results_perf_tests_summary)"; deep-diagnostics="$(results_deep_diagnostics_summary)"; report="$report_path"
EOF
}

render_results_summary() {
  case "${DNS_VALIDATION_REPORT_MODE:-full}" in
    full) render_results_summary_full "$@" ;;
    condensed) render_results_summary_condensed "$@" ;;
    ci) render_results_summary_ci "$@" ;;
    *) echo "ERROR: unsupported DNS_VALIDATION_REPORT_MODE=${DNS_VALIDATION_REPORT_MODE:-}" >&2; return 2 ;;
  esac
}
```

- [ ] **Step 4: Update report tests for the profile header**

In `tests/report-results-summary.sh`, in the config file block:

```bash
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
EOF
```

change it to:

```bash
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
VALIDATION_PROFILE="day1"
EOF
```

After `REPORT="$ARTIFACT_DIR/05-report/dns-validation-report.md"`, add:

```bash
grep -Fq "Profile: day1" "$REPORT"
```

- [ ] **Step 5: Add condensed report assertion**

In `tests/report-results-summary.sh`, after the existing full report assertions, add:

```bash
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
VALIDATION_PROFILE="day2"
DNS_VALIDATION_REPORT_MODE="condensed"
EOF

PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" report >"$TMP_DIR/report-condensed.out"

grep -Fq "Profile: day2" "$REPORT"
grep -Fq -- "- Profile: \`day2\`" "$REPORT"
grep -Fq "## DNS validation verdict" "$REPORT"
if grep -Fq "## dnsperf detailed stats" "$REPORT"; then
  echo "condensed report should not render dnsperf detailed stats" >&2
  exit 1
fi
```

- [ ] **Step 6: Add CI report assertion**

In `tests/report-results-summary.sh`, after the condensed assertion block, add:

```bash
cat >"$CONFIG_FILE" <<EOF
ARTIFACT_DIR="$ARTIFACT_DIR"
VALIDATION_NAMESPACE="dns-validation"
VALIDATION_PROFILE="ci"
DNS_VALIDATION_REPORT_MODE="ci"
EOF

PATH="$FAKE_BIN:$PATH" bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$CONFIG_FILE" report >"$TMP_DIR/report-ci.out"

grep -Fq "Profile: ci" "$REPORT"
grep -Fq -- "- CI summary: profile=ci;" "$REPORT"
if grep -Fq "## DNS conformance details" "$REPORT"; then
  echo "ci report should not render detailed DNS conformance sections" >&2
  exit 1
fi
```

- [ ] **Step 7: Run report tests**

Run:

```bash
bash tests/report-results-summary.sh
```

Expected: PASS.

- [ ] **Step 8: Run full static checks**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add dns-validation/lib/perf.sh dns-validation/lib/results.sh tests/report-results-summary.sh
git commit -m "feat: render profile-aware DNS reports"
```

---

### Task 4: Document Profile Usage

**Files:**
- Modify: `dns-validation/README.md`

- [ ] **Step 1: Add a profiles section after quick start**

In `dns-validation/README.md`, after the `## Quick start` section, add:

````markdown
## Profiles

Profiles select validation defaults for common scenarios. Choose a profile with `--profile`, `DNS_VALIDATION_PROFILE`, or `VALIDATION_PROFILE` in `config/validation.env`.

Profile selection precedence:

1. `--profile <name>`
2. `DNS_VALIDATION_PROFILE`
3. `VALIDATION_PROFILE` in `validation.env`
4. `default`

Concrete settings load as profile defaults first, then `validation.env` last. This means `validation.env` can override any profile-controlled setting.

| Profile | Purpose | Key defaults |
|---------|---------|--------------|
| `default` | Current baseline behavior | Existing DNS exclusions, standard dnsperf ladder, full report |
| `day1` | Conservative post-install validation | Serial DNS tests, no DNS test exclusions, 120s dnsperf, zero-loss threshold |
| `day2` | Operational health for existing clusters | No serial DNS tests, shorter dnsperf, `100 500` QPS ladder, condensed report |
| `ci` | CI pipelines | `AUTO_YES=true`, no serial tests, no DNS test exclusions, strict thresholds, CI report mode |
| `customer-evidence` | Customer-facing evidence collection | Serial DNS tests, extended QPS ladder, more clients and threads, deep diagnostics always |

Examples:

```bash
bash bin/ocp-dns-validate --profile day1 --config config/validation.env all
DNS_VALIDATION_PROFILE=ci bash bin/ocp-dns-validate --config config/validation.env all
echo 'VALIDATION_PROFILE="day2"' >> config/validation.env
```
````

- [ ] **Step 2: Run static checks**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add dns-validation/README.md
git commit -m "docs: document DNS validation profiles"
```

---

### Task 5: Final Verification

**Files:**
- Review all changed files

- [ ] **Step 1: Run full verification**

Run:

```bash
bash scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 2: Verify each profile file parses**

Run:

```bash
for profile_file in dns-validation/config/profiles/*.env; do
  bash -n "$profile_file"
done
```

Expected: no output and exit code 0.

- [ ] **Step 3: Verify help includes profile usage**

Run:

```bash
bash dns-validation/bin/ocp-dns-validate --help | grep -F -- '--profile NAME'
```

Expected: the command prints the usage line containing `--profile NAME`.

- [ ] **Step 4: Verify changed-file scope**

Run:

```bash
git --no-pager diff --stat HEAD
```

Expected changed files:

```text
dns-validation/bin/ocp-dns-validate
dns-validation/config/profiles/default.env
dns-validation/config/profiles/day1.env
dns-validation/config/profiles/day2.env
dns-validation/config/profiles/ci.env
dns-validation/config/profiles/customer-evidence.env
dns-validation/config/validation.env.example
dns-validation/lib/cluster.sh
dns-validation/lib/perf.sh
dns-validation/lib/results.sh
dns-validation/README.md
scripts/check-static.sh
tests/profile-loading.sh
tests/report-results-summary.sh
```

- [ ] **Step 5: Commit any verification fixes**

If Steps 1-4 require fixes:

```bash
git add dns-validation/bin/ocp-dns-validate \
  dns-validation/config/profiles \
  dns-validation/config/validation.env.example \
  dns-validation/lib/cluster.sh \
  dns-validation/lib/perf.sh \
  dns-validation/lib/results.sh \
  dns-validation/README.md \
  scripts/check-static.sh \
  tests/profile-loading.sh \
  tests/report-results-summary.sh
git commit -m "test: verify DNS validation profiles"
```

If Steps 1-4 require no fixes, do not create an empty commit.

---

## Spec Coverage Check

| Spec Requirement | Implementing Task |
|------------------|-------------------|
| Named profiles `day1`, `day2`, `ci`, `customer-evidence` | Task 1 |
| Profiles configure validation steps and thoroughness | Task 1 profile files |
| Profiles configure thresholds and strictness | Task 1 profile files |
| Profiles configure report format and verbosity | Task 1 settings, Task 3 renderer |
| Explicit profile selection through `--profile` | Task 2 |
| `DNS_VALIDATION_PROFILE` profile selection | Task 2 |
| `VALIDATION_PROFILE` in `validation.env` profile selection | Task 2 |
| User `validation.env` overrides concrete profile settings | Task 2 |
| `default.env` sourced before named profile files | Task 2 |
| Named profile files contain only overrides | Task 1 |
| Unknown profile fails fast | Task 2 |
| Missing profile file fails fast | Task 2 |
| Invalid profile syntax fails fast and static checks cover profile files | Task 1, Task 2 |
| Report header includes profile name | Task 3 |
| Deep diagnostics can be `on-risk` or `always` | Task 1, Task 3 |
| Full, condensed, and CI report modes | Task 1, Task 3 |
| Documentation covers profiles and precedence | Task 4 |

## Deferred Work Scan

- No marker comments or deferred-work phrases are used.
- Report modes are implemented in Task 3 rather than deferred.
- Each implementation step names exact files, commands, and expected outcomes.
- Each code-changing step includes the concrete code to add or replace.

## Type and Name Consistency

- `RESOLVED_PROFILE` is internal CLI state.
- `VALIDATION_PROFILE` is exported after profile loading and used for report rendering.
- `DNS_VALIDATION_REPORT_MODE` allowed values are `full`, `condensed`, and `ci`.
- `DNS_VALIDATION_DEEP_DIAGNOSTICS` allowed values are `on-risk` and `always`.
- Profile names are consistent: `default`, `day1`, `day2`, `ci`, `customer-evidence`.
