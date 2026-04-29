# DNS Validation MVP Design

Date: 2026-04-29

## Context

The `dns-validation` tool is a Bash-based OpenShift DNS validation pack. It already provides:

- Release-matched `openshift-tests` DNS conformance discovery and execution.
- Node-level DNS smoke checks through a DaemonSet.
- Direct `dnsperf` QPS ladder tests against the OpenShift cluster DNS service IP.
- Optional `kubernetes/perf-tests/dns` execution.
- Markdown report generation under each run artifact directory.

Recent work has improved runtime reliability and report detail. The next improvement should make the tool better at explaining validation outcomes, especially when results are ambiguous.

## Goals

The MVP focuses on two outcomes:

1. Better failure triage.
2. Better final verdict quality.

The tool should capture enough evidence on every run to make a passing result trustworthy, and enough extra evidence on risky or failing runs to make the first triage pass useful without immediately rerunning the validation.

The report should compute a structured verdict:

- `Accepted`
- `Accepted with risks`
- `Blocked`

Each verdict must include explicit reasons and references to supporting artifacts.

## Non-Goals

The MVP does not implement profile-driven validation, CI-native behavior, artifact bundle packaging, trend history, or performance baseline comparison. Those are documented as backlog items in this spec.

The MVP should not rewrite the tool in another language or replace the current Bash CLI structure.

## MVP Diagnostics

The tool should add a diagnostics phase with two levels.

### Lightweight Diagnostics

Lightweight diagnostics are collected on every run. They should include:

- DNS operator state and conditions.
- `openshift-dns` and `openshift-dns-operator` pods, daemonsets, deployments, services, endpoints, and recent events.
- CoreDNS pod placement by node.
- Node count compared with node-sweep pod count.
- DNS service IP, cluster domain, apps domain, network type, release image, and tests image metadata.
- A per-node lookup summary derived from the node sweep:
  - Internal Kubernetes service lookup.
  - Internal OpenShift service lookup.
  - External lookup.
  - Failures by node.

### Deep Diagnostics

Deep diagnostics are collected automatically when the computed verdict is `Blocked` or `Accepted with risks`. They should include:

- Logs from `openshift-dns` pods.
- Logs from DNS operator pods.
- `describe` output for unhealthy DNS pods.
- Relevant events from `openshift-dns`, `openshift-dns-operator`, and the validation namespace.
- Failing node-sweep pod logs or exec output grouped by node.
- Failure excerpts from `openshift-tests` when selected DNS tests fail.

Passing runs remain compact. Risky or failing runs get enough evidence for immediate triage.

## MVP Verdict Model

Verdict computation should use explicit artifact-derived inputs. The result parser should not query live cluster state while computing the verdict.

### Blocked

The verdict is `Blocked` when there is direct DNS validation failure:

- DNS operator gate is unhealthy:
  - `Available != True`
  - `Progressing != False`
  - `Degraded != False`
- Any selected DNS conformance test fails.
- Node sweep misses required internal lookups on any swept node.
- `dnsperf` has configured QPS step failures.
- `dnsperf` exceeds configured loss or latency thresholds. For the MVP, these thresholds should be opt-in configuration values. When unset, dnsperf verdict gating uses the existing per-QPS command return codes.
- Required artifacts for an expected completed step are missing or malformed.

### Accepted With Risks

The verdict is `Accepted with risks` when DNS appears usable but evidence is incomplete or adjacent symptoms exist:

- `openshift-tests` exits nonzero but no selected DNS test failed.
- External lookup fails on one or more nodes while required internal service lookups pass.
- Tests were skipped or excluded.
- Optional perf-tests fails or is not run.
- Deep diagnostics collection fails after a risk or failure trigger.

### Accepted

The verdict is `Accepted` when required MVP checks pass and no risk-only conditions are present:

- DNS operator gate is healthy.
- Selected DNS conformance has no failures.
- Node sweep internal lookups pass on all swept nodes.
- `dnsperf` passes configured steps and thresholds.
- No risk-only conditions are present.

The report should show the verdict near the top and again at the end, with reason bullets and artifact paths.

## Architecture

The MVP should fit into the current layout without a rewrite.

### New Library

Add `dns-validation/lib/results.sh`.

This library owns:

- Parsing existing artifact files into normalized result fields.
- Computing blocking reasons and risk reasons.
- Computing the final verdict.
- Rendering verdict and result sections for reports.

### Existing Libraries

`dns-validation/lib/cluster.sh` continues to collect preflight, `openshift-tests`, and node-sweep artifacts. It should gain lightweight diagnostics collection after preflight and node sweep.

`dns-validation/lib/perf.sh` continues query generation, dnsperf execution, optional perf-tests execution, cleanup, and report generation. Reporting should call `results.sh` instead of continuing to grow result-parsing logic inline.

`dns-validation/lib/common.sh` keeps shared logging, command execution, runtime environment helpers, and artifact directory setup.

## Data Flow

1. CLI actions produce artifacts under the existing run directory.
2. Lightweight diagnostics are collected as part of normal validation flow.
3. Result parsing reads artifacts only.
4. Verdict computation produces:
   - Verdict.
   - Blocking reasons.
   - Risk reasons.
   - Supporting artifact references.
5. If the verdict is `Blocked` or `Accepted with risks`, deep diagnostics are collected.
6. If deep diagnostics collection fails, that failure is appended as an additional risk reason without replacing the original verdict reasons.
7. The report renderer uses the normalized status and diagnostics artifact paths.
8. Future JSON, CI, profile, and evidence-bundle features can reuse the same normalized status.

## Error Handling

Collection failure and validation failure must stay distinct.

- Artifact capture commands keep writing `.rc` files and continue where possible.
- Parsing code treats missing or malformed required artifacts as `Blocked` only when the related step was expected to run.
- Optional missing artifacts should not make report generation fail.
- Deep diagnostics failures should not hide the original validation result.
- Deep diagnostics failures add a risk reason such as `deep diagnostics incomplete`.
- The report command should continue to render even when optional sections are absent.
- Existing CLI actions remain stable. New behavior should be added through helper functions or new actions rather than renaming current commands.

## Testing

Testing stays shell-based for the MVP.

Add focused regression tests for:

- Verdict computation from synthetic artifact directories.
- Existing report summary behavior.
- Missing required artifact handling.
- Missing optional artifact handling.
- Node-sweep partial failure classification.
- `openshift-tests rc != 0` with zero DNS failures producing `Accepted with risks`, not `Blocked`.
- DNS operator unhealthy conditions producing `Blocked`.
- dnsperf QPS step failure producing `Blocked`.

## Post-MVP Backlog

### Profile-Driven Validation

Add named profiles that select checks, thresholds, and report behavior:

- `day1`: conservative post-install validation.
- `day2`: operational health validation for existing clusters.
- `ci`: deterministic noninteractive behavior with stable machine-readable output.
- `customer-evidence`: broader diagnostics and polished evidence output.

Profiles should build on the same verdict engine rather than duplicating validation logic.

### Full Evidence Platform

Add features for broader automation and customer-ready evidence:

- JSON output derived from normalized verdict status.
- Stable CI exit codes.
- Artifact bundle packaging.
- Redaction support for sensitive values.
- Performance baseline comparison.
- Trend and history support across multiple runs.
- More polished customer-facing reports.
- Stronger performance analysis, including sustained runs and saturation detection.

These backlog items should not block the MVP. The MVP architecture should leave clear extension points for them.
