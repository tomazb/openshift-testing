# Cluster Validator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Package the dns-validation and network-validation shell scripts as a container image so anyone with cluster access can run either validator as a Kubernetes Job — no local toolchain required.

**Architecture:** A new `cluster-validator/` top-level directory holds a `Containerfile` (built FROM `network-testing-image`, scripts copied in at build time), a single `bin/entrypoint.sh` that selects which validator to run, a `manifests/` subdirectory with ready-to-apply Kubernetes YAML (namespace, RBAC, Jobs, ConfigMap examples), and a GitHub Actions workflow. The entrypoint generates an in-cluster kubeconfig from the pod's service account token so `oc` can talk to the API server without any external kubeconfig.

**Tech Stack:** Bash, Podman/Docker, GitHub Actions `docker/build-push-action`, Kubernetes/OpenShift YAML, GHCR.

---

## Reading before you start

- `docs/plans/2026-05-14-cluster-validator-design.md` — the approved design doc
- `scripts/check-static.sh` — you must register every new shell script here
- `tests/network-validation-smoke.sh` — example of how smoke tests are written in this repo
- `dns-validation/bin/ocp-dns-validate` and `network-validation/bin/ocp-network-validate` — the scripts you are wrapping (read the top of each to understand flags they accept)
- `.github/workflows/network-testing-image.yml` — the workflow pattern to follow

## Key conventions

- Every shell script starts with `set -Eeuo pipefail`.
- Smoke tests live under `tests/*.sh` and are picked up automatically by `check-static.sh`.
- Smoke tests use `mktemp -d` + an EXIT trap to clean up; they never write outside `$TMP_DIR`.
- Smoke tests stub `oc` via a `$FAKE_BIN` dir prepended to `$PATH`; they export `HOME` to a tmpdir to avoid polluting `~/.kube/config`.
- `check-static.sh` must be updated to include every new `bash -n` check and shellcheck target.
- Never commit `Co-authored-by` trailers — a git hook strips them but clean messages are better.

---

## Task 1: Create the directory skeleton

**Files:**
- Create: `cluster-validator/bin/.gitkeep` (placeholder)
- Create: `cluster-validator/manifests/.gitkeep` (placeholder)

**Step 1: Make the directories**

```bash
mkdir -p cluster-validator/bin cluster-validator/manifests
touch cluster-validator/bin/.gitkeep cluster-validator/manifests/.gitkeep
```

**Step 2: Verify**

```bash
ls cluster-validator/bin cluster-validator/manifests
```

Expected: both dirs exist with `.gitkeep`.

**Step 3: Commit**

```bash
git add cluster-validator/
git commit -m "chore(cluster-validator): scaffold directory structure"
```

---

## Task 2: Write the smoke test (failing)

**Files:**
- Create: `tests/cluster-validator-entrypoint.sh`

The test stubs the two validator scripts, then invokes the entrypoint under different `VALIDATOR` values and verifies which stubs were called. At this stage the entrypoint does not exist yet, so the test must fail.

**Step 1: Create the test**

