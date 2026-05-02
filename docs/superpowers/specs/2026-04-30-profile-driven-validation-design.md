# Profile-Driven DNS Validation Design

Date: 2026-04-30

## Context

The DNS validation tool already produces structured verdicts (`Accepted`, `Accepted with risks`, `Blocked`) and two levels of diagnostics (lightweight and deep). Different use cases call for different validation behavior, thresholds, and output formats. The current approach requires users to manually edit `validation.env` to tune behavior for each scenario.

## Goals

Allow users to select validation behavior through named **profiles** that configure:

1. Which validation steps to run and how thoroughly.
2. Which thresholds and strictness levels to apply.
3. Report format and verbosity.

Profiles must be explicit, extensible, and composable with user overrides.

## Non-Goals

- Rewriting the tool in another language.
- Replacing the existing `validation.env` mechanism.
- Adding profile-driven behavior to anything outside DNS validation.
- Real-time profile switching during a single run.

## Profiles

### `day1` — Conservative Post-Install Validation

For fresh cluster installs. Runs the full validation suite with conservative thresholds to catch day-1 DNS issues.

- Includes serial DNS tests (`INCLUDE_SERIAL_DNS_TESTS=true`).
- No test exclusions (`DNS_TEST_EXCLUDE_REGEX=""`).
- Longer dnsperf duration for stability (`DNSPERF_DURATION_SECONDS=120`).
- Stricter loss threshold (`DNSPERF_MAX_LOST_PERCENT=0.0`).
- Standard markdown report with full details.
- Deep diagnostics triggered only on risky/blocked verdicts.

### `day2` — Operational Health for Existing Clusters

For clusters already in production. Faster, lighter, and skips disruptive serial tests.

- Excludes serial DNS tests (`INCLUDE_SERIAL_DNS_TESTS=false`).
- Shorter dnsperf duration (`DNSPERF_DURATION_SECONDS=30`).
- Fewer QPS steps (`DNSPERF_QPS_STEPS="100 500"`).
- Stricter latency threshold (`DNSPERF_MAX_AVG_LATENCY_SECONDS=0.003`).
- Standard markdown report, but condensed.
- Always collects lightweight diagnostics (already the default).
- Deep diagnostics triggered only on risky/blocked verdicts.

### `ci` — Deterministic Noninteractive Behavior

For CI pipelines. Stable, predictable output with no interactivity.

- Automatically answers yes to prompts (`AUTO_YES=true`).
- No serial tests (`INCLUDE_SERIAL_DNS_TESTS=false`).
- No test exclusions (`DNS_TEST_EXCLUDE_REGEX=""`).
- Standard QPS steps and duration.
- Strict thresholds (`DNSPERF_MAX_LOST_PERCENT=0.0`, `DNSPERF_MAX_AVG_LATENCY_SECONDS=0.005`).
- Condensed markdown report (no interactive prompts, deterministic output).
- Deep diagnostics triggered only on risky/blocked verdicts.

### `customer-evidence` — Broader Diagnostics and Polished Evidence

For customer-facing evidence collection. Runs comprehensive tests with moderate thresholds.

- Includes serial DNS tests (`INCLUDE_SERIAL_DNS_TESTS=true`).
- Extended QPS ladder (`DNSPERF_QPS_STEPS="100 500 1000 2000 5000"`).
- Longer duration (`DNSPERF_DURATION_SECONDS=120`).
- More clients and threads (`DNSPERF_CLIENTS=10`, `DNSPERF_THREADS=4`).
- Moderate thresholds (`DNSPERF_MAX_LOST_PERCENT=0.5`, `DNSPERF_MAX_AVG_LATENCY_SECONDS=0.010`).
- Standard markdown report with profile name prominently displayed.
- Always collects deep diagnostics for completeness.

## Architecture

### Profile Selection Precedence

1. Explicit CLI flag: `--profile <name>`
2. Environment variable: `DNS_VALIDATION_PROFILE`
3. User config file: `validation.env` (if `VALIDATION_PROFILE` is set there)
4. Default profile: `default`

Profile selection decides which profile file is loaded. It does not make profile values higher priority than user overrides.

### Setting Precedence

After the profile name is resolved, concrete settings load in this order:

1. `config/profiles/default.env`
2. `config/profiles/<resolved-profile>.env` (if the resolved profile is not `default`)
3. User config file: `validation.env`
4. Existing script fallback defaults for unset values

A user's `validation.env` always wins for concrete settings, giving full control even when using profiles. If `--profile` or `DNS_VALIDATION_PROFILE` selects a profile, `VALIDATION_PROFILE` from `validation.env` does not replace that resolved profile name after the user config is sourced; it only participates in profile selection when no higher-precedence selector is present.

### Profile File Structure

```
dns-validation/config/profiles/
├── default.env          # Common baseline for all profiles
├── day1.env             # Conservative post-install
├── day2.env             # Operational health
├── ci.env               # Deterministic, noninteractive
└── customer-evidence.env # Broader diagnostics
```

Each named profile file contains only overrides. The loader owns sourcing `default.env` before the selected named profile:

```bash
# Example: day1.env
DNSPERF_DURATION_SECONDS="120"
INCLUDE_SERIAL_DNS_TESTS="true"
DNS_TEST_EXCLUDE_REGEX=""
```

