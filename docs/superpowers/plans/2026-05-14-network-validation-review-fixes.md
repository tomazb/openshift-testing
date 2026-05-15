# Network Validation Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve review findings by ignoring local network-validation config and renumbering network-validation artifact directories consistently.

**Architecture:** This is a narrow shell/docs cleanup. The validator continues to use fixed artifact subdirectories under `ARTIFACT_DIR`; only the OVN diagnostics and report directory constants move from `05-ovn-diagnostics` and `06-report` to `06-ovn-diagnostics` and `07-report`. The local config copy becomes ignored while `validation.env.example` remains the tracked template.

**Tech Stack:** Bash, shell smoke tests with fake `oc`, markdown documentation, git ignore rules.

---

## File Structure

- Modify `.gitignore`: add `network-validation/config/validation.env` next to the DNS local config ignore rule.
- Modify `network-validation/lib/common.sh`: create `06-ovn-diagnostics` and `07-report` in `init_dirs`.
- Modify `network-validation/lib/cluster.sh`: write OVN diagnostics into `06-ovn-diagnostics`.
- Modify `network-validation/lib/results.sh`: write verdict files and the markdown report into `07-report`.
- Modify `network-validation/README.md`: update the artifact tree to `05-node-metrics`, `06-ovn-diagnostics`, `07-report`.
- Modify `network-validation/CHANGELOG.md`: add a note that local `validation.env` is ignored and artifact numbering is unique.
- Modify `tests/network-validation-smoke.sh`: update asserted OVN diagnostics and report paths to the new directory names.
- Leave `network-validation/config/validation.env` untracked and unstaged.

### Task 1: Ignore Local Network Config

**Files:**
- Modify: `.gitignore`
- Verify: `git status --short`

- [ ] **Step 1: Add the ignore rule**

In `.gitignore`, change the local configuration section to:

```gitignore
# Local configuration copies; keep secrets and environment-specific paths out of Git.
dns-validation/config/validation.env
network-validation/config/validation.env
```

- [ ] **Step 2: Verify the local config no longer appears as untracked**

Run:

```bash
git status --short
```

Expected: `network-validation/config/validation.env` is absent from the status output. Existing modified docs may still appear.

- [ ] **Step 3: Commit the ignore-rule change when this task is complete**

Run:

```bash
git add .gitignore
git commit -m "chore: ignore network validation local config"
```

Expected: commit succeeds and only `.gitignore` is included.

### Task 2: Renumber Runtime Artifact Paths

**Files:**
- Modify: `network-validation/lib/common.sh`
- Modify: `network-validation/lib/cluster.sh`
- Modify: `network-validation/lib/results.sh`
- Test: `tests/network-validation-smoke.sh`

- [ ] **Step 1: Update directory creation**

In `network-validation/lib/common.sh`, make `init_dirs` create the final network-validation layout:

```bash
init_dirs() {
  mkdir -p \
    "$ARTIFACT_DIR/00-preflight" \
    "$ARTIFACT_DIR/01-cross-node" \
    "$ARTIFACT_DIR/02-same-node" \
    "$ARTIFACT_DIR/03-host-network" \
    "$ARTIFACT_DIR/04-pod-to-service" \
    "$ARTIFACT_DIR/05-node-metrics" \
    "$ARTIFACT_DIR/06-ovn-diagnostics" \
    "$ARTIFACT_DIR/07-report" \
    "$ARTIFACT_DIR/tmp"
}
```

- [ ] **Step 2: Update OVN diagnostics output path**

In `network-validation/lib/cluster.sh`, change the OVN diagnostics directory assignment to:

```bash
local d="$ARTIFACT_DIR/06-ovn-diagnostics"
```

- [ ] **Step 3: Update report and verdict paths**

In `network-validation/lib/results.sh`, replace every `"$ARTIFACT_DIR/06-report` reference with `"$ARTIFACT_DIR/07-report`.

The affected patterns should become:

```bash
"$ARTIFACT_DIR/07-report/verdict-blocking-reasons.txt"
"$ARTIFACT_DIR/07-report/verdict-risk-reasons.txt"
"$ARTIFACT_DIR/07-report/verdict.txt"
"$ARTIFACT_DIR/07-report/network-validation-report.md"
```

