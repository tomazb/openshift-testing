#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

bash -n dns-validation/bin/ocp-dns-validate
bash -n dns-validation/lib/common.sh
bash -n dns-validation/lib/cluster.sh
bash -n dns-validation/lib/perf.sh
bash -n scripts/check-static.sh
bash -n tests/extract-tests-empty-target.sh

bash tests/extract-tests-empty-target.sh

shellcheck -x \
  dns-validation/bin/ocp-dns-validate \
  dns-validation/lib/common.sh \
  dns-validation/lib/cluster.sh \
  dns-validation/lib/perf.sh \
  scripts/check-static.sh \
  tests/extract-tests-empty-target.sh

if grep -q 'DNSPERF_IMAGE=".*:latest"' dns-validation/config/validation.env.example; then
  echo "validation.env.example must not use a floating DNSPERF_IMAGE tag" >&2
  exit 1
fi

if grep -q 'PERF_TESTS_REF="master"' dns-validation/config/validation.env.example; then
  echo "validation.env.example must pin PERF_TESTS_REF" >&2
  exit 1
fi

if ! grep -Fq 'delete pod/dnsperf configmap/dnsperf-queries' dns-validation/lib/perf.sh; then
  echo "dnsperf cleanup must delete pod/dnsperf and configmap/dnsperf-queries explicitly" >&2
  exit 1
fi

# shellcheck disable=SC2016
bad_node_sweep_command='sh -c "nslookup kubernetes.default.svc.${domain}'
if grep -Fq "$bad_node_sweep_command" dns-validation/lib/cluster.sh; then
  echo "node sweep must pass domain to sh -c as an argument, not interpolate it" >&2
  exit 1
fi

git diff --check