### Profile-Controlled Settings

Profiles use the same environment settings the tool already accepts wherever possible:

- Existing DNS test settings: `INCLUDE_SERIAL_DNS_TESTS`, `DNS_TEST_EXCLUDE_REGEX`.
- Existing dnsperf settings: `DNSPERF_QPS_STEPS`, `DNSPERF_DURATION_SECONDS`, `DNSPERF_CLIENTS`, `DNSPERF_THREADS`, `DNSPERF_MAX_LOST_PERCENT`, `DNSPERF_MAX_AVG_LATENCY_SECONDS`.
- Existing prompt setting: `AUTO_YES`.
- New report verbosity setting: `DNS_VALIDATION_REPORT_MODE`, one of `full`, `condensed`, or `ci`.
- New deep diagnostics setting: `DNS_VALIDATION_DEEP_DIAGNOSTICS`, one of `on-risk` or `always`.

The `default` profile preserves current behavior:

- `INCLUDE_SERIAL_DNS_TESTS=false`
- Current default `DNS_TEST_EXCLUDE_REGEX` from `validation.env.example`
- `DNSPERF_QPS_STEPS="100 500 1000 2000"`
- `DNSPERF_DURATION_SECONDS=60`
- `DNSPERF_CLIENTS=5`
- `DNSPERF_THREADS=2`
- Empty dnsperf threshold settings
- `DNS_VALIDATION_REPORT_MODE=full`
- `DNS_VALIDATION_DEEP_DIAGNOSTICS=on-risk`

### Report Differences by Profile

| Profile | Report Format | Deep Diagnostics | Verdict Rendering |
|---------|---------------|------------------|-------------------|
| `day1` | Standard markdown | Triggered on risky/blocked | Full details |
| `day2` | Standard markdown | Triggered on risky/blocked | Condensed |
| `ci` | Condensed markdown | Triggered on risky/blocked | Single-line summary |
| `customer-evidence` | Standard markdown with profile header | Always collected | Full details |

All reports include the profile name in the header:

```markdown
# OpenShift DNS Validation Report

Profile: day1
Generated: 2026-04-30T12:00:00+00:00
```

## Data Flow

1. CLI parses `--config`, `--profile`, `--yes`, and the action.
2. Profile name is resolved from CLI, `DNS_VALIDATION_PROFILE`, `VALIDATION_PROFILE` in `validation.env`, or `default`.
3. `config/profiles/default.env` is sourced.
4. Named profile file is sourced (if not `default`).
5. User's `validation.env` is sourced (overriding profile values).
6. `VALIDATION_PROFILE` is set to the resolved profile name for reporting.
7. Existing config validation runs, including allowed values for profile-controlled settings.
8. Validation executes with the resolved settings.
9. Report is generated with profile-appropriate formatting.

## Error Handling

- No requested profile: use `default`.
- Unknown profile name: fail fast with a clear error that lists valid profiles.
- Missing profile file for a known profile: fail fast with a clear error.
- Invalid syntax in profile file: fail fast before sourcing by running `bash -n` on the profile file; static checks also run `bash -n` on every profile file.
- Profile + user config conflicts: user config wins (by design).

## Testing

1. **Static checks:** All profile `.env` files pass `bash -n` syntax validation.
2. **Profile loading tests:**
   - `--profile day1` loads correct values.
   - `DNS_VALIDATION_PROFILE=ci` env var works.
   - `VALIDATION_PROFILE=customer-evidence` in `validation.env` works when no CLI/env profile selector is present.
   - `--profile` wins over `DNS_VALIDATION_PROFILE` and `VALIDATION_PROFILE`.
   - `validation.env` overrides profile values.
   - Unknown explicit profile fails before running an action.
3. **Regression tests:** Existing tests pass with default profile.
4. **Report output tests:** Each profile produces expected report format.

## Extension Points

- New profiles: create a new `.env` file in `config/profiles/`.
- New profile-controlled settings: add to `default.env` and override in specific profiles.
- Future JSON output: `ci` profile can be extended to output JSON instead of markdown.
- Future profile-specific behavior: add new profile-controlled settings first; only gate directly on the profile name when the behavior cannot be expressed as a reusable setting.

## Files

### Create

- `dns-validation/config/profiles/default.env`
- `dns-validation/config/profiles/day1.env`
- `dns-validation/config/profiles/day2.env`
- `dns-validation/config/profiles/ci.env`
- `dns-validation/config/profiles/customer-evidence.env`

### Modify

- `dns-validation/bin/ocp-dns-validate` — add `--profile` flag, profile loading logic, usage update
- `dns-validation/lib/perf.sh` — add profile name to report header and switch deep diagnostics trigger based on `DNS_VALIDATION_DEEP_DIAGNOSTICS`
- `dns-validation/lib/results.sh` — render full, condensed, and CI report modes based on `DNS_VALIDATION_REPORT_MODE`
- `dns-validation/config/validation.env.example` — add `VALIDATION_PROFILE` comment
- `dns-validation/README.md` — document profiles
- `scripts/check-static.sh` — add profile file syntax checks
- `tests/profile-loading.sh` — add profile loading and precedence regression tests
- `tests/report-results-summary.sh` — add report mode and profile header assertions
