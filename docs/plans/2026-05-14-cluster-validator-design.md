# Cluster Validator — Design

**Date:** 2026-05-14
**Status:** Approved

## Problem

The `dns-validation` and `network-validation` tools run on a RHEL 9 workstation and require a working `oc` session with cluster-admin privileges. This prevents ad-hoc use by people who have cluster access but no local toolchain. Running the validators as a Kubernetes Job inside the cluster removes the local dependency entirely.

## Approach

Add a new `cluster-validator/` top-level directory. It contains:
- a `Containerfile` that extends `network-testing-image` with the validator scripts
- an `entrypoint.sh` that selects which tool to run and wires configuration and artifacts
- a `manifests/` directory with all Kubernetes objects needed to deploy and run the Job
- a GitHub Actions workflow to build and publish the image

## Directory Layout

```text
cluster-validator/
├── Containerfile
├── bin/
│   └── entrypoint.sh
├── manifests/
│   ├── namespace.yaml
│   ├── namespace-dns-validation.yaml
│   ├── namespace-network-validation.yaml
│   ├── serviceaccount.yaml
│   ├── clusterrole.yaml
│   ├── clusterrolebinding.yaml
│   ├── role-*.yaml
│   ├── rolebinding-*.yaml
│   ├── configmap-dns-example.yaml
│   ├── configmap-network-example.yaml
│   ├── job-dns.yaml
│   └── job-network.yaml
└── README.md
```

A smoke test lives at `tests/cluster-validator-entrypoint.sh`.

## Container Image

### Base

`FROM ghcr.io/tomazb/openshift-testing/network-testing-image:latest`

`network-testing-image` already provides `oc`, `iperf3`, `dnsperf`, and all other runtime dependencies the validator scripts need.

### Build

```dockerfile
FROM ghcr.io/tomazb/openshift-testing/network-testing-image:latest
COPY dns-validation/     /opt/openshift-testing/dns-validation/
COPY network-validation/ /opt/openshift-testing/network-validation/
COPY cluster-validator/bin/entrypoint.sh /usr/local/bin/validator
RUN chmod +x /usr/local/bin/validator \
    && mkdir -p /artifacts /config /tmp/validator-home \
    && chgrp -R 0 /artifacts /config /tmp/validator-home \
    && chmod -R g=u /artifacts /config /tmp/validator-home
ENV HOME=/tmp/validator-home
USER 1001
ENTRYPOINT ["/usr/local/bin/validator"]
```

Scripts are copied at image build time. No volume mount for scripts is needed.

### Image tags published

```text
ghcr.io/tomazb/openshift-testing/cluster-validator:latest
ghcr.io/tomazb/openshift-testing/cluster-validator:main
ghcr.io/tomazb/openshift-testing/cluster-validator:sha-<short-sha>
```

## Entrypoint

`/usr/local/bin/validator` (sourced from `cluster-validator/bin/entrypoint.sh`).

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `VALIDATOR` | `dns` | Which tool to run: `dns`, `network`, or `all` |
| `ARTIFACT_DIR` | `/artifacts` | Where artifact files land |

### Config file

If `/config/validation.env` is present (a ConfigMap mounted at `/config`), it is passed to the validator via `--config /config/validation.env`. Otherwise, built-in defaults apply.

### Execution

- Runs `ocp-{dns,network}-validate --yes all` (non-interactive, full sequence)
- `VALIDATOR=all` runs dns first, then network; a failure in one does not abort the other
- All output goes to stdout (visible in `oc logs`)
- Artifact files land in `ARTIFACT_DIR`

## Kubernetes Manifests

### Namespaces

- `cluster-validator` — holds the ServiceAccount, ConfigMaps, and Jobs.
- `dns-validation` — runtime namespace for DNS sweep and dnsperf workloads.
- `network-validation` — runtime namespace for iperf3 validation workloads.

### ServiceAccount

`cluster-validator` in the `cluster-validator` namespace.

### ClusterRole and Roles

The ClusterRole grants read-only cluster discovery. Mutable runtime permissions
are scoped to the `dns-validation` and `network-validation` namespaces through
Role/RoleBinding manifests. Additional narrow read-only Roles cover OpenShift
component namespaces used for diagnostics, and `openshift-config/pull-secret`
access is limited to `get` on that single Secret.

| Resource | Verbs |
|---|---|
| `nodes` | get, list |
| `namespaces` | get, list |
| `clusterversions`, `clusteroperators`, `networks`, `ingresses` | get, list |
| `dnses.operator.openshift.io`, `networks.operator.openshift.io` | get, list |
| runtime namespace pods, services, configmaps, endpoints, apps workloads | get, list, create, delete, watch, patch, update |
| OpenShift diagnostic namespace pods/logs/events/routes | get, list as needed |
| `openshift-config` `secret/pull-secret` | get |

### ClusterRoleBinding

Binds the ClusterRole to the `cluster-validator` ServiceAccount in the `cluster-validator` namespace.

### Jobs

`job-dns.yaml` and `job-network.yaml` — each sets:
- `serviceAccountName: cluster-validator`
- `restartPolicy: Never`
- `VALIDATOR=dns` or `VALIDATOR=network` via env
- Optional volume mount for a ConfigMap at `/config`
- Optional volume mount for a PVC at `/artifacts`

The PVC volume and ConfigMap volume are included as commented-out sections so users can enable them by uncommenting.

### ConfigMap examples

`configmap-dns-example.yaml` and `configmap-network-example.yaml` contain the full set of tunable variables as comments, so users copy, rename, uncomment, and apply before running the Job.

## Configuration Precedence

1. Built-in script defaults (`${VAR:-default}`)
2. ConfigMap-mounted `validation.env` (if present at `/config/validation.env`)
3. Environment variables on the Job Pod (highest precedence, override ConfigMap values)

## GitHub Actions Workflow

`.github/workflows/cluster-validator-image.yml`

- **Trigger:** push to `main` or PR touching `cluster-validator/**`, `dns-validation/**`, `network-validation/**`
- **Build:** `podman build` with `cluster-validator/Containerfile` using the repo root as build context
- **Push:** to GHCR on `main` merges (not on PRs)
- **Smoke test on PR:** build only (no push), run `tests/cluster-validator-entrypoint.sh`

## Smoke Test

`tests/cluster-validator-entrypoint.sh`

Stubs `oc` and the two validator scripts. Verifies:

1. `VALIDATOR=dns` calls `ocp-dns-validate --yes all`
2. `VALIDATOR=network` calls `ocp-network-validate --yes all`
3. `VALIDATOR=all` calls both scripts
4. A ConfigMap mount at `/config/validation.env` is passed via `--config`
5. `/artifacts` is created and used as the default artifact directory
6. in-cluster kubeconfig generation is safe when HOME or service account files are absent

## Out of Scope

- Helm chart or Kustomize overlays (plain YAML is sufficient)
- Automatic scheduling / CronJob (one-shot Job is the right primitive here)
- Per-tool separate images (unified image reduces maintenance)
- Uploading artifacts to S3 (future enhancement)