```bash
cat > tests/cluster-validator-entrypoint.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- Stub validator scripts ---
DNS_STUB="$TMP_DIR/dns-stub"
NETWORK_STUB="$TMP_DIR/network-stub"
DNS_CALLS="$TMP_DIR/dns-calls"
NETWORK_CALLS="$TMP_DIR/network-calls"

cat >"$DNS_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DNS_CALLS_FILE"
STUB
chmod +x "$DNS_STUB"

cat >"$NETWORK_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NETWORK_CALLS_FILE"
STUB
chmod +x "$NETWORK_STUB"

# Helper: run entrypoint with stubs wired in
run_ep() {
  DNS_CALLS_FILE="$DNS_CALLS" NETWORK_CALLS_FILE="$NETWORK_CALLS" \
  DNS_VALIDATE="$DNS_STUB" NETWORK_VALIDATE="$NETWORK_STUB" \
  HOME="$TMP_DIR/home" \
    bash "$REPO_ROOT/cluster-validator/bin/entrypoint.sh" "$@"
}

# Reset call logs between tests
reset_calls() {
  rm -f "$DNS_CALLS" "$NETWORK_CALLS"
}

mkdir -p "$TMP_DIR/home"

# --- Test 1: VALIDATOR=dns calls only the dns validator with --yes all ---
reset_calls
VALIDATOR=dns run_ep

grep -Fq -- "--yes all" "$DNS_CALLS"
if [[ -f "$NETWORK_CALLS" ]]; then
  echo "FAIL: network validator should not have been called for VALIDATOR=dns" >&2
  exit 1
fi

# --- Test 2: VALIDATOR=network calls only the network validator with --yes all ---
reset_calls
VALIDATOR=network run_ep

grep -Fq -- "--yes all" "$NETWORK_CALLS"
if [[ -f "$DNS_CALLS" ]]; then
  echo "FAIL: dns validator should not have been called for VALIDATOR=network" >&2
  exit 1
fi

# --- Test 3: VALIDATOR=all calls both validators ---
reset_calls
VALIDATOR=all run_ep

grep -Fq -- "--yes all" "$DNS_CALLS"
grep -Fq -- "--yes all" "$NETWORK_CALLS"

# --- Test 4: Default VALIDATOR is dns ---
reset_calls
run_ep

grep -Fq -- "--yes all" "$DNS_CALLS"
if [[ -f "$NETWORK_CALLS" ]]; then
  echo "FAIL: default should be dns, not network" >&2
  exit 1
fi

# --- Test 5: ConfigMap mount passes --config to the validator ---
reset_calls
mkdir -p "$TMP_DIR/config"
echo "# config" > "$TMP_DIR/config/validation.env"

DNS_CALLS_FILE="$DNS_CALLS" NETWORK_CALLS_FILE="$NETWORK_CALLS" \
DNS_VALIDATE="$DNS_STUB" NETWORK_VALIDATE="$NETWORK_STUB" \
HOME="$TMP_DIR/home" \
  bash "$REPO_ROOT/cluster-validator/bin/entrypoint.sh" \
    --config-dir "$TMP_DIR/config"

grep -Fq -- "--config $TMP_DIR/config/validation.env --yes all" "$DNS_CALLS"

# --- Test 6: VALIDATOR=all continues past a dns failure ---
reset_calls
FAIL_DNS_STUB="$TMP_DIR/fail-dns-stub"
cat >"$FAIL_DNS_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DNS_CALLS_FILE"
exit 1
STUB
chmod +x "$FAIL_DNS_STUB"

set +e
DNS_CALLS_FILE="$DNS_CALLS" NETWORK_CALLS_FILE="$NETWORK_CALLS" \
DNS_VALIDATE="$FAIL_DNS_STUB" NETWORK_VALIDATE="$NETWORK_STUB" \
HOME="$TMP_DIR/home" \
  VALIDATOR=all bash "$REPO_ROOT/cluster-validator/bin/entrypoint.sh"
overall_rc=$?
set -e

if [[ "$overall_rc" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit when a validator fails" >&2
  exit 1
fi
# network must still have been called even though dns failed
grep -Fq -- "--yes all" "$NETWORK_CALLS"

# --- Test 7: Unknown VALIDATOR value exits 2 ---
reset_calls
set +e
VALIDATOR=bogus run_ep >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 2 ]]; then
  echo "FAIL: unknown VALIDATOR should exit 2, got $rc" >&2
  exit 1
fi

echo "All cluster-validator-entrypoint tests passed."
EOF
chmod +x tests/cluster-validator-entrypoint.sh
```

**Step 2: Run to confirm it fails**

```bash
bash tests/cluster-validator-entrypoint.sh
```

Expected: error like `bash: .../cluster-validator/bin/entrypoint.sh: No such file or directory`.

---

## Task 3: Implement entrypoint.sh

**Files:**
- Create: `cluster-validator/bin/entrypoint.sh`
- Delete: `cluster-validator/bin/.gitkeep`

The entrypoint:
1. Generates `/root/.kube/config` from the pod's service account token if in-cluster creds exist — so `oc` can reach the API server without an externally-supplied kubeconfig.
2. Determines `ARTIFACT_DIR` (defaults to `/artifacts`).
3. Resolves the config file flag from `--config-dir` or the fixed `/config/validation.env` path.
4. Dispatches to `ocp-dns-validate`, `ocp-network-validate`, or both based on `VALIDATOR`.

