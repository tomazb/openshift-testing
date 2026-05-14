# Live Cluster PR Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate PR #10 by running the `cluster-validator` DNS and network Kubernetes Jobs on live cluster context `ocp1htz1`.

**Architecture:** This plan performs a controlled live validation run using the PR manifests as the source of truth. It validates locally first, applies only the required namespace and RBAC objects, runs each Job separately, captures evidence, and removes the test resources afterward.

**Tech Stack:** Bash, Git, `oc`, OpenShift Jobs, repository smoke tests.

---

### Task 1: Local and Context Preflight

**Files:**
- Read: `docs/superpowers/specs/2026-05-14-live-cluster-pr-test-design.md`
- Read: `cluster-validator/README.md`
- Read: `cluster-validator/manifests/*.yaml`
- No code changes.

- [ ] **Step 1: Confirm the Git branch and local state**

Run:

```bash
git status --short --branch
```

Expected: branch is `feature/cluster-validator`. Unrelated uncommitted changes may exist, but no unexpected edits are required for this live test.

- [ ] **Step 2: Confirm the active OpenShift context**

Run:

```bash
oc config current-context
```

Expected:

```text
ocp1htz1
```

- [ ] **Step 3: Confirm OpenShift identity**

Run:

```bash
oc whoami
```

Expected:

```text
system:admin
```

- [ ] **Step 4: Capture the cluster version**

Run:

```bash
oc get clusterversion
```

Expected: the command succeeds and reports the live cluster version.

- [ ] **Step 5: Run local static and smoke validation**

Run:

```bash
./scripts/check-static.sh
```

Expected: the script exits `0`. If it fails, stop before making cluster changes and report the failing check.

### Task 2: Apply Cluster Validator Control Plane Resources

**Files:**
- Use: `cluster-validator/manifests/namespace.yaml`
- Use: `cluster-validator/manifests/serviceaccount.yaml`
- Use: `cluster-validator/manifests/clusterrole.yaml`
- Use: `cluster-validator/manifests/clusterrolebinding.yaml`
- No code changes.

- [ ] **Step 1: Apply namespace and RBAC manifests**

Run:

```bash
oc apply -f cluster-validator/manifests/namespace.yaml
oc apply -f cluster-validator/manifests/serviceaccount.yaml
oc apply -f cluster-validator/manifests/clusterrole.yaml
oc apply -f cluster-validator/manifests/clusterrolebinding.yaml
```

Expected: each command exits `0` and reports `created`, `configured`, or `unchanged`.

- [ ] **Step 2: Verify namespace and ServiceAccount**

Run:

```bash
oc get namespace openshift-testing
oc get serviceaccount cluster-validator -n openshift-testing
```

Expected: both resources exist.

- [ ] **Step 3: Verify cluster-scoped RBAC objects**

Run:

```bash
oc get clusterrole cluster-validator
oc get clusterrolebinding cluster-validator
```

Expected: both resources exist.

### Task 3: Run DNS Validation Job

**Files:**
- Use: `cluster-validator/manifests/job-dns.yaml`
- No code changes.

- [ ] **Step 1: Ensure no stale DNS Job is present**

Run:

```bash
oc delete job dns-validation -n openshift-testing --ignore-not-found=true
```

Expected: command exits `0`.

- [ ] **Step 2: Create the DNS Job**

Run:

```bash
oc create -f cluster-validator/manifests/job-dns.yaml
```

Expected: `job.batch/dns-validation created`.

- [ ] **Step 3: Wait for the DNS Job**

Run:

```bash
oc wait --for=condition=complete job/dns-validation -n openshift-testing --timeout=45m
```

Expected: `job.batch/dns-validation condition met`. If the command times out or fails, continue to evidence collection before cleanup.

- [ ] **Step 4: Capture DNS Job status**

Run:

```bash
oc get job dns-validation -n openshift-testing -o wide
oc get pods -n openshift-testing -l job-name=dns-validation -o wide
```

Expected: the Job and pod are visible. Successful runs show completion.

- [ ] **Step 5: Capture DNS logs**

Run:

```bash
oc logs job/dns-validation -n openshift-testing
```

Expected: logs include:

```text
=== cluster-validator: running dns-validation ===
```

- [ ] **Step 6: Capture DNS failure detail on failure**

Run this only if the Job did not complete:

```bash
oc describe job dns-validation -n openshift-testing
oc describe pod -n openshift-testing -l job-name=dns-validation
oc get events -n openshift-testing --sort-by=.lastTimestamp
```

Expected: output identifies the failure cause, such as image pull, RBAC, pod scheduling, or validator failure.

- [ ] **Step 7: Delete the DNS Job before running the next Job**

Run:

```bash
oc delete job dns-validation -n openshift-testing --ignore-not-found=true
```

Expected: command exits `0`.

### Task 4: Run Network Validation Job

**Files:**
- Use: `cluster-validator/manifests/job-network.yaml`
- No code changes.

- [ ] **Step 1: Ensure no stale network Job is present**

Run:

```bash
oc delete job network-validation -n openshift-testing --ignore-not-found=true
```

Expected: command exits `0`.

- [ ] **Step 2: Create the network Job**

Run:

```bash
oc create -f cluster-validator/manifests/job-network.yaml
```

Expected: `job.batch/network-validation created`.

- [ ] **Step 3: Wait for the network Job**

Run:

```bash
oc wait --for=condition=complete job/network-validation -n openshift-testing --timeout=45m
```

Expected: `job.batch/network-validation condition met`. If the command times out or fails, continue to evidence collection before cleanup.

- [ ] **Step 4: Capture network Job status**

Run:

```bash
oc get job network-validation -n openshift-testing -o wide
oc get pods -n openshift-testing -l job-name=network-validation -o wide
```

Expected: the Job and pod are visible. Successful runs show completion.

- [ ] **Step 5: Capture network logs**

Run:

```bash
oc logs job/network-validation -n openshift-testing
```

Expected: logs include:

```text
=== cluster-validator: running network-validation ===
```

- [ ] **Step 6: Capture network failure detail on failure**

Run this only if the Job did not complete:

```bash
oc describe job network-validation -n openshift-testing
oc describe pod -n openshift-testing -l job-name=network-validation
oc get events -n openshift-testing --sort-by=.lastTimestamp
```

Expected: output identifies the failure cause, such as image pull, RBAC, pod scheduling, or validator failure.

### Task 5: Cleanup and Report

**Files:**
- No code changes.

- [ ] **Step 1: Delete live test Jobs**

Run:

```bash
oc delete job dns-validation -n openshift-testing --ignore-not-found=true
oc delete job network-validation -n openshift-testing --ignore-not-found=true
```

Expected: both commands exit `0`.

- [ ] **Step 2: Delete cluster-scoped RBAC**

Run:

```bash
oc delete clusterrolebinding cluster-validator --ignore-not-found=true
oc delete clusterrole cluster-validator --ignore-not-found=true
```

Expected: both commands exit `0`.

- [ ] **Step 3: Delete the test namespace**

Run:

```bash
oc delete namespace openshift-testing --ignore-not-found=true
```

Expected: command exits `0`.

- [ ] **Step 4: Verify cleanup**

Run:

```bash
oc get namespace openshift-testing
oc get clusterrole cluster-validator
oc get clusterrolebinding cluster-validator
```

Expected: each command reports `NotFound`.

- [ ] **Step 5: Report the outcome**

Include:

- Local static test result.
- Cluster context and version.
- DNS Job result and key log lines.
- Network Job result and key log lines.
- Cleanup result.
- Any failures or residual resources.
