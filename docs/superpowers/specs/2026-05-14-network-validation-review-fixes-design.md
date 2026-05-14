# Network Validation Review Fixes Design

## Goal

Resolve the uncommitted-change review findings for `network-validation` without changing unrelated behavior.

## Decisions

- Treat `network-validation/config/validation.env` as a local operator config file, matching the DNS validation pattern.
- Keep `network-validation/config/validation.env.example` as the tracked template.
- Renumber generated network-validation artifact directories so every numbered prefix is unique and ordered.

## Config Hygiene

Add `network-validation/config/validation.env` to `.gitignore`. The local config copy should remain untracked, while the example file remains the canonical committed reference.

The README copy/edit workflow stays valid:

```bash
cp config/validation.env.example config/validation.env
```

## Artifact Layout

Use this generated directory layout:

```text
00-preflight/
01-cross-node/
02-same-node/
03-host-network/
04-pod-to-service/
05-node-metrics/
06-ovn-diagnostics/
07-report/
```

`node-metrics` remains informational and does not affect verdict computation. OVN diagnostics and report paths move forward by one slot to keep prefix numbering unique.

## Code Changes

Update the network-validation code paths consistently:

- `lib/common.sh`: create `06-ovn-diagnostics` and `07-report`.
- `lib/cluster.sh`: write OVN diagnostics to `06-ovn-diagnostics`.
- `lib/results.sh`: read and write verdict/report artifacts under `07-report`.
- `README.md` files and changelog text: reflect the final paths and local config hygiene.
- Tests: update only assertions or fixtures that reference the old report or OVN paths.

No compatibility shim is needed because these paths are part of the current uncommitted branch work, not a released interface.

## Validation

Run the repository static/smoke validation if available:

```bash
scripts/check-static.sh
```

If that is too broad or unavailable, run targeted tests covering config validation, all-actions smoke behavior, and report generation.

## Out of Scope

- Changing the semantics of `IPERF_PARALLEL=auto`.
- Changing verdict logic.
- Adding backward compatibility for old artifact paths.
- Committing a real `network-validation/config/validation.env`.
