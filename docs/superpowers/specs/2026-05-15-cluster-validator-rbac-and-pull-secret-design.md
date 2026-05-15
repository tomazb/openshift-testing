# Cluster Validator RBAC and Pull Secret Fallback Design

## Goal

Harden the `cluster-validator` live-cluster installation so runtime Jobs keep the permissions they need without cluster-wide mutation or namespace deletion privileges. Add an in-cluster DNS pull-secret fallback that can use the OpenShift global pull secret without requiring users to mount a local pull-secret file into the Job.

## Context

The current `cluster-validator` install binds one broad `ClusterRole` to the `cluster-validator` service account. That role allows cluster-wide mutation for pods, services, configmaps, endpoints, apps workloads, and namespaces. Live testing showed this is functional, but it gives the validator pod a high-impact blast radius if its token is compromised.

DNS conformance currently requires `PULL_SECRET_FILE`. When it is missing, guarded actions such as `extract-tests`, `discover-dns-tests`, `run-dns-tests`, and `run-single-test` skip the conformance path. In OpenShift, the global pull secret already exists as `secret/pull-secret` in `openshift-config`, so the in-cluster Job should be able to use that as a fallback with tightly scoped RBAC.

## Design

Split runtime permissions into a small set of purpose-specific roles.

1. Keep a read-only cluster-level role for discovery:
   - `nodes`: `get`, `list`
   - `namespaces`: `get`, `list`
   - `config.openshift.io`: `clusterversions`, `clusteroperators`, `networks`, `ingresses`
   - `operator.openshift.io`: `dnses`, `networks`

2. Move mutable workload permissions into namespace-local roles:
   - `dns-validation`: pods, pods/log, pods/exec, services, configmaps, endpoints, events, daemonsets, deployments, replicasets as required by DNS sweep and dnsperf.
   - `network-validation`: pods, pods/log, pods/exec, services, configmaps, endpoints, events, daemonsets, deployments, replicasets as required by iperf deployment and diagnostics.

3. Add read-only diagnostic roles where the validator reads OpenShift component state:
   - `openshift-dns`: read workloads, endpoint slices, events, logs, and pod descriptions needed by DNS diagnostics.
   - `openshift-dns-operator`: read workloads, events, logs, and pod descriptions needed by DNS diagnostics.
   - `openshift-console`: get the `console` route if preflight keeps collecting the console host.
   - `openshift-ovn-kubernetes`: read OVN workloads, events, and logs. Do not grant `pods/exec` here by default; commands such as `ovn-nbctl`, interface stats, and `ovs-ofctl` become best-effort diagnostics that may be skipped unless an explicit elevated diagnostics manifest is installed.

4. Add a narrow pull-secret reader:
   - namespace: `openshift-config`
   - resource: `secrets`
   - `resourceNames: ["pull-secret"]`
   - verbs: `get`

The runtime service account should no longer be able to create or delete namespaces. The install manifests should pre-create `cluster-validator`, `dns-validation`, and `network-validation`. Runtime `ensure_namespace()` should verify that the configured namespace exists and fail with a clear installation/RBAC message if it does not.

## Pull Secret Flow

`require_pull_secret()` should keep its current first choice: if `PULL_SECRET_FILE` points to a readable file, use it.

If the file is missing or unreadable, it should attempt the in-cluster fallback:

1. Read `secret/pull-secret` from `openshift-config`.
2. Decode `.data[".dockerconfigjson"]`.
3. Write it to an artifact-local file such as `$ARTIFACT_DIR/tmp/openshift-config-pull-secret.json` with restrictive file permissions.
4. Set `PULL_SECRET_FILE` to that generated file for the current process.
5. Continue extraction and conformance actions.

If the fallback cannot read or decode the secret, preserve the current behavior: warn clearly, create the `pull-secret-skipped` sentinel, and return non-zero so guarded conformance actions skip without failing unrelated DNS checks.

## Error Handling

Missing validation namespaces should be treated as install/setup errors for actions that need to deploy resources. The error should say which namespace is missing and point users to the cluster-validator install manifests.

Missing `openshift-config/pull-secret` permission should not fail the whole DNS validation. It should be reported as a conformance skip, matching current missing local pull-secret behavior.

OpenShift component diagnostics that are not allowed by restricted RBAC should remain best-effort captures. The report should distinguish skipped diagnostics from validator failures.

## Manifest Changes

Replace the single broad ClusterRole/ClusterRoleBinding with:

- `clusterrole-readonly.yaml`
- `clusterrolebinding-readonly.yaml`
- `namespace-dns-validation.yaml`
- `namespace-network-validation.yaml`
- `role-dns-validation.yaml`
- `rolebinding-dns-validation.yaml`
- `role-network-validation.yaml`
- `rolebinding-network-validation.yaml`
- `role-openshift-config-pull-secret.yaml`
- `rolebinding-openshift-config-pull-secret.yaml`
- read-only diagnostic Role/RoleBinding manifests for OpenShift component namespaces

Existing install instructions should apply all required manifests before creating Jobs.

## Testing

Add smoke tests that verify:

- The shipped manifests no longer grant namespace `create` or `delete` to the runtime service account.
- Mutable pod/service/configmap/apps permissions are scoped to `dns-validation` and `network-validation`, not cluster-wide.
- `openshift-config` secret access is limited to `get` on `resourceNames: ["pull-secret"]`.
- `require_pull_secret()` uses an existing `PULL_SECRET_FILE` without calling the fallback.
- `require_pull_secret()` falls back to `openshift-config/pull-secret` when `PULL_SECRET_FILE` is missing.
- `require_pull_secret()` preserves the current graceful skip when both the file and fallback are unavailable.
- `ensure_namespace()` fails clearly when a required validation namespace is not pre-created.

Run the full static suite after implementation:

```bash
./scripts/check-static.sh
```

## Out of Scope

- Changing the DNS test discovery regex or conformance selection.
- Granting default `pods/exec` into `openshift-ovn-kubernetes`.
- Copying or persisting the OpenShift global pull secret outside the artifact directory.
- Changing the CI image publishing workflow.