**Step 1: Write the file**

```bash
cat > cluster-validator/bin/entrypoint.sh << 'ENTRYPOINT'
#!/usr/bin/env bash
# Entrypoint for the cluster-validator container image.
# Selects which OpenShift validation tool to run and wires in-cluster credentials.
set -Eeuo pipefail

DNS_VALIDATE="${DNS_VALIDATE:-/opt/openshift-testing/dns-validation/bin/ocp-dns-validate}"
NETWORK_VALIDATE="${NETWORK_VALIDATE:-/opt/openshift-testing/network-validation/bin/ocp-network-validate}"
VALIDATOR="${VALIDATOR:-dns}"
CONFIG_DIR="/config"

# Allow --config-dir override (used by smoke tests to inject a custom config dir)
if [[ "${1:-}" == "--config-dir" ]]; then
  CONFIG_DIR="$2"
  shift 2
fi

# Build ~/.kube/config from the pod's service account token when running in-cluster.
_SA_TOKEN="/var/run/secrets/kubernetes.io/serviceaccount/token"
_SA_CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
_SA_NS_FILE="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
if [[ -f "$_SA_TOKEN" && -f "$_SA_CA" ]]; then
  mkdir -p "$HOME/.kube"
  _ns="$(cat "$_SA_NS_FILE")"
  cat >"$HOME/.kube/config" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: $_SA_CA
    server: https://kubernetes.default.svc
  name: in-cluster
contexts:
- context:
    cluster: in-cluster
    namespace: $_ns
    user: validator
  name: in-cluster
current-context: in-cluster
users:
- name: validator
  user:
    tokenFile: $_SA_TOKEN
KUBECONFIG
fi

export ARTIFACT_DIR="${ARTIFACT_DIR:-/artifacts}"
mkdir -p "$ARTIFACT_DIR"

# Build the common argument list; prepend --config if a config file is present.
args=(--yes all)
if [[ -f "$CONFIG_DIR/validation.env" ]]; then
  args=(--config "$CONFIG_DIR/validation.env" --yes all)
fi

run_dns() {
  echo "=== cluster-validator: running dns-validation ==="
  "$DNS_VALIDATE" "${args[@]}"
}

run_network() {
  echo "=== cluster-validator: running network-validation ==="
  "$NETWORK_VALIDATE" "${args[@]}"
}

case "$VALIDATOR" in
  dns)
    run_dns
    ;;
  network)
    run_network
    ;;
  all)
    dns_rc=0
    network_rc=0
    run_dns     || dns_rc=$?
    run_network || network_rc=$?
    if [[ $dns_rc -ne 0 || $network_rc -ne 0 ]]; then
      echo "=== cluster-validator: one or more validators failed (dns=$dns_rc network=$network_rc) ===" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: unknown VALIDATOR='$VALIDATOR'. Valid values: dns, network, all." >&2
    exit 2
    ;;
esac
ENTRYPOINT
chmod +x cluster-validator/bin/entrypoint.sh
rm cluster-validator/bin/.gitkeep
```

**Step 2: Run the test**

```bash
bash tests/cluster-validator-entrypoint.sh
```

Expected: `All cluster-validator-entrypoint tests passed.`

**Step 3: Commit**

```bash
git add cluster-validator/bin/entrypoint.sh tests/cluster-validator-entrypoint.sh
git commit -m "feat(cluster-validator): add entrypoint.sh and smoke test"
```

---

## Task 4: Update check-static.sh

**Files:**
- Modify: `scripts/check-static.sh`

Add `cluster-validator/bin/entrypoint.sh` to the `bash -n` syntax checks and to the `shellcheck` invocation at the bottom of the file. The test glob `tests/*.sh` already covers the new test automatically.

**Step 1: Add bash -n check**

In `check-static.sh`, find the block of `bash -n` lines (e.g. `bash -n dns-validation/bin/ocp-dns-validate`) and add after the last one:

```bash
bash -n cluster-validator/bin/entrypoint.sh
```

