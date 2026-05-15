# Cluster Validator RBAC and Pull Secret Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `cluster-validator` runtime RBAC and add an in-cluster fallback to `openshift-config/pull-secret` for DNS conformance extraction.

**Architecture:** Replace the broad runtime `ClusterRole` with a read-only cluster discovery role, namespace-local mutable roles, and tightly scoped diagnostic/pull-secret roles. Runtime namespace helpers stop creating namespaces and instead fail clearly when install-time namespaces are missing. DNS pull-secret resolution first uses `PULL_SECRET_FILE`, then falls back to the OpenShift global pull secret when RBAC permits it, then preserves the current graceful skip behavior.

**Tech Stack:** Bash validators, Kubernetes/OpenShift YAML manifests, shell smoke tests with fake `oc`, `scripts/check-static.sh`.

---

## File Map

- `cluster-validator/manifests/clusterrole.yaml`: convert to read-only cluster discovery role.
- `cluster-validator/manifests/clusterrolebinding.yaml`: keep binding the read-only cluster role to the `cluster-validator` service account.
- `cluster-validator/manifests/namespace-dns-validation.yaml`: new install-time DNS validation namespace.
- `cluster-validator/manifests/namespace-network-validation.yaml`: new install-time network validation namespace.
- `cluster-validator/manifests/role-dns-validation.yaml`: new mutable Role for DNS validation namespace.
- `cluster-validator/manifests/rolebinding-dns-validation.yaml`: bind DNS Role to `cluster-validator` service account.
- `cluster-validator/manifests/role-network-validation.yaml`: new mutable Role for network validation namespace.
- `cluster-validator/manifests/rolebinding-network-validation.yaml`: bind network Role to `cluster-validator` service account.
- `cluster-validator/manifests/role-openshift-config-pull-secret.yaml`: new Role to get only `openshift-config/pull-secret`.
- `cluster-validator/manifests/rolebinding-openshift-config-pull-secret.yaml`: bind pull-secret Role to `cluster-validator` service account.
- `cluster-validator/manifests/role-openshift-dns-read.yaml`, `rolebinding-openshift-dns-read.yaml`: read-only DNS component diagnostics.
- `cluster-validator/manifests/role-openshift-dns-operator-read.yaml`, `rolebinding-openshift-dns-operator-read.yaml`: read-only DNS operator diagnostics.
- `cluster-validator/manifests/role-openshift-console-read.yaml`, `rolebinding-openshift-console-read.yaml`: console route lookup.
- `cluster-validator/manifests/role-openshift-ovn-kubernetes-read.yaml`, `rolebinding-openshift-ovn-kubernetes-read.yaml`: read-only OVN diagnostics.
- `dns-validation/lib/common.sh`: change `ensure_namespace()` to verify-only.
- `network-validation/lib/common.sh`: change `ensure_namespace()` to verify-only.
- `dns-validation/lib/cluster.sh`: add pull-secret fallback resolution.
- `cluster-validator/README.md`: update install commands and RBAC notes.
- `cluster-validator/manifests/configmap-dns-example.yaml`: document optional explicit pull secret and automatic fallback.
- `tests/cluster-validator-rbac.sh`: validate restricted manifest shape.
- `tests/pull-secret-required.sh`: add fallback success and fallback skip coverage.
- `tests/all-actions-smoke.sh`, `tests/network-validation-smoke.sh`: update fake `oc` namespace expectations if needed.

---

### Task 1: Manifest RBAC Split

**Files:**
- Modify: `cluster-validator/manifests/clusterrole.yaml`
- Create: `cluster-validator/manifests/namespace-dns-validation.yaml`
- Create: `cluster-validator/manifests/namespace-network-validation.yaml`
- Create: `cluster-validator/manifests/role-dns-validation.yaml`
- Create: `cluster-validator/manifests/rolebinding-dns-validation.yaml`
- Create: `cluster-validator/manifests/role-network-validation.yaml`
- Create: `cluster-validator/manifests/rolebinding-network-validation.yaml`
- Create: `cluster-validator/manifests/role-openshift-config-pull-secret.yaml`
- Create: `cluster-validator/manifests/rolebinding-openshift-config-pull-secret.yaml`
- Create: `cluster-validator/manifests/role-openshift-dns-read.yaml`
- Create: `cluster-validator/manifests/rolebinding-openshift-dns-read.yaml`
- Create: `cluster-validator/manifests/role-openshift-dns-operator-read.yaml`
- Create: `cluster-validator/manifests/rolebinding-openshift-dns-operator-read.yaml`
- Create: `cluster-validator/manifests/role-openshift-console-read.yaml`
- Create: `cluster-validator/manifests/rolebinding-openshift-console-read.yaml`
- Create: `cluster-validator/manifests/role-openshift-ovn-kubernetes-read.yaml`
- Create: `cluster-validator/manifests/rolebinding-openshift-ovn-kubernetes-read.yaml`
- Test: `tests/cluster-validator-rbac.sh`

