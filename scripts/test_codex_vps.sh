#!/usr/bin/env zsh
set -eu
setopt PIPE_FAIL

ROOT="${0:A:h:h}"
SCRIPT="${ROOT}/scripts/codex-vps"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-vps-check.XXXXXX")"
EVENTS="${TEST_ROOT}/events"
BIN_DIR="${TEST_ROOT}/bin"
LOCAL_CLIENT_FIXTURE="${BIN_DIR}/codex-local"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM HUP

fail() {
  print -u2 -r -- "test_codex_vps: $*"
  return 1
}

assert_contains() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "missing expected output: ${expected}"
}

assert_status() {
  local actual="$1"
  local expected="$2"
  [[ "$actual" = "$expected" ]] || fail "expected status ${expected}, got ${actual}"
}

assert_no_events() {
  if [[ -s "$EVENTS" ]]; then
    fail "observational command invoked: $(tr '\n' ' ' < "$EVENTS")"
  fi
}

write_executable() {
  local target="$1"
  local body="$2"
  print -r -- "$body" > "$target"
  chmod 700 "$target"
}

mkdir -p "$BIN_DIR" "${TEST_ROOT}/home"
: > "$EVENTS"

write_executable "$LOCAL_CLIENT_FIXTURE" '#!/usr/bin/env zsh
print -r -- "codex-cli 0.144.1"'

write_executable "${BIN_DIR}/npm" '#!/usr/bin/env zsh
print -r -- "npm $*" >> "$CODEX_VPS_TEST_EVENTS"
exit 97'

export HOME="${TEST_ROOT}/home"
export PATH="${BIN_DIR}:/usr/bin:/bin:/usr/sbin:/sbin"
export CODEX_VPS_SOURCE_ONLY=1
export CODEX_VPS_TEST_EVENTS="$EVENTS"
source "$SCRIPT"

NPM_REMOTE_CLIENT="${TEST_ROOT}/missing-npm-client"
APP_BUNDLED_CLIENT="${TEST_ROOT}/missing-app-client"
PATCHED_REMOTE_CLIENT="$LOCAL_CLIENT_FIXTURE"
LOCAL_CLIENT="$LOCAL_CLIENT_FIXTURE"

direct_tailscale_app_server_available() {
  return 0
}

remote_codex_version() {
  print -r -- "0.144.3"
}

set +e
unscoped_sync_output="$(sync_local_remote_client 2>&1)"
unscoped_sync_status=$?
set -e

assert_status "$unscoped_sync_status" 2
assert_contains "$unscoped_sync_output" \
  "client synchronization is only available through 'codex-vps sync-client'"
assert_no_events

mutation_tripwire() {
  print -r -- "$1" >> "$EVENTS"
  return 97
}

sync_local_remote_client() {
  mutation_tripwire sync_local_remote_client
}

ensure_local_remote_client() {
  mutation_tripwire ensure_local_remote_client
}

ensure_local_remote_client_for_direct() {
  mutation_tripwire ensure_local_remote_client_for_direct
}

ensure_tunnel() {
  mutation_tripwire ensure_tunnel
}

start_tunnel_supervisor_for_interactive_attach() {
  mutation_tripwire start_tunnel_supervisor_for_interactive_attach
}

restart_remote_codex() {
  mutation_tripwire restart_remote_codex
}

persist_default_thread_id() {
  mutation_tripwire persist_default_thread_id
}

ssh_remote() {
  mutation_tripwire "ssh_remote:$*"
}

set +e
check_output="$(codex_vps_main --check 2>&1)"
check_status=$?
set -e

assert_status "$check_status" 1
assert_contains "$check_output" \
  "local remote client 0.144.1 does not match remote 0.144.3"
assert_contains "$check_output" \
  "run 'codex-vps sync-client' to install the matching client explicitly"
assert_no_events

help_output="$(codex_vps_main --help 2>&1)"
assert_contains "$help_output" \
  "codex-vps sync-client  explicitly install the matching Mac remote client"
assert_no_events

sync_local_remote_client() {
  print -r -- "sync_local_remote_client:${1:-missing}" >> "$EVENTS"
}

codex_vps_main sync-client >/dev/null 2>&1
sync_events="$(<"$EVENTS")"
[[ "$sync_events" = "sync_local_remote_client:sync-client" ]] || \
  fail "sync-client did not exclusively invoke its named mutation: ${sync_events}"

print -r -- "test_codex_vps: PASS"