**Step 2: Add to shellcheck invocation**

Find the `shellcheck -x \` block. Append `cluster-validator/bin/entrypoint.sh \` before the closing `"${test_scripts[@]}"` line.

The relevant section currently ends with:
```
  iperf3/iperf3-network-metrics-collector.sh \
  scripts/check-static.sh \
  "${profile_files[@]}" \
  "${test_scripts[@]}"
```

Change it to:
```
  iperf3/iperf3-network-metrics-collector.sh \
  scripts/check-static.sh \
  cluster-validator/bin/entrypoint.sh \
  "${profile_files[@]}" \
  "${test_scripts[@]}"
```

**Step 3: Run static checks**

```bash
bash scripts/check-static.sh
```

Expected: all checks pass, no shellcheck errors.

**Step 4: Commit**

```bash
git add scripts/check-static.sh
git commit -m "chore(check-static): add cluster-validator entrypoint to checks"
```

---

## Task 5: Write the Containerfile

**Files:**
- Create: `cluster-validator/Containerfile`
- Delete: `cluster-validator/manifests/.gitkeep`

The build context is the **repo root** (so both `dns-validation/` and `network-validation/` are reachable). The Containerfile extends `network-testing-image` (which already provides `oc`, `iperf3`, `dnsperf`, and all other tool dependencies).

**Step 1: Write Containerfile**

```bash
cat > cluster-validator/Containerfile << 'EOF'
FROM ghcr.io/tomazb/openshift-testing/network-testing-image:latest

COPY dns-validation/     /opt/openshift-testing/dns-validation/
COPY network-validation/ /opt/openshift-testing/network-validation/
COPY cluster-validator/bin/entrypoint.sh /usr/local/bin/validator

RUN chmod +x /usr/local/bin/validator \
    && mkdir -p /artifacts /config

ENTRYPOINT ["/usr/local/bin/validator"]
EOF
rm cluster-validator/manifests/.gitkeep
```

**Step 2: Syntax-check with bash -n (Containerfile is not a shell script; skip)**

**Step 3: Commit**

```bash
git add cluster-validator/Containerfile
git commit -m "feat(cluster-validator): add Containerfile"
```

---

## Task 6: Write RBAC manifests

**Files:**
- Create: `cluster-validator/manifests/namespace.yaml`
- Create: `cluster-validator/manifests/serviceaccount.yaml`
- Create: `cluster-validator/manifests/clusterrole.yaml`
- Create: `cluster-validator/manifests/clusterrolebinding.yaml`

The resources below cover everything the two validator scripts actually invoke via `oc`. The ClusterRole is scoped to the minimum necessary — it does not grant cluster-admin.

**Step 1: Write namespace.yaml**

```bash
cat > cluster-validator/manifests/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-testing
EOF
```

**Step 2: Write serviceaccount.yaml**

```bash
cat > cluster-validator/manifests/serviceaccount.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-validator
  namespace: openshift-testing
EOF
```

**Step 3: Write clusterrole.yaml**

The rules cover every `oc` call made by dns-validation and network-validation:
- Core API: nodes, namespaces, pods, pods/log, pods/exec, services, configmaps, endpoints, events
- apps: daemonsets
- config.openshift.io: clusterversions, clusteroperators, networks, ingresses
- operator.openshift.io: dnses, networks
- route.openshift.io: routes (console route lookup in dns preflight)
- discovery.k8s.io: endpointslices

```bash
cat > cluster-validator/manifests/clusterrole.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-validator
rules:
  # Core — cluster topology and identity
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [get, list, create, delete]
  # Core — pod lifecycle and diagnostics
  - apiGroups: [""]
    resources: [pods, pods/log, pods/exec]
    verbs: [get, list, create, delete, watch]
  # Core — services, configmaps, endpoints
  - apiGroups: [""]
    resources: [services, configmaps, endpoints]
    verbs: [get, list, create, delete, watch]
  # Core — events
  - apiGroups: [""]
    resources: [events]
    verbs: [get, list]
  # apps — DaemonSets (node sweep, OVN inspection)
  - apiGroups: [apps]
    resources: [daemonsets]
    verbs: [get, list, create, delete, watch]
  # OpenShift cluster config
  - apiGroups: [config.openshift.io]
    resources: [clusterversions, clusteroperators, networks, ingresses]
    verbs: [get, list]
  # OpenShift operator config (DNS and network operators)
  - apiGroups: [operator.openshift.io]
    resources: [dnses, networks]
    verbs: [get, list]
  # Routes (console route lookup in dns preflight)
  - apiGroups: [route.openshift.io]
    resources: [routes]
    verbs: [get]
  # EndpointSlices (dns preflight)
  - apiGroups: [discovery.k8s.io]
    resources: [endpointslices]
    verbs: [get, list]
