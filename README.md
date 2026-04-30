# OpenShift Testing

Automation and runbooks for validating OpenShift clusters after build or during day-2 testing.

## Available validation packs

### Network testing image

The `network-testing-image/` directory defines a UBI9-based troubleshooting image with OpenShift and Kubernetes clients, bash completion, DNS tools, packet and route inspection tools, throughput benchmarks, transfer utilities, JSON/YAML helpers, TLS and certificate tooling, and storage device tooling. GitHub Actions builds and smoke-tests it on pull requests, then publishes it to GitHub Container Registry after changes land on `main`.

Pull the latest published image with:

```bash
podman pull ghcr.io/tomazb/openshift-testing/network-testing-image:latest
```

Published tags include `latest`, `main`, `sha-<commit>`, and `network-testing-image-v*` release tags.

Some tools need extra pod permissions to be useful. Packet capture and low-level interface inspection may require capabilities, device access, privileged security context settings, or cluster policy changes outside the image itself.

Tools that are not available from the configured UBI9 repositories are intentionally deferred rather than added through broad third-party repositories. Deferred tools currently include `whois`, `netperf`, `qperf`, `tshark`, `s3fs`, and `fio`.

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
