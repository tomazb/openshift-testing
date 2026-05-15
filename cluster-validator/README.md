# Cluster Validator

Run `dns-validation` or `network-validation` directly on an OpenShift cluster as a Kubernetes Job — no local toolchain required.

## Prerequisites

- `oc` or `kubectl` with cluster-admin (to apply RBAC and create the Job)
- Pull access to `ghcr.io/tomazb/openshift-testing/cluster-validator:latest` (published by CI)

## Quick start

```bash
# 1. Create namespaces and RBAC (one-time setup)
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

# 2. Run DNS validation
oc create -f cluster-validator/manifests/job-dns.yaml

# 3. Follow logs
oc logs -f job/dns-validation -n cluster-validator

# 4. Run network validation
oc create -f cluster-validator/manifests/job-network.yaml
oc logs -f job/network-validation -n cluster-validator
```

## Configuration

### Using environment variables (simple overrides)

Add variables directly in the Job YAML under `spec.template.spec.containers[].env`.
Example variables are documented as comments in `job-dns.yaml` and `job-network.yaml`.

DNS conformance can use a mounted `PULL_SECRET_FILE`. When it is not set or the
file is missing, the in-cluster Job falls back to `openshift-config/pull-secret`
through the narrow `role-openshift-config-pull-secret.yaml` binding.

### Using a ConfigMap (full config)

Copy the DNS or network ConfigMap example, remove the `-example` suffix,
uncomment and edit variables, then apply it:

```bash
oc apply -f cluster-validator/manifests/configmap-dns.yaml -n cluster-validator
oc apply -f cluster-validator/manifests/configmap-network.yaml -n cluster-validator
```

Uncomment the matching `volumes` and `volumeMounts` sections in `job-dns.yaml`
or `job-network.yaml`, then create the Job.

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
