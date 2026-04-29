# OpenShift Testing

Automation and runbooks for validating OpenShift clusters after build or during day-2 testing.

## Available validation packs

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