- [ ] **Step 1: Write failing RBAC manifest tests**

Replace `tests/cluster-validator-rbac.sh` with assertions that fail against the current broad ClusterRole:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_DIR="$REPO_ROOT/cluster-validator/manifests"
CLUSTERROLE="$MANIFEST_DIR/clusterrole.yaml"

assert_contains() {
  local file="$1" expected="$2"
  if ! grep -Fq "$expected" "$file"; then
    echo "missing in $file: $expected" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    echo "unexpected in $file: $unexpected" >&2
    exit 1
  fi
}

for file in \
  "$MANIFEST_DIR/namespace-dns-validation.yaml" \
  "$MANIFEST_DIR/namespace-network-validation.yaml" \
  "$MANIFEST_DIR/role-dns-validation.yaml" \
  "$MANIFEST_DIR/rolebinding-dns-validation.yaml" \
  "$MANIFEST_DIR/role-network-validation.yaml" \
  "$MANIFEST_DIR/rolebinding-network-validation.yaml" \
  "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-config-pull-secret.yaml" \
  "$MANIFEST_DIR/role-openshift-dns-read.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-dns-read.yaml" \
  "$MANIFEST_DIR/role-openshift-dns-operator-read.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-dns-operator-read.yaml" \
  "$MANIFEST_DIR/role-openshift-console-read.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-console-read.yaml" \
  "$MANIFEST_DIR/role-openshift-ovn-kubernetes-read.yaml" \
  "$MANIFEST_DIR/rolebinding-openshift-ovn-kubernetes-read.yaml"; do
  [[ -f "$file" ]] || { echo "missing manifest: $file" >&2; exit 1; }
done

assert_contains "$CLUSTERROLE" "resources: [nodes]"
assert_contains "$CLUSTERROLE" "resources: [namespaces]"
assert_contains "$CLUSTERROLE" "verbs: [get, list]"
assert_contains "$CLUSTERROLE" "resources: [clusterversions, clusteroperators, networks, ingresses]"
assert_contains "$CLUSTERROLE" "resources: [dnses, networks]"
assert_not_contains "$CLUSTERROLE" "verbs: [get, list, create, delete"
assert_not_contains "$CLUSTERROLE" "resources: [pods, pods/log, pods/exec]"
assert_not_contains "$CLUSTERROLE" "resources: [services, configmaps, endpoints]"
assert_not_contains "$CLUSTERROLE" "resources: [daemonsets, deployments, replicasets]"

assert_contains "$MANIFEST_DIR/namespace-dns-validation.yaml" "name: dns-validation"
assert_contains "$MANIFEST_DIR/namespace-network-validation.yaml" "name: network-validation"

assert_contains "$MANIFEST_DIR/role-dns-validation.yaml" "namespace: dns-validation"
assert_contains "$MANIFEST_DIR/role-dns-validation.yaml" "resources: [pods, pods/log, pods/exec]"
assert_contains "$MANIFEST_DIR/role-dns-validation.yaml" "resources: [services, configmaps, endpoints]"
assert_contains "$MANIFEST_DIR/role-dns-validation.yaml" "resources: [daemonsets, deployments, replicasets]"

assert_contains "$MANIFEST_DIR/role-network-validation.yaml" "namespace: network-validation"
assert_contains "$MANIFEST_DIR/role-network-validation.yaml" "resources: [pods, pods/log, pods/exec]"
assert_contains "$MANIFEST_DIR/role-network-validation.yaml" "resources: [services, configmaps, endpoints]"
assert_contains "$MANIFEST_DIR/role-network-validation.yaml" "resources: [daemonsets, deployments, replicasets]"

