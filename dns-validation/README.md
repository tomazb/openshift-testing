# OpenShift DNS Validation Automation

This directory contains a text-fronted automation wrapper for DNS-focused post-install validation of a newly built OpenShift cluster.

It covers three validation layers:

1. **Correctness** using release-matched `openshift-tests` DNS conformance subsets.
2. **Node coverage** using a DaemonSet-based DNS smoke sweep.
3. **Performance** using direct `dnsperf` QPS ladders against the OpenShift cluster DNS service IP, plus an optional `kubernetes/perf-tests/dns` profile.

## Quick start

```bash
cd dns-validation
cp config/validation.env.example config/validation.env
vi config/validation.env

bash bin/ocp-dns-validate --config config/validation.env menu
```

The text frontend exposes the validation steps in a controlled order:

```text
1) Init/check local tools
2) Preflight cluster + DNS baseline
3) Extract release-matched openshift-tests
4) Discover DNS conformance tests
5) Run DNS conformance subset
6) Run one openshift-tests test by full name
7) Node-level DNS sweep
8) Generate dnsperf query file
9) Run direct dnsperf QPS ladder
10) Run optional kubernetes/perf-tests/dns quick profile
11) Generate markdown report
12) Cleanup validation namespace
13) Run recommended sequence
14) Show artifact paths
```

## Non-interactive run

```bash
cd dns-validation
bash bin/ocp-dns-validate --config config/validation.env all
```

Individual steps are also available:

```bash
bash bin/ocp-dns-validate preflight
bash bin/ocp-dns-validate extract-tests
bash bin/ocp-dns-validate discover-dns-tests
bash bin/ocp-dns-validate run-dns-tests
bash bin/ocp-dns-validate node-sweep
bash bin/ocp-dns-validate generate-queries
bash bin/ocp-dns-validate dnsperf
bash bin/ocp-dns-validate perf-tests
bash bin/ocp-dns-validate report
```

If you clone the repo locally and want direct execution, run:

```bash
chmod +x bin/ocp-dns-validate
./bin/ocp-dns-validate --config config/validation.env menu
```

## Required access

- `oc` authenticated to the target cluster.
- Cluster-admin or equivalent privileges for conformance tests and temporary namespace workloads.
- Pull secret if the release tests image requires authentication.
- A dnsperf image available to the cluster.

## Important configuration

Review `config/validation.env.example` before running.

For lab use the sample public `DNSPERF_IMAGE` may be acceptable. For customer or regulated environments, replace it with an internally approved and pinned image.

```bash
DNSPERF_IMAGE="registry.example.com/tools/dnsperf:2.x-pinned"
DNSPERF_QPS_STEPS="100 500 1000 2000"
DNSPERF_DURATION_SECONDS="60"
```

## Artifacts

Each run writes artifacts under `runs/<timestamp>/` unless `ARTIFACT_DIR` is explicitly configured.

```text
runs/<timestamp>/
  00-preflight/
  01-openshift-tests/
  02-node-sweep/
  03-dnsperf/
  04-perf-tests/
  05-report/
  ocp-dns-validate.log
  runtime.env
```

The generated report is:

```text
runs/<timestamp>/05-report/dns-validation-report.md
```

## Design choices

- `openshift-tests` is extracted from the cluster release image to avoid version mismatch.
- The automation reads OpenShift DNS IP from `dns.operator/default.status.clusterIP`.
- Direct `dnsperf` is the preferred day-1 DNS performance path because it targets the OpenShift cluster DNS service directly.
- `kubernetes/perf-tests/dns` remains optional because it is Kubernetes-generic and can be more sensitive to image, SCC, and service-layout assumptions.

## Cleanup

```bash
bash bin/ocp-dns-validate cleanup
```

This deletes only the configured validation namespace. It does not delete `openshift-tests` e2e namespaces that may have been intentionally preserved for debugging.
