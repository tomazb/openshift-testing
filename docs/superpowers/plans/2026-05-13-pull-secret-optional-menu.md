# Pull Secret Optional — Menu Warning & Graceful Skip

Date: 2026-05-13

## Problem

`PULL_SECRET_FILE` is required to extract `openshift-tests` from the release payload.
After making it a hard requirement, running the menu or the `all` sequence without a pull
secret aborts immediately with an error instead of letting the rest of validation proceed.

For field use, teams often want to run node-sweep and dnsperf without pull-secret access;
blocking on the conformance step is unnecessarily disruptive.

## Goal

- Menu header: show a visible `[!]` indicator when `PULL_SECRET_FILE` is not configured.
- Affected actions: warn and skip gracefully instead of hard-failing; control returns to the
  menu naturally.
- `all` sequence (menu and CLI): silently skip pull-secret steps, continue the rest.
- Report verdict: treat skipped conformance tests as `Accepted with risks`, not `Blocked`.

## Affected actions

Steps that require the pull secret (directly or indirectly via the extracted binary):

| Menu # | Action            |
|--------|-------------------|
| 3      | extract-tests     |
| 4      | discover-dns-tests|
| 5      | run-dns-tests     |
| 6      | run-single-test   |

## Design

### Guard helper — `require_pull_secret()`

New function in `dns-validation/lib/cluster.sh`:

```bash
require_pull_secret() {
  [[ -f "$PULL_SECRET_FILE" ]] && return 0
  warn "PULL_SECRET_FILE not found or not readable: $PULL_SECRET_FILE — skipping (conformance tests require a pull secret)"
  mkdir -p "$ARTIFACT_DIR/01-openshift-tests"
  touch "$ARTIFACT_DIR/01-openshift-tests/pull-secret-skipped"
  return 1
}
```

Each of `extract_tests`, `discover_dns_tests`, `run_dns_tests`, `run_single_test` calls
`require_pull_secret || return 0` at the top, replacing the previous hard `fail`.

The sentinel file `01-openshift-tests/pull-secret-skipped` is the single source of truth
used by the report layer.

### Menu header

`menu()` in `ocp-dns-validate` gains a conditional warning line printed before the item list:

```
OpenShift DNS Validation
Artifact directory: /path/to/runs/20260513-123456
Namespace:          dns-validation
[!] PULL_SECRET_FILE not configured — conformance tests (3,4,5,6) will be skipped
```

The line is omitted when `PULL_SECRET_FILE` is present.

When the user picks items 3–6 directly, the function itself warns and returns 0; the menu
loop re-displays immediately — no extra menu-level branching needed.

### Report & verdict

In `results_compute_verdict` (`results.sh`), the DNS conformance block:

```
Before:
  if [[ ! -s "$dns_summary" ]]; then
    results_add_blocking_reason "DNS conformance summary artifact missing" ...

After:
  if [[ -f "$ARTIFACT_DIR/01-openshift-tests/pull-secret-skipped" ]]; then
    results_add_risk_reason "DNS conformance tests skipped (pull secret not available)"
  elif [[ ! -s "$dns_summary" ]]; then
    results_add_blocking_reason "DNS conformance summary artifact missing" ...
```

In the `report()` markdown body, the `openshift-tests DNS summary` fence block reads the
sentinel and outputs `Skipped — pull secret not configured` when appropriate.

## Testing

- **Existing tests** (`all-actions-smoke.sh`, `extract-tests-empty-target.sh`): already use
  a real fake pull secret file — no changes needed for the happy path.
- **`tests/pull-secret-required.sh`**: updated to verify the new behavior: exit 0, sentinel
  file created, warning in output.
- **New test `tests/pull-secret-skip-all.sh`**: runs the `all` sequence without a pull secret,
  verifies that node-sweep and dnsperf artifacts are produced, DNS conformance artifacts are
  absent, and the report verdict is `Accepted with risks` (not `Blocked`).
- **`tests/config-validation.sh`** or a focused test: verifies the menu header line appears
  when `PULL_SECRET_FILE` is missing.

## Out of scope

- Prompting the user to enter a pull secret path interactively.
- Affecting the `preflight`, `node-sweep`, `dnsperf`, or `perf-tests` actions.
- Changing CLI hard-fail behavior for `extract-tests` when called directly (it already
  gracefully warns and returns, same as menu — consistent across all modes).