assert_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "namespace: openshift-config"
assert_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "resources: [secrets]"
assert_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "resourceNames: [pull-secret]"
assert_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "verbs: [get]"
assert_not_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "list"
assert_not_contains "$MANIFEST_DIR/role-openshift-config-pull-secret.yaml" "watch"

for binding in "$MANIFEST_DIR"/rolebinding-*.yaml; do
  assert_contains "$binding" "kind: RoleBinding"
  assert_contains "$binding" "name: cluster-validator"
  assert_contains "$binding" "namespace: cluster-validator"
done

echo "All cluster-validator RBAC tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/cluster-validator-rbac.sh`

Expected: FAIL with `missing manifest: .../namespace-dns-validation.yaml`.

- [ ] **Step 3: Implement manifest split**

Modify `cluster-validator/manifests/clusterrole.yaml` to read-only cluster discovery:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-validator
rules:
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [get, list]
  - apiGroups: [config.openshift.io]
    resources: [clusterversions, clusteroperators, networks, ingresses]
    verbs: [get, list]
  - apiGroups: [operator.openshift.io]
    resources: [dnses, networks]
    verbs: [get, list]
```

Create validation namespaces:

```yaml
# cluster-validator/manifests/namespace-dns-validation.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dns-validation
```

```yaml
# cluster-validator/manifests/namespace-network-validation.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: network-validation
```

Create `cluster-validator/manifests/role-dns-validation.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cluster-validator
  namespace: dns-validation
rules:
  - apiGroups: [""]
    resources: [pods, pods/log, pods/exec]
    verbs: [get, list, create, delete, watch, patch, update]
  - apiGroups: [""]
    resources: [services, configmaps, endpoints]
    verbs: [get, list, create, delete, watch, patch, update]
  - apiGroups: [""]
    resources: [events]
    verbs: [get, list]
  - apiGroups: [apps]
    resources: [daemonsets, deployments, replicasets]
    verbs: [get, list, create, delete, watch, patch, update]
```

Create `cluster-validator/manifests/rolebinding-dns-validation.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cluster-validator
  namespace: dns-validation
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cluster-validator
subjects:
  - kind: ServiceAccount
    name: cluster-validator
    namespace: cluster-validator
```

Create `role-network-validation.yaml` and `rolebinding-network-validation.yaml` with the same rule and subject shape, using `namespace: network-validation`.

Create `role-openshift-config-pull-secret.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cluster-validator-pull-secret
  namespace: openshift-config
rules:
  - apiGroups: [""]
    resources: [secrets]
    resourceNames: [pull-secret]
    verbs: [get]
```

Create `rolebinding-openshift-config-pull-secret.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cluster-validator-pull-secret
  namespace: openshift-config
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cluster-validator-pull-secret
subjects:
  - kind: ServiceAccount
    name: cluster-validator
    namespace: cluster-validator
```

Create read-only diagnostic roles with `verbs: [get, list]`, plus `pods/log` `get` where logs are collected:

```yaml
# cluster-validator/manifests/role-openshift-dns-read.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cluster-validator-read
  namespace: openshift-dns
rules:
  - apiGroups: [""]
    resources: [pods, pods/log, services, endpoints, events]
    verbs: [get, list]
  - apiGroups: [apps]
    resources: [daemonsets, deployments, replicasets]
    verbs: [get, list]
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list]
```

```yaml
# cluster-validator/manifests/rolebinding-openshift-dns-read.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cluster-validator-read
  namespace: openshift-dns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cluster-validator-read
subjects:
  - kind: ServiceAccount
    name: cluster-validator
    namespace: cluster-validator
```

Repeat the same binding pattern for:

```yaml
# cluster-validator/manifests/role-openshift-dns-operator-read.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cluster-validator-read
  namespace: openshift-dns-operator
rules:
  - apiGroups: [""]
    resources: [pods, pods/log, services, events]
    verbs: [get, list]
  - apiGroups: [apps]
    resources: [deployments, replicasets]
    verbs: [get, list]
```

```yaml
# cluster-validator/manifests/role-openshift-console-read.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cluster-validator-read
  namespace: openshift-console
rules:
  - apiGroups: [route.openshift.io]
    resources: [routes]
    resourceNames: [console]
    verbs: [get]
```

```yaml
# cluster-validator/manifests/role-openshift-ovn-kubernetes-read.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cluster-validator-read
  namespace: openshift-ovn-kubernetes
