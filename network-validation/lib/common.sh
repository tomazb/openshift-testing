#!/usr/bin/env bash
# Shared helpers for OpenShift network validation automation.

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

run_capture() {
  local out="$1"
  local rc_file="$2"
  local rc
  shift 2

  ( set +e; "$@" >"$out" 2>&1; printf '%s\n' "$?" >"$rc_file" )
  rc="$(tr -d '[:space:]' <"$rc_file" 2>/dev/null || true)"
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
  return "$rc"
}

run_out_checked() {
  local out="$1"
  local rc=0
  shift
  log "+ $* > $out"
  run_capture "$out" "$out.rc" "$@" || rc=$?
  [[ $rc -eq 0 ]] || warn "rc=$rc for $*; see $out"
  return "$rc"
}

run_out() {
  local out="$1"
  shift
  run_out_checked "$out" "$@" || true
  return 0
}

init_dirs() {
  mkdir -p \
    "$ARTIFACT_DIR/00-preflight" \
    "$ARTIFACT_DIR/01-cross-node" \
    "$ARTIFACT_DIR/02-same-node" \
    "$ARTIFACT_DIR/03-host-network" \
    "$ARTIFACT_DIR/04-pod-to-service" \
    "$ARTIFACT_DIR/05-ovn-diagnostics" \
    "$ARTIFACT_DIR/06-report" \
    "$ARTIFACT_DIR/tmp"
}

read_runtime() {
  [[ -f "$RUNTIME_ENV" ]] || return 0
  # shellcheck disable=SC1090
  source "$RUNTIME_ENV"
}

write_runtime_kv() {
  local key="$1" value="$2"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "Invalid runtime key: $key"
  mkdir -p "$(dirname "$RUNTIME_ENV")"
  if [[ -f "$RUNTIME_ENV" ]]; then
    grep -v "^${key}=" "$RUNTIME_ENV" >"$RUNTIME_ENV.tmp" || true
    mv "$RUNTIME_ENV.tmp" "$RUNTIME_ENV"
  fi
  printf '%s=%q\n' "$key" "$value" >>"$RUNTIME_ENV"
}

runtime_key_prefix() {
  local value="$1"
  printf '%s\n' "$value" | tr '[:lower:]-' '[:upper:]_'
}

ensure_namespace() {
  oc get ns "$IPERF_NAMESPACE" >/dev/null 2>&1 || run oc create namespace "$IPERF_NAMESPACE"
}

show_paths() {
  printf '\nArtifact directory:\n  %s\nRuntime file:\n  %s\nMain log:\n  %s\n\n' "$ARTIFACT_DIR" "$RUNTIME_ENV" "$LOG_FILE"
}

results_read_artifact_rc() {
  local file="$1"
  if [[ -s "$file" ]]; then
    tr -d '[:space:]' <"$file"
  else
    echo "not run"
  fi
}