- [ ] **Step 4: Update smoke test assertions**

In `tests/network-validation-smoke.sh`, replace old path assertions:

```bash
"$ARTIFACT_DIR/05-ovn-diagnostics/"
"$ARTIFACT_DIR/06-report/"
"$SVC_ARTIFACT_DIR/06-report/"
"$FAIL_ARTIFACT_DIR/06-report/"
```

with:

```bash
"$ARTIFACT_DIR/06-ovn-diagnostics/"
"$ARTIFACT_DIR/07-report/"
"$SVC_ARTIFACT_DIR/07-report/"
"$FAIL_ARTIFACT_DIR/07-report/"
```

- [ ] **Step 5: Verify no stale runtime references remain**

Run:

```bash
rg -n '05-ovn-diagnostics|06-report' network-validation tests
```

Expected: no matches. If this returns references in historical docs under `docs/`, leave them alone unless they describe current behavior.

- [ ] **Step 6: Commit runtime path changes**

Run:

```bash
git add network-validation/lib/common.sh network-validation/lib/cluster.sh network-validation/lib/results.sh tests/network-validation-smoke.sh
git commit -m "fix: renumber network validation artifact paths"
```

Expected: commit succeeds and includes only runtime/test path changes.

### Task 3: Update Documentation

**Files:**
- Modify: `network-validation/README.md`
- Modify: `network-validation/CHANGELOG.md`
- Optionally inspect: `README.md`

- [ ] **Step 1: Update artifact tree in README**

In `network-validation/README.md`, make the artifact tree read:

```text
runs/<timestamp>/
  00-preflight/       — cluster and network baseline
  01-cross-node/      — cross-node test results and metrics
    client/           — client collector artifacts and iperf3 JSON
    server/           — server collector artifacts and iperf3 JSON
  02-same-node/       — same-node test results
  03-host-network/    — host-network test results
  04-pod-to-service/  — ClusterIP service path test results
  05-node-metrics/    — dedicated deep metrics test results
  06-ovn-diagnostics/ — OVN logs, DB state, tunnel stats
  07-report/          — markdown report and verdict
```

- [ ] **Step 2: Add changelog note**

In `network-validation/CHANGELOG.md`, under `## Unreleased`, add bullets that describe the review cleanup:

```markdown
### Changed

- Network-validation artifact directories now use unique ordered prefixes: `05-node-metrics`, `06-ovn-diagnostics`, and `07-report`.
- Local `network-validation/config/validation.env` copies are ignored; `validation.env.example` remains the tracked template.
```

If an `### Changed` section already exists under `Unreleased`, append these bullets there instead of creating a duplicate section.

- [ ] **Step 3: Verify docs do not mention old current paths**

Run:

```bash
rg -n '05-ovn-diagnostics|06-report' README.md network-validation/README.md network-validation/CHANGELOG.md
```

Expected: no matches.

- [ ] **Step 4: Commit documentation changes**

Run:

```bash
git add network-validation/README.md network-validation/CHANGELOG.md
git commit -m "docs: document network validation artifact layout"
```

Expected: commit succeeds and includes only documentation changes. Do not stage `network-validation/config/validation.env`.

### Task 4: Validate End-to-End

**Files:**
- Read: `scripts/check-static.sh`
- Test: repository shell checks and smoke tests

- [ ] **Step 1: Run the full static/smoke check**

Run:

```bash
scripts/check-static.sh
```

Expected: command exits 0.

- [ ] **Step 2: If full static check is unavailable, run targeted smoke tests**

If `scripts/check-static.sh` is missing or blocked by missing local tooling, run:

```bash
bash tests/network-validation-smoke.sh
bash tests/config-validation.sh
bash tests/all-actions-smoke.sh
```

Expected: each command exits 0.

- [ ] **Step 3: Confirm final status**

Run:

```bash
git status --short
```

Expected: no uncommitted implementation changes except intentional pre-existing user edits that are not part of this fix. `network-validation/config/validation.env` should not appear.

- [ ] **Step 4: Summarize validation evidence**

Record the exact commands run and their pass/fail outcome in the final response. If any command could not be run, include the reason and the targeted fallback command that did run.