rules:
  - apiGroups: [""]
    resources: [pods, pods/log, events]
    verbs: [get, list]
  - apiGroups: [apps]
    resources: [daemonsets, deployments, replicasets]
    verbs: [get, list]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/cluster-validator-rbac.sh`

Expected: PASS with `All cluster-validator RBAC tests passed.`

- [ ] **Step 5: Commit**

```bash
git add cluster-validator/manifests tests/cluster-validator-rbac.sh
git commit -m "fix(cluster-validator): split runtime RBAC"
```

---

### Task 2: Verify-Only Namespace Helpers

**Files:**
- Modify: `dns-validation/lib/common.sh`
- Modify: `network-validation/lib/common.sh`
- Test: `tests/all-actions-smoke.sh`
- Test: `tests/network-validation-smoke.sh`

- [ ] **Step 1: Write failing namespace behavior checks**

In `tests/all-actions-smoke.sh`, update the fake `oc` branch that currently accepts `create namespace` so it fails if runtime code tries to create namespaces:

```bash
if [[ "$args" == "create namespace "* ]] || [[ "$args" == "delete namespace "* ]]; then
  echo "runtime must not create or delete namespaces: $args" >&2
  exit 99
fi
```

Keep the existing fake `oc get ns dns-validation` path returning success.

In `tests/network-validation-smoke.sh`, apply the same rule for `create namespace` and `delete namespace`, while preserving fake `oc get ns network-validation` success.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bash tests/all-actions-smoke.sh
bash tests/network-validation-smoke.sh
```

Expected: at least one test FAILS with `runtime must not create or delete namespaces`.

- [ ] **Step 3: Change namespace helpers**

In `dns-validation/lib/common.sh`, replace `ensure_namespace()` with:

```bash
ensure_namespace() {
  if ! oc get ns "$VALIDATION_NAMESPACE" >/dev/null 2>&1; then
    fail "Validation namespace '$VALIDATION_NAMESPACE' is missing. Apply the cluster-validator install manifests before running this action."
  fi
}
```

In `network-validation/lib/common.sh`, replace `ensure_namespace()` with:

```bash
ensure_namespace() {
  if ! oc get ns "$IPERF_NAMESPACE" >/dev/null 2>&1; then
    fail "Validation namespace '$IPERF_NAMESPACE' is missing. Apply the cluster-validator install manifests before running this action."
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:

```bash
bash tests/all-actions-smoke.sh
bash tests/network-validation-smoke.sh
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add dns-validation/lib/common.sh network-validation/lib/common.sh tests/all-actions-smoke.sh tests/network-validation-smoke.sh
git commit -m "fix(validators): require precreated validation namespaces"
```

---

### Task 3: Pull Secret Fallback

**Files:**
- Modify: `dns-validation/lib/cluster.sh`
- Test: `tests/pull-secret-required.sh`

- [ ] **Step 1: Write failing pull-secret fallback tests**

Extend `tests/pull-secret-required.sh` with two new cases after the current missing-secret skip case:

```bash
# --- Fallback to openshift-config/pull-secret when local file is missing ---
FALLBACK_TMP="$TMP_DIR/fallback"
FALLBACK_CONFIG="$FALLBACK_TMP/config.env"
mkdir -p "$FALLBACK_TMP/bin"

cat >"$FALLBACK_TMP/bin/oc" <<'FAKEOC'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
printf '%s\n' "$args" >>"${FAKE_OC_LOG:-/dev/null}"
if [[ "$args" == "get secret pull-secret -n openshift-config -o jsonpath={.data.\\.dockerconfigjson}" ]]; then
  printf '%s' 'eyJhdXRocyI6e319fQ=='
  exit 0
fi
if [[ "$args" == "get clusterversion version -o jsonpath={.status.desired.image}" ]]; then
  echo "quay.io/openshift-release-dev/ocp-release:test"
  exit 0
fi
if [[ "$args" == "adm release info --image-for=tests -a "* ]]; then
  auth_file=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-a" ]]; then
      auth_file="$2"
      break
    fi
    shift
  done
  [[ -s "$auth_file" ]] || { echo "fallback auth file missing" >&2; exit 4; }
  echo "quay.io/openshift-release-dev/ocp-tests:test"
  exit 0
fi
if [[ "$args" == image\ extract* ]]; then
  cat >"$PWD/openshift-tests" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then echo "openshift-tests fake"; exit 0; fi
