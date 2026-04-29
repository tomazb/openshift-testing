#!/usr/bin/env bash
# Shared helpers for OpenShift DNS validation automation.

set -Eeuo pipefail

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

warn() {
  log "WARN: $*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

confirm() {
  local prompt="$1"
  [[ "${AUTO_YES:-false}" == "true" ]] && return 0
  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

run() {
  log "+ $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

run_out() {
  local out="$1"
  shift
  log "+ $* > $out"
  set +e
  "$@" >"$out" 2>&1
  local rc=$?
  set -e
  echo "$rc" >"$out.rc"
  [[ $rc -eq 0 ]] || warn "rc=$rc for $*; see $out"
  # Always return 0: run_out is an artifact-capture helper; command exit
  # codes are persisted to $out.rc for callers that need them.
  return 0
}

init_dirs() {
  mkdir -p \
    "$ARTIFACT_DIR/00-preflight" \
    "$ARTIFACT_DIR/01-openshift-tests/junit" \
    "$ARTIFACT_DIR/02-node-sweep" \
    "$ARTIFACT_DIR/03-dnsperf" \
    "$ARTIFACT_DIR/04-perf-tests" \
    "$ARTIFACT_DIR/05-report" \
    "$ARTIFACT_DIR/tmp"
}

read_runtime() {
  [[ -f "$RUNTIME_ENV" ]] || return 0
  # shellcheck disable=SC1090
  source "$RUNTIME_ENV"
}

write_runtime_kv() {
  local key="$1" value="$2"
  mkdir -p "$(dirname "$RUNTIME_ENV")"
  if [[ -f "$RUNTIME_ENV" ]]; then
    grep -v "^${key}=" "$RUNTIME_ENV" >"$RUNTIME_ENV.tmp" || true
    mv "$RUNTIME_ENV.tmp" "$RUNTIME_ENV"
  fi
  printf '%s=%q\n' "$key" "$value" >>"$RUNTIME_ENV"
}

ensure_namespace() {
  oc get ns "$VALIDATION_NAMESPACE" >/dev/null 2>&1 || run oc create namespace "$VALIDATION_NAMESPACE"
}

ensure_tests() {
  [[ -x "$OPENSHIFT_TESTS_BIN" ]] || extract_tests
}

show_paths() {
  printf '\nArtifact directory:\n  %s\nRuntime file:\n  %s\nMain log:\n  %s\n\n' "$ARTIFACT_DIR" "$RUNTIME_ENV" "$LOG_FILE"
}
