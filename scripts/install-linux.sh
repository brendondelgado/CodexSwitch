#!/usr/bin/env bash
set -euo pipefail

INSTALLER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNTIME_OBSERVER_HELPER_ROOT="${CODEXSWITCH_RUNTIME_OBSERVER_HELPER_ROOT:-$INSTALLER_SCRIPT_DIR/lib}"
SYSTEMD_CONTRACT_MANIFEST="${CODEXSWITCH_SYSTEMD_CONTRACT_MANIFEST:-$INSTALLER_SCRIPT_DIR/manifests/linux-systemd-contract.tsv}"
REPO_URL="${CODEXSWITCH_REPO_URL:-https://github.com/brendondelgado/CodexSwitch.git}"
INSTALL_ROOT="${CODEXSWITCH_INSTALL_ROOT:-${CODEXSWITCH_INSTALL_DIR:-$HOME/.local/share/codexswitch}}"
SOURCE_DIR="${CODEXSWITCH_SOURCE_DIR:-$INSTALL_ROOT/source}"
BUILD_ROOT="${CODEXSWITCH_BUILD_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/codexswitch/build}"
BIN_DIR="${CODEXSWITCH_BIN_DIR:-$HOME/.local/bin}"
SERVICE_DIR="${CODEXSWITCH_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
CODEX_RUNTIME_DIR="${CODEXSWITCH_CODEX_RUNTIME_DIR:-$INSTALL_ROOT/patched-codex}"
RUNTIME_STORAGE_ROOT="${CODEXSWITCH_RUNTIME_STORAGE_ROOT:-${CODEX_HOME:-$HOME/.codex}}"
CODEX_VERSION="${CODEXSWITCH_CODEX_VERSION:-}"
CODEX_SOURCE_SHA="${CODEXSWITCH_CODEX_SOURCE_SHA:-}"
TARGET_SHA="${CODEXSWITCH_GIT_SHA:-}"
APPROVED_ORIGIN_REF="${CODEXSWITCH_APPROVED_ORIGIN_REF:-refs/remotes/origin/main}"
IMPORT_BUNDLE="${CODEXSWITCH_IMPORT_BUNDLE:-${1:-}}"
IMPORT_BUNDLE_SHA256="${CODEXSWITCH_IMPORT_BUNDLE_SHA256:-}"
ACCOUNT_STORE_PATH="${CODEXSWITCH_ACCOUNT_STORE_PATH:-$HOME/.codexswitch/accounts.json}"
AUTH_PATH="${CODEXSWITCH_AUTH_PATH:-$HOME/.codex/auth.json}"
BUILD_NICE="${CODEXSWITCH_BUILD_NICE:-10}"
BUILD_MEMORY_HIGH="${CODEXSWITCH_BUILD_MEMORY_HIGH:-4G}"
BUILD_MEMORY_MAX="${CODEXSWITCH_BUILD_MEMORY_MAX:-6G}"
BUILD_SWAP_MAX="${CODEXSWITCH_BUILD_SWAP_MAX:-2G}"
BUILD_TIMEOUT_SECONDS=600
TEST_BUILD_TIMEOUT_SECONDS="${CODEXSWITCH_TEST_BUILD_TIMEOUT_SECONDS:-}"
BUILD_MIN_FREE_BYTES="${CODEXSWITCH_BUILD_MIN_FREE_BYTES:-8589934592}"
BUILD_MAX_BYTES="${CODEXSWITCH_BUILD_MAX_BYTES:-12884901888}"
RELEASE_MAX_BYTES="${CODEXSWITCH_RELEASE_MAX_BYTES:-2147483648}"
RELEASE_RETENTION_MAX_COUNT="${CODEXSWITCH_RELEASE_RETENTION_MAX_COUNT:-5}"
RELEASE_RETENTION_MAX_AGE_DAYS="${CODEXSWITCH_RELEASE_RETENTION_MAX_AGE_DAYS:-30}"
RELEASE_RETENTION_MAX_BYTES="${CODEXSWITCH_RELEASE_RETENTION_MAX_BYTES:-8589934592}"
BUILD_RETENTION_MAX_COUNT="${CODEXSWITCH_BUILD_RETENTION_MAX_COUNT:-4}"
BUILD_RETENTION_MAX_AGE_HOURS="${CODEXSWITCH_BUILD_RETENTION_MAX_AGE_HOURS:-24}"
RUNTIME_STORAGE_MAX_COUNT="${CODEXSWITCH_RUNTIME_STORAGE_MAX_COUNT:-100000}"
RUNTIME_STORAGE_MAX_AGE_DAYS="${CODEXSWITCH_RUNTIME_STORAGE_MAX_AGE_DAYS:-3650}"
RUNTIME_STORAGE_MAX_BYTES="${CODEXSWITCH_RUNTIME_STORAGE_MAX_BYTES:-68719476736}"
SYSTEMD_TRANSACTION_MAX_COUNT="${CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_COUNT:-4}"
SYSTEMD_TRANSACTION_MAX_AGE_HOURS="${CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_AGE_HOURS:-24}"
SYSTEMD_TRANSACTION_MAX_BYTES="${CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_BYTES:-67108864}"
SCAN_MAX_ENTRIES="${CODEXSWITCH_SCAN_MAX_ENTRIES:-200000}"
SCAN_MAX_DEPTH="${CODEXSWITCH_SCAN_MAX_DEPTH:-64}"
SCAN_MAX_BYTES="${CODEXSWITCH_SCAN_MAX_BYTES:-137438953472}"
STATE_FILE_MAX_BYTES="${CODEXSWITCH_STATE_FILE_MAX_BYTES:-1048576}"
RUNTIME_OBSERVATION_TIMEOUT_SECONDS="${CODEXSWITCH_RUNTIME_OBSERVATION_TIMEOUT_SECONDS:-15}"
PROC_ROOT="${CODEXSWITCH_PROC_ROOT:-/proc}"
DRY_RUN="${CODEXSWITCH_DRY_RUN:-0}"
ACTIVATE="${CODEXSWITCH_ACTIVATE:-0}"
INSTALL_SYSTEMD="${CODEXSWITCH_INSTALL_SYSTEMD:-1}"
APPROVE_SYSTEMD_CONFLICTS="${CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS:-0}"
ENABLE_DAEMON="${CODEXSWITCH_ENABLE_DAEMON:-0}"
START_DAEMON="${CODEXSWITCH_START_DAEMON:-0}"
ENABLE_APP_SERVER="${CODEXSWITCH_ENABLE_APP_SERVER:-0}"
START_APP_SERVER="${CODEXSWITCH_START_APP_SERVER:-0}"
TEST_MODE="${CODEXSWITCH_TEST_MODE:-0}"
TEST_FAULT_POINT="${CODEXSWITCH_TEST_FAULT_POINT:-}"
TEST_FAULT_MODE="${CODEXSWITCH_TEST_FAULT_MODE:-fail}"
TEST_PROCESS_START_IDENTITY="${CODEXSWITCH_TEST_PROCESS_START_IDENTITY:-}"
TEST_CONCURRENT_START="${CODEXSWITCH_TEST_CONCURRENT_START:-0}"
TEST_CONCURRENT_DAEMON_START="${CODEXSWITCH_TEST_CONCURRENT_DAEMON_START:-0}"
MANAGED_APP_SERVER_UNIT="signul-codex-app-server.service"