echo "unexpected openshift-tests call: $*" >&2
exit 2
SCRIPT
  chmod +x "$PWD/openshift-tests"
  exit 0
fi
echo "unexpected oc call: $args" >&2
exit 2
FAKEOC
chmod +x "$FALLBACK_TMP/bin/oc"

cat >"$FALLBACK_CONFIG" <<EOF
ARTIFACT_DIR="$FALLBACK_TMP/artifacts"
PULL_SECRET_FILE="$FALLBACK_TMP/missing-pull-secret.json"
EOF

FAKE_OC_LOG="$FALLBACK_TMP/oc.log" PATH="$FALLBACK_TMP/bin:$PATH" \
  bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$FALLBACK_CONFIG" extract-tests

test -x "$FALLBACK_TMP/artifacts/01-openshift-tests/openshift-tests"
test -s "$FALLBACK_TMP/artifacts/tmp/openshift-config-pull-secret.json"
grep -Fq "get secret pull-secret -n openshift-config" "$FALLBACK_TMP/oc.log"

# --- Fallback failure still skips gracefully ---
NO_FALLBACK_TMP="$TMP_DIR/no-fallback"
NO_FALLBACK_CONFIG="$NO_FALLBACK_TMP/config.env"
mkdir -p "$NO_FALLBACK_TMP/bin"

cat >"$NO_FALLBACK_TMP/bin/oc" <<'FAKEOC'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
printf '%s\n' "$args" >>"${FAKE_OC_LOG:-/dev/null}"
if [[ "$args" == "get secret pull-secret -n openshift-config -o jsonpath={.data.\\.dockerconfigjson}" ]]; then
  echo "forbidden" >&2
  exit 1
fi
echo "unexpected oc call: $args" >&2
exit 2
FAKEOC
chmod +x "$NO_FALLBACK_TMP/bin/oc"

cat >"$NO_FALLBACK_CONFIG" <<EOF
ARTIFACT_DIR="$NO_FALLBACK_TMP/artifacts"
PULL_SECRET_FILE="$NO_FALLBACK_TMP/missing-pull-secret.json"
EOF

FAKE_OC_LOG="$NO_FALLBACK_TMP/oc.log" PATH="$NO_FALLBACK_TMP/bin:$PATH" \
  bash "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" --config "$NO_FALLBACK_CONFIG" extract-tests >"$NO_FALLBACK_TMP/out.txt" 2>&1

test -f "$NO_FALLBACK_TMP/artifacts/01-openshift-tests/pull-secret-skipped"
grep -Fq "PULL_SECRET_FILE not found" "$NO_FALLBACK_TMP/out.txt"
grep -Fq "openshift-config/pull-secret fallback unavailable" "$NO_FALLBACK_TMP/out.txt"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/pull-secret-required.sh`

Expected: FAIL because the fallback file is not created and `oc get secret pull-secret` is not called.

- [ ] **Step 3: Implement fallback helper**

In `dns-validation/lib/cluster.sh`, replace `require_pull_secret()` with:

```bash
resolve_openshift_config_pull_secret() {
  local d encoded fallback
  d="$ARTIFACT_DIR/tmp"
  fallback="$d/openshift-config-pull-secret.json"
  mkdir -p "$d"

  encoded="$(oc get secret pull-secret -n openshift-config -o 'jsonpath={.data.\.dockerconfigjson}' 2>/dev/null || true)"
  if [[ -z "$encoded" ]]; then
    warn "openshift-config/pull-secret fallback unavailable; conformance tests require a pull secret"
    return 1
  fi

  if ! printf '%s' "$encoded" | base64 -d >"$fallback" 2>/dev/null; then
    rm -f "$fallback"
    warn "openshift-config/pull-secret fallback could not be decoded; conformance tests require a pull secret"
    return 1
  fi
  chmod 0600 "$fallback" 2>/dev/null || true
  PULL_SECRET_FILE="$fallback"
  export PULL_SECRET_FILE
  log "Using openshift-config/pull-secret fallback for conformance image extraction."
  return 0
}

