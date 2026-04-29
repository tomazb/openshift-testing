#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

test_scripts=(tests/*.sh)

bash -n dns-validation/bin/ocp-dns-validate
bash -n dns-validation/lib/common.sh
bash -n dns-validation/lib/cluster.sh
bash -n dns-validation/lib/perf.sh
bash -n dns-validation/lib/results.sh
bash -n scripts/check-static.sh
for test_script in "${test_scripts[@]}"; do
  bash -n "$test_script"
done

for test_script in "${test_scripts[@]}"; do
  bash "$test_script"
done

shellcheck -x \
  dns-validation/bin/ocp-dns-validate \
  dns-validation/lib/common.sh \
  dns-validation/lib/cluster.sh \
  dns-validation/lib/perf.sh \
  dns-validation/lib/results.sh \
  scripts/check-static.sh \
  "${test_scripts[@]}"

# shellcheck disable=SC2016
if ! grep -Fq 'source "$PROJECT_DIR/lib/results.sh"' dns-validation/bin/ocp-dns-validate; then
  echo "ocp-dns-validate must source dns-validation/lib/results.sh" >&2
  exit 1
fi

if rg -n '^(results_|render_)' dns-validation/lib/perf.sh >/dev/null; then
  echo "result parsing/rendering helpers belong in dns-validation/lib/results.sh" >&2
  rg -n '^(results_|render_)' dns-validation/lib/perf.sh >&2
  exit 1
fi

if grep -q 'DNSPERF_IMAGE=".*:latest"' dns-validation/config/validation.env.example; then
  echo "validation.env.example must not use a floating DNSPERF_IMAGE tag" >&2
  exit 1
fi

if grep -q 'DNSPERF_IMAGE="docker.io/guessi/dnsperf:2.14.0"' dns-validation/config/validation.env.example; then
  echo "validation.env.example must not use the unavailable docker.io/guessi/dnsperf:2.14.0 tag" >&2
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

legacy_shellcheck_node_sweep_command="sh -c 'nslookup \"kubernetes.default.svc.\$1\""
if grep -Fq "$legacy_shellcheck_node_sweep_command" dns-validation/lib/cluster.sh; then
  echo "node sweep sh -c command must avoid ShellCheck 0.9 SC2016 on the intentional \$1 argument" >&2
  exit 1
fi

if ! grep -Fq '````markdown' docs/superpowers/plans/2026-04-29-dns-validation-mvp-implementation.md; then
  echo "implementation plan markdown examples with nested fences must use an outer quadruple fence" >&2
  exit 1
fi

git diff --check
