# OpenShift Testing

Automation and runbooks for validating OpenShift clusters after build or during day-2 testing.

## Available validation packs

### Network testing image

The `network-testing-image/` directory defines a UBI9-based troubleshooting image with OpenShift and Kubernetes clients, bash completion, DNS tools, packet and route inspection tools, throughput benchmarks, transfer utilities, S3 mount tooling, JSON/YAML helpers, TLS and certificate tooling, storage device tooling, and `fio` storage-performance testing. GitHub Actions builds and smoke-tests it on pull requests, then publishes it to GitHub Container Registry after changes land on `main`.

Pull the latest published image with:

```bash
podman pull ghcr.io/tomazb/openshift-testing/network-testing-image:latest
```

Published tags include `latest`, `main`, `sha-<commit>`, and `network-testing-image-v*` release tags.

The image uses UBI9 repositories first, enables EPEL9 for `netperf`, `qperf`, and `s3fs-fuse`, and source-builds `iperf3` and `fio` from their official release tarballs with pinned SHA-256 checksums. `iperf3` is built from source (currently 3.21) rather than installed from UBI9 repos (which only provides the outdated 3.9) to gain modern performance features including parallel stream improvements, zero-copy sendfile, and GSO/GRO support. External standalone tools such as `rclone`, `oc`, `kubectl`, `step`, and `yq` are version-pinned and verified during the build.

Some tools need extra pod permissions to be useful. Packet capture, low-level interface inspection, and `s3fs` mounts may require capabilities, device access, privileged security context settings, or cluster policy changes outside the image itself.

Tools that are not available from the configured UBI9 and EPEL9 repositories are intentionally deferred rather than added through weak package sources. Deferred tools currently include `whois` and `tshark`.

### DNS validation

The `dns-validation/` directory contains a text-fronted automation wrapper for DNS-focused post-install validation:

- release-matched `openshift-tests` DNS conformance subset
- node-level DNS sweep using a DaemonSet
- direct dnsperf QPS ladder against OpenShift cluster DNS
- optional kubernetes/perf-tests/dns quick profile
- structured `Accepted`, `Accepted with risks`, or `Blocked` verdicts
- lightweight and failure-triggered DNS diagnostics
- markdown report generation

See `dns-validation/README.md` for usage instructions.

### Network validation

The `network-validation/` directory contains an iperf3-based network throughput validation tool for OpenShift clusters with CoreOS nodes:

- automated iperf3 server/client pod deployment on selected nodes
- topology-aware test scenarios: cross-node, same-node, host-network, pod-to-service
- CoreOS-compatible server/client artifact and metric collection via a mounted pod-side collector
- dedicated deep node-level metrics collection
- OVN-Kubernetes diagnostics capture with OpenShift-version-aware pod/container discovery
- structured `Accepted`, `Accepted with risks`, or `Blocked` verdicts
- markdown report generation

See `network-validation/README.md` for usage instructions.

### Cluster validator

The `cluster-validator/` directory packages the DNS and network validators into
one container image and a set of Kubernetes Job manifests. It lets an operator
apply the required namespaces/RBAC once, then run either validator in-cluster
without a local validation workstation.

See `cluster-validator/README.md` for install and Job usage instructions.

## Planning docs

Current design and implementation plans live under `docs/plans/`, including the approved `cluster-validator` plan for packaging DNS and network validation as in-cluster Kubernetes Jobs.