RELEASES_DIR=""
CURRENT_LINK=""
PREVIOUS_LINK=""
ACTIVATION_LOCK_FILE=""
ACTIVATION_JOURNAL=""
RUNTIME_START_INSTALL_GUARD=""
DAEMON_RESERVATION_GUARD=""
SYSTEMD_TRANSACTION_DIR=""
CARGO_TARGET_ROOT=""
CARGO_TARGET_DIR_PATH=""
WORKTREE_ROOT=""
BUILD_STAGE_ROOT=""
BUILD_LOCK_DIR=""
BUILD_LOCK_TOKEN=""
TRANSACTION_OWNER_KEY=""
WORK_DIR=""
WORKTREE_REGISTERED=0
STAGE_DIR=""
PUBLISH_DIR=""
ACTIVATION_LOCK_HELD=0
ACTIVATION_LOCK_TOKEN=""
ACTIVATION_TRANSACTION_ACTIVE=0
RUNTIME_GUARDS_HELD=0
TEST_START_GUARD_HELD=0
TEST_DAEMON_GUARD_HELD=0
BUILD_LOCK_HELD=0
BUILD_DESCENDANTS_REAPED=1
BUILD_REAP_PROOF=""
PACKAGE_VERSION=""
BUILD_EPOCH=""
RELEASE_ID=""
RELEASE_DIR=""
EXPECTED_CLI_VERSION=""
RELEASE_PUBLISHED_THIS_RUN=0
HOME_ROOT=""
IMPORT_BUNDLE_STAGED=""
IMPORT_ACTIVATION_BARRIER_IDENTITY=""
IMPORT_BARRIER_CONVERGED=0