require_pull_secret() {
  [[ -f "$PULL_SECRET_FILE" && -r "$PULL_SECRET_FILE" ]] && return 0
  warn "PULL_SECRET_FILE not found or not readable: $PULL_SECRET_FILE"
  if resolve_openshift_config_pull_secret; then
    return 0
  fi
  warn "Skipping conformance tests because no pull secret is available."
  mkdir -p "$ARTIFACT_DIR/01-openshift-tests"
  touch "$ARTIFACT_DIR/01-openshift-tests/pull-secret-skipped"
  return 1
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/pull-secret-required.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add dns-validation/lib/cluster.sh tests/pull-secret-required.sh
git commit -m "fix(dns-validation): fall back to cluster pull secret"
```

---

### Task 4: Docs and Install Instructions

**Files:**
- Modify: `cluster-validator/README.md`
- Modify: `cluster-validator/manifests/configmap-dns-example.yaml`
- Test: `tests/cluster-validator-namespace.sh`

- [ ] **Step 1: Update smoke doc checks**

Add these checks to `tests/cluster-validator-namespace.sh`:

```bash
assert_contains "$REPO_ROOT/cluster-validator/README.md" "namespace-dns-validation.yaml"
assert_contains "$REPO_ROOT/cluster-validator/README.md" "role-openshift-config-pull-secret.yaml"
assert_contains "$REPO_ROOT/cluster-validator/manifests/configmap-dns-example.yaml" "openshift-config/pull-secret"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/cluster-validator-namespace.sh`

Expected: FAIL because README/config examples do not mention the new manifests/fallback yet.

- [ ] **Step 3: Update README and config example**

In `cluster-validator/README.md`, update install commands to apply all manifests:

```bash
oc apply -f cluster-validator/manifests/namespace.yaml
oc apply -f cluster-validator/manifests/namespace-dns-validation.yaml
oc apply -f cluster-validator/manifests/namespace-network-validation.yaml
oc apply -f cluster-validator/manifests/serviceaccount.yaml
oc apply -f cluster-validator/manifests/clusterrole.yaml
oc apply -f cluster-validator/manifests/clusterrolebinding.yaml
oc apply -f cluster-validator/manifests/role-dns-validation.yaml
oc apply -f cluster-validator/manifests/rolebinding-dns-validation.yaml
oc apply -f cluster-validator/manifests/role-network-validation.yaml
oc apply -f cluster-validator/manifests/rolebinding-network-validation.yaml
oc apply -f cluster-validator/manifests/role-openshift-config-pull-secret.yaml
oc apply -f cluster-validator/manifests/rolebinding-openshift-config-pull-secret.yaml
oc apply -f cluster-validator/manifests/role-openshift-dns-read.yaml
oc apply -f cluster-validator/manifests/rolebinding-openshift-dns-read.yaml
oc apply -f cluster-validator/manifests/role-openshift-dns-operator-read.yaml
oc apply -f cluster-validator/manifests/rolebinding-openshift-dns-operator-read.yaml
oc apply -f cluster-validator/manifests/role-openshift-console-read.yaml
oc apply -f cluster-validator/manifests/rolebinding-openshift-console-read.yaml
oc apply -f cluster-validator/manifests/role-openshift-ovn-kubernetes-read.yaml
oc apply -f cluster-validator/manifests/rolebinding-openshift-ovn-kubernetes-read.yaml
```

In `cluster-validator/manifests/configmap-dns-example.yaml`, document:

```bash
# PULL_SECRET_FILE is optional in-cluster when RBAC can read openshift-config/pull-secret.
# Set it only when mounting a custom pull secret file.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/cluster-validator-namespace.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cluster-validator/README.md cluster-validator/manifests/configmap-dns-example.yaml tests/cluster-validator-namespace.sh
git commit -m "docs(cluster-validator): document restricted RBAC install"
```

---

### Task 5: Full Verification

**Files:**
- No code changes unless verification exposes a defect.

- [ ] **Step 1: Run full static suite**

Run:

```bash
./scripts/check-static.sh
```

Expected: exit 0.

- [ ] **Step 2: Inspect final status**

Run:

```bash
git status --short
```

Expected: no uncommitted files.

- [ ] **Step 3: Summarize commits and verification**

Run:

```bash
git --no-pager log --oneline -n 6
```

Expected: includes commits for RBAC split, namespace verification, pull-secret fallback, and docs.

---

## Self-Review

Spec coverage:

- RBAC split: Task 1.
- Namespace create/delete removal: Task 2.
- Pull-secret fallback: Task 3.
- Docs/install instructions: Task 4.
- Full verification: Task 5.

Plan text is concrete. Function names and manifest names are consistent across tasks.