EOF
```

**Step 4: Write clusterrolebinding.yaml**

```bash
cat > cluster-validator/manifests/clusterrolebinding.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-validator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-validator
subjects:
  - kind: ServiceAccount
    name: cluster-validator
    namespace: openshift-testing
EOF
```

**Step 5: Commit**

```bash
git add cluster-validator/manifests/
git commit -m "feat(cluster-validator): add RBAC manifests"
```

---

## Task 7: Write Job manifests

**Files:**
- Create: `cluster-validator/manifests/job-dns.yaml`
- Create: `cluster-validator/manifests/job-network.yaml`

Each Job includes commented-out volume mounts for the ConfigMap (at `/config`) and a PVC (at `/artifacts`). Users uncomment whichever they need.

**Step 1: Write job-dns.yaml**

```bash
cat > cluster-validator/manifests/job-dns.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: dns-validation
  namespace: openshift-testing
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: cluster-validator
      containers:
        - name: dns-validation
          image: ghcr.io/tomazb/openshift-testing/cluster-validator:latest
          env:
            - name: VALIDATOR
              value: dns
          # Uncomment to override individual config variables:
          # - name: VALIDATION_NAMESPACE
          #   value: dns-validation
          # - name: DNSPERF_QPS_STEPS
          #   value: "100 500 1000"
          volumeMounts: []
          # Uncomment to supply a full config file via ConfigMap:
          # volumeMounts:
          #   - name: config
          #     mountPath: /config
          #     readOnly: true
          # Uncomment to persist artifacts to a PVC:
          #   - name: artifacts
          #     mountPath: /artifacts
      volumes: []
      # volumes:
      #   - name: config
      #     configMap:
      #       name: dns-validation-config
      #   - name: artifacts
      #     persistentVolumeClaim:
      #       claimName: dns-validation-artifacts
EOF
```

**Step 2: Write job-network.yaml**

```bash
cat > cluster-validator/manifests/job-network.yaml << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: network-validation
  namespace: openshift-testing
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: cluster-validator
      containers:
        - name: network-validation
          image: ghcr.io/tomazb/openshift-testing/cluster-validator:latest
          env:
            - name: VALIDATOR
              value: network
          # Uncomment to override individual config variables:
          # - name: IPERF_NAMESPACE
          #   value: network-validation
          # - name: IPERF_DURATION
          #   value: "30"
          volumeMounts: []
          # Uncomment to supply a full config file via ConfigMap:
          # volumeMounts:
          #   - name: config
          #     mountPath: /config
          #     readOnly: true
          # Uncomment to persist artifacts to a PVC:
          #   - name: artifacts
          #     mountPath: /artifacts
      volumes: []
      # volumes:
      #   - name: config
      #     configMap:
      #       name: network-validation-config
      #   - name: artifacts
      #     persistentVolumeClaim:
      #       claimName: network-validation-artifacts
EOF
```

**Step 3: Commit**

```bash
git add cluster-validator/manifests/job-dns.yaml cluster-validator/manifests/job-network.yaml
git commit -m "feat(cluster-validator): add Job manifests"
```

---

## Task 8: Write ConfigMap examples

**Files:**
- Create: `cluster-validator/manifests/configmap-dns-example.yaml`
- Create: `cluster-validator/manifests/configmap-network-example.yaml`

These are reference ConfigMaps. Every variable is commented out so users see the available knobs and uncomment only what they need.

**Step 1: Write configmap-dns-example.yaml**

```bash
cat > cluster-validator/manifests/configmap-dns-example.yaml << 'EOF'
# Copy this file, remove the -example suffix, and uncomment variables you want to override.
# Mount the ConfigMap in job-dns.yaml under /config.
#
# oc create -f configmap-dns.yaml -n openshift-testing
apiVersion: v1
kind: ConfigMap
metadata:
  name: dns-validation-config
  namespace: openshift-testing
