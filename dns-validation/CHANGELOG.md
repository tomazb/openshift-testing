# Changelog

All notable changes to the OpenShift DNS validation automation are documented here.

This project has not been tagged yet, so entries are grouped by commit date.

## Unreleased

### Added

- Added non-interactive `run-single-test <test name>` support while keeping the existing interactive prompt fallback.
- Added startup validation for DNS validation configuration values, including positive integer fields, QPS lists, optional numeric dnsperf thresholds, boolean flags, and supported perf-tests modes.
- Added regression coverage for config validation, non-interactive single-test execution, and missing dnsperf log handling during threshold checks.

### Changed

- Centralized command output and return-code capture through shared helpers.
- Replaced repeated DNS operator gate parsing with one shared parser.
- Defined shared verdict constants for `Accepted`, `Accepted with risks`, and `Blocked`.

### Fixed

- Missing dnsperf log artifacts now block threshold-based verdicts instead of silently producing inconclusive threshold checks.

## 2026-04-29

### Added

- Added structured DNS validation verdict generation with `Accepted`, `Accepted with risks`, and `Blocked` outcomes.
- Added final results summaries and detailed report sections for DNS conformance, dnsperf, node sweep coverage, and verdict reasons.
- Added lightweight DNS diagnostics during normal validation, including DNS workloads, events, CoreDNS placement, endpoint slices, upstream resolvers, and DNS operator state.
- Added deep DNS diagnostics when report generation sees a risky or blocked preliminary verdict.
- Added optional dnsperf verdict thresholds for query loss and average latency.

### Changed

- Split DNS result rendering into focused helpers.
- Documented DNS validation verdict behavior and diagnostics in the README.
- Documented the menu option for showing artifact paths.
- Pinned default DNS validation dependencies and helper images, including `PERF_TESTS_REF`, `DNSPERF_IMAGE`, and the dnsperf container base image.
- Clarified ShellCheck source directives and the `run_out` artifact-capture contract.

### Fixed

- Hardened verdict parsing for missing, malformed, failed, and IPv6 DNS artifacts.
- Flagged missing optional perf-tests results as a risk.
- Rendered DNS upstream resolver summaries safely when capture commands fail.
- Fixed release-matched `openshift-tests` extraction target handling.
- Improved rerun safety and static-check compatibility.
- Excluded known prod3 DNS tests through the default discovery configuration.
- Fixed prod3 validation runtime issues.

## 2026-04-28

### Added

- Added the initial DNS validation automation guide and linked it from the repository README.
- Added the DNS validation configuration template.
- Added shared Bash helpers for logging, command execution, runtime state, namespace handling, and artifact directory setup.
- Added cluster validation steps for preflight capture, `openshift-tests` extraction, DNS conformance discovery, conformance execution, single-test execution, and node-level DNS sweep.
- Added dnsperf query generation, direct dnsperf execution, optional `kubernetes/perf-tests/dns` execution, markdown report generation, cleanup, and all-in-one orchestration.
- Added the text menu frontend for guided DNS validation runs.
- Added a dnsperf query seed example and dnsperf helper containerfile placeholder.

### Changed

- Updated documentation to use explicit `bash` invocation for the validation frontend.
- Exported shared environment variables for sourced library scripts.
- Replaced ambiguous shell `&&`/`||` control flow with explicit `if`/`else` blocks.
- Used the detected cluster domain in node sweep lookups.
- Passed dnsperf extra arguments as an array and removed an invalid dnsperf flag.
- Used the perf-tests virtual environment interpreter and logged setup output.

### Fixed

- Propagated command exit codes through the shared `run` helper.
- Captured `openshift-tests` dry-run stderr and failed fast when DNS test discovery produced no matches.
- Required `oc` and loaded runtime state during cleanup.
