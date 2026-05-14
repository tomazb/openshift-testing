# Live Cluster PR Test - Design

Date: 2026-05-14
Status: Approved for specification

## Goal

Validate PR #10, `feat: add cluster-validator - run validation tools as Kubernetes Jobs`, on the live OpenShift cluster using the current `oc` context `ocp1htz1`.

The test should prove that the new `cluster-validator` manifests and container entrypoint work in the cluster, not only in local smoke tests.

## Cluster Context

- Kubernetes context: `ocp1htz1`
- User identity: `system:admin`
- OpenShift version observed before the test: `4.20.17`
- Test namespace: `openshift-testing`

The namespace does not exist before the test, so the run will create it through the PR manifest.

## Scope

In scope:

- Run repository static and smoke tests before touching the cluster.
- Apply the PR Kubernetes manifests:
  - `cluster-validator/manifests/namespace.yaml`
  - `cluster-validator/manifests/serviceaccount.yaml`
  - `cluster-validator/manifests/clusterrole.yaml`
  - `cluster-validator/manifests/clusterrolebinding.yaml`
- Run the DNS validator Job from `cluster-validator/manifests/job-dns.yaml`.
- Run the network validator Job from `cluster-validator/manifests/job-network.yaml`.
- Capture Job status, pod status, and validator logs.
- Clean up resources created by the test when evidence has been collected.

Out of scope:

- Changing PR code or manifests unless the live test exposes a bug.
- Persisting artifacts through PVCs.
- Adding ConfigMaps or custom runtime configuration.
- Testing release tags other than the image referenced by the PR manifests.

## Test Flow

1. Confirm the active context is `ocp1htz1`.
2. Run `scripts/check-static.sh`.
3. Apply namespace and RBAC manifests.
4. Create the DNS validation Job.
5. Wait for the DNS Job to complete or fail.
6. Collect DNS Job description, pod status, and logs.
7. Delete the DNS Job so a rerun is possible.
8. Create the network validation Job.
9. Wait for the network Job to complete or fail.
10. Collect network Job description, pod status, and logs.
11. Clean up the `openshift-testing` namespace and cluster-scoped RBAC created by the manifests.

## Success Criteria

The PR is considered live-tested successfully when:

- Local static and smoke tests pass.
- The namespace, ServiceAccount, ClusterRole, and ClusterRoleBinding apply without error.
- Both Jobs create pods successfully.
- The DNS Job reaches `Complete`.
- The network Job reaches `Complete`.
- Logs show the `cluster-validator` entrypoint selected the expected validator for each Job.
- No image pull, RBAC, in-cluster kubeconfig, config discovery, or artifact directory failures appear in the logs.

## Failure Handling

If a local test fails, stop before making cluster changes and report the failing command.

If a cluster step fails, collect the highest-signal evidence before cleanup:

- `oc describe job`
- `oc get pods -o wide`
- `oc describe pod`
- `oc logs`
- relevant events from the `openshift-testing` namespace

Cleanup still runs unless the remaining resources are needed to inspect an active failure.

## Cleanup

The cleanup will remove:

- `job/dns-validation` in `openshift-testing`, if present
- `job/network-validation` in `openshift-testing`, if present
- `clusterrolebinding/cluster-validator`
- `clusterrole/cluster-validator`
- `namespace/openshift-testing`

The cleanup does not delete unrelated cluster resources.

## Reporting

The final report will include:

- Local test result.
- Cluster context and OpenShift version.
- DNS Job result and key log lines.
- Network Job result and key log lines.
- Cleanup result.
- Any failures or residual resources requiring follow-up.