data:
  validation.env: |
    # Temporary namespace used for node sweep and dnsperf workloads.
    # VALIDATION_NAMESPACE="dns-validation"

    # Pull secret — required only for extract-tests / run-dns-tests.
    # Mount a Secret containing pull-secret.json and set the path here.
    # PULL_SECRET_FILE="/secrets/pull-secret.json"

    # DNS conformance test filter regex.
    # DNS_TEST_REGEX="dns|\[sig-network\].*DNS"

    # Pipe-separated test names to exclude; leave empty to run all matches.
    # DNS_TEST_EXCLUDE_REGEX=""

    # Node-level DNS sweep image.
    # DNS_SWEEP_IMAGE="registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3"

    # dnsperf image.
    # DNSPERF_IMAGE="docker.io/guessi/dnsperf:2.15.1-1"

    # dnsperf QPS ladder steps.
    # DNSPERF_QPS_STEPS="100 500 1000 2000"

    # Seconds per QPS step.
    # DNSPERF_DURATION_SECONDS="60"
EOF
```

**Step 2: Write configmap-network-example.yaml**

```bash
cat > cluster-validator/manifests/configmap-network-example.yaml << 'EOF'
# Copy this file, remove the -example suffix, and uncomment variables you want to override.
# Mount the ConfigMap in job-network.yaml under /config.
#
# oc create -f configmap-network.yaml -n openshift-testing
apiVersion: v1
kind: ConfigMap
metadata:
  name: network-validation-config
  namespace: openshift-testing
data:
  validation.env: |
    # Temporary namespace used for iperf3 pods.
    # IPERF_NAMESPACE="network-validation"

    # Pin specific nodes (leave empty for auto-selection).
    # IPERF_SERVER_NODE=""
    # IPERF_CLIENT_NODE=""

    # iperf3 test duration in seconds.
    # IPERF_DURATION="30"

    # Protocol: tcp or udp.
    # IPERF_PROTOCOL="tcp"

    # Minimum acceptable throughput in Gbps (0 = skip threshold check).
    # IPERF_MIN_THROUGHPUT_GBPS="0"

    # Enable extended deep metrics collection.
    # IPERF_DEEP_METRICS="false"

    # Pod image (default: network-testing-image from GHCR).
    # IPERF_IMAGE="ghcr.io/tomazb/openshift-testing/network-testing-image:latest"
EOF
```

**Step 3: Commit**

```bash
git add cluster-validator/manifests/configmap-dns-example.yaml cluster-validator/manifests/configmap-network-example.yaml
git commit -m "feat(cluster-validator): add ConfigMap examples"
```

---

## Task 9: Write the GitHub Actions workflow

**Files:**
- Create: `.github/workflows/cluster-validator-image.yml`

Pattern: follow `.github/workflows/network-testing-image.yml` exactly. The build context is the repo root; the Containerfile path is `cluster-validator/Containerfile`.

**Step 1: Write the workflow**

```bash
cat > .github/workflows/cluster-validator-image.yml << 'EOF'
name: Cluster validator image