# shellcheck source=lib/install-linux-common.sh
source "$INSTALLER_SCRIPT_DIR/lib/install-linux-common.sh"
# shellcheck source=lib/install-linux-storage.sh
source "$INSTALLER_SCRIPT_DIR/lib/install-linux-storage.sh"
# shellcheck source=lib/install-linux-release.sh
source "$INSTALLER_SCRIPT_DIR/lib/install-linux-release.sh"
# shellcheck source=lib/install-linux-activation-journal.sh
source "$INSTALLER_SCRIPT_DIR/lib/install-linux-activation-journal.sh"
# shellcheck source=lib/install-linux-systemd-policy.sh
source "$INSTALLER_SCRIPT_DIR/lib/install-linux-systemd-policy.sh"
# shellcheck source=lib/install-linux-import-transaction.sh
source "$INSTALLER_SCRIPT_DIR/lib/install-linux-import-transaction.sh"
# shellcheck source=lib/install-linux-systemd-transaction.sh
source "$INSTALLER_SCRIPT_DIR/lib/install-linux-systemd-transaction.sh"
# shellcheck source=lib/install-linux-activation.sh
source "$INSTALLER_SCRIPT_DIR/lib/install-linux-activation.sh"

trap cleanup EXIT
need_cmd git
need_cmd python3
validate_configuration
validate_source_destination
enforce_runtime_storage_bounds

if [[ "$DRY_RUN" == "1" ]]; then
  print_dry_run
  exit 0
fi

need_cmd awk
need_cmd cargo
need_cmd cp
need_cmd du
need_cmd find
need_cmd flock
need_cmd grep
need_cmd install
need_cmd ionice
need_cmd ln
need_cmd mv
need_cmd nice
need_cmd paste
need_cmd sed
need_cmd sort
need_cmd systemd-run
need_cmd timeout
if ! command -v sha256sum >/dev/null 2>&1; then
  need_cmd shasum
fi
validate_import_bundle_digest
if [[ "$ACTIVATE" == "1" ]]; then
  need_cmd systemctl
fi

mkdir -p "$INSTALL_ROOT"
acquire_build_lock
preflight_storage
if [[ "$ACTIVATE" == "1" ]]; then
  acquire_activation_lock
fi
validate_release_pointers_for_retention
prepare_source_worktree
publish_release
enforce_release_retention

if [[ "$ACTIVATE" == "1" ]]; then
  activate_release
  run_transaction_actions
  inject_fault after_actions
  commit_activation_transaction
  run_requested_starts
  if [[ -n "$IMPORT_BUNDLE" && "$IMPORT_BARRIER_CONVERGED" == "1" ]]; then
    echo "CodexSwitch release activated with confirmed import convergence: $RELEASE_DIR"
  else
    echo "CodexSwitch release activated: $RELEASE_DIR"
    if [[ -n "$IMPORT_BUNDLE" ]]; then
      echo "CodexSwitch import prepared offline file-only; runtime convergence remains pending."
    fi
  fi
else
  echo "CodexSwitch release staged and validated without activation: $RELEASE_DIR"
fi

cat <<EOF
Release manifest:
  $RELEASE_DIR/release-manifest.tsv

Current and public CLI pointers were changed only when CODEXSWITCH_ACTIVATE=1.
No service was stopped or restarted. Enablement and post-commit starts require
their separate explicit flags.
EOF