on:
  pull_request:
    paths:
      - cluster-validator/**
      - dns-validation/**
      - network-validation/**
  push:
    branches:
      - main
    paths:
      - cluster-validator/**
      - dns-validation/**
      - network-validation/**
    tags:
      - "cluster-validator-v*"

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}/cluster-validator

jobs:
  build-test-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      attestations: write
      id-token: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v5

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v4

      - name: Build image for smoke test
        uses: docker/build-push-action@v7
        with:
          context: .
          file: cluster-validator/Containerfile
          load: true
          platforms: linux/amd64
          tags: cluster-validator:test

      - name: Smoke test image
        run: |
          docker run --rm cluster-validator:test bash -euxo pipefail -c '
            command -v validator
            test -f /opt/openshift-testing/dns-validation/bin/ocp-dns-validate
            test -f /opt/openshift-testing/network-validation/bin/ocp-network-validate
            test -d /artifacts
            test -d /config
          '

      - name: Log in to GitHub Container Registry
        if: github.event_name == 'push'
        uses: docker/login-action@v4
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract image metadata
        if: github.event_name == 'push'
        id: meta
        uses: docker/metadata-action@v6
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=ref,event=branch
            type=ref,event=tag
            type=sha,prefix=sha-
            type=raw,value=latest,enable={{is_default_branch}}

      - name: Build and push image
        if: github.event_name == 'push'
        id: push
        uses: docker/build-push-action@v7
        with:
          context: .
          file: cluster-validator/Containerfile
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

      - name: Generate build provenance
        if: github.event_name == 'push'
        uses: actions/attest-build-provenance@v3
        with:
          subject-name: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          subject-digest: ${{ steps.push.outputs.digest }}
          push-to-registry: true
EOF
```

**Step 2: Commit**

```bash
git add .github/workflows/cluster-validator-image.yml
git commit -m "ci: add cluster-validator image build workflow"
```

---

## Task 10: Write the README

**Files:**
- Create: `cluster-validator/README.md`

**Step 1: Write README.md**

```bash
cat > cluster-validator/README.md << 'EOF'
# Cluster Validator

Run `dns-validation` or `network-validation` directly on an OpenShift cluster as a Kubernetes Job — no local toolchain required.

## Prerequisites

- `oc` or `kubectl` with cluster-admin (to apply RBAC and create the Job)
- Pull access to `ghcr.io/tomazb/openshift-testing/cluster-validator:latest`

## Quick start

```bash
# 1. Create the namespace and RBAC (one-time setup)
oc apply -f cluster-validator/manifests/namespace.yaml
oc apply -f cluster-validator/manifests/serviceaccount.yaml
oc apply -f cluster-validator/manifests/clusterrole.yaml
oc apply -f cluster-validator/manifests/clusterrolebinding.yaml

# 2. Run DNS validation
oc create -f cluster-validator/manifests/job-dns.yaml

# 3. Follow logs
oc logs -f job/dns-validation -n openshift-testing

# 4. Run network validation
oc create -f cluster-validator/manifests/job-network.yaml
oc logs -f job/network-validation -n openshift-testing
```

## Configuration

### Using environment variables (simple overrides)

Add variables directly in the Job YAML under `spec.template.spec.containers[].env`.
Example variables are documented as comments in `job-dns.yaml` and `job-network.yaml`.

### Using a ConfigMap (full config)

Copy `manifests/configmap-dns-example.yaml` to `configmap-dns.yaml`, remove the `-example` suffix, uncomment and edit variables, then:

```bash
oc apply -f cluster-validator/manifests/configmap-dns.yaml -n openshift-testing
```

Uncomment the `volumes` and `volumeMounts` sections in `job-dns.yaml`, then create the Job.

## Persisting artifacts

Uncomment the `artifacts` volume and `volumeMounts` in the Job YAML and create a PVC named
`dns-validation-artifacts` (or `network-validation-artifacts`) before running the Job.
Artifact files will land under `/artifacts` inside the pod and survive pod completion.

## Running both validators

Set `VALIDATOR=all` on either Job to run DNS validation followed by network validation in one pod.
The Job exits non-zero if either validator reports a failure.

## Image tags

| Tag | Meaning |
|-----|---------|
| `latest` | Latest build from `main` |
| `main` | Same as `latest` |
| `sha-<short>` | Pinned to a specific commit |
| `cluster-validator-v*` | Release tags |
EOF
```

**Step 2: Commit**

```bash
git add cluster-validator/README.md
git commit -m "docs(cluster-validator): add README"
```

---

## Task 11: Final verification

Run the full static-check suite to confirm nothing is broken end-to-end.

**Step 1: Run all checks**

```bash
bash scripts/check-static.sh
```

Expected: exits 0, no errors.

**Step 2: Confirm git history is clean**

```bash
git --no-pager log --oneline -8
git diff --check
```

Expected: no whitespace errors, clean history with one commit per task.
