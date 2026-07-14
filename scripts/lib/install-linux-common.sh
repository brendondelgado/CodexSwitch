# shellcheck shell=bash
managed_systemd_entries() {
  printf '%s\n' \
    "codexswitch.service" \
    "codexswitch.service.d" \
    "signul-codex-app-server.service" \
    "signul-codex-app-server.service.d" \
    "codexswitch-knowledge-sync.service" \
    "codexswitch-knowledge-sync.service.d" \
    "codexswitch-knowledge-sync.timer" \
    "codexswitch-knowledge-sync.timer.d" \
    "codexswitch-daemon.service" \
    "codexswitch-daemon.service.d" \
    "codexswitch-app-server.service" \
    "codexswitch-app-server.service.d" \
    "codexswitch-app-server-proxy.service" \
    "codexswitch-app-server-proxy.service.d" \
    "codex-app-server.service" \
    "codex-app-server.service.d" \
    "codex-app-server-daemon.service" \
    "codex-app-server-daemon.service.d" \
    "codex-app-server-control.service" \
    "codex-app-server-control.service.d" \
    "default.target.wants/codexswitch.service" \
    "default.target.wants/signul-codex-app-server.service" \
    "default.target.wants/codexswitch-knowledge-sync.service" \
    "default.target.wants/codexswitch-knowledge-sync.timer" \
    "timers.target.wants/codexswitch-knowledge-sync.timer" \
    "default.target.wants/codexswitch-daemon.service" \
    "default.target.wants/codexswitch-app-server.service" \
    "default.target.wants/codexswitch-app-server-proxy.service" \
    "default.target.wants/codex-app-server.service" \
    "default.target.wants/codex-app-server-daemon.service" \
    "default.target.wants/codex-app-server-control.service"
}

systemd_entry_is_managed() {
  local wanted="$1"
  local entry=""
  local dropin_count=0

  while IFS= read -r entry; do
    [[ "$entry" != "$wanted" ]] || return 0
  done < <(managed_systemd_entries)
  return 1
}

legacy_systemd_units() {
  printf '%s\n' \
    "codexswitch-knowledge-sync.service" \
    "codexswitch-knowledge-sync.timer" \
    "codexswitch-daemon.service" \
    "codexswitch-app-server.service" \
    "codexswitch-app-server-proxy.service" \
    "codex-app-server.service" \
    "codex-app-server-daemon.service" \
    "codex-app-server-control.service" \
    "codexswitch.socket" \
    "codexswitch.path" \
    "signul-codex-app-server.socket" \
    "signul-codex-app-server.path" \
    "codexswitch-app-server.socket" \
    "codexswitch-app-server.path" \
    "codex-app-server.socket" \
    "codex-app-server.path"
}

activation_blocking_systemd_units() {
  python3 - "$SYSTEMD_CONTRACT_MANIFEST" "$STATE_FILE_MAX_BYTES" <<'PY'
import os
import re
import stat
import sys

path = sys.argv[1]
limit = int(sys.argv[2])
before = os.lstat(path)
if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode) or before.st_size > limit:
    raise SystemExit("systemd start barrier manifest is unsafe")
descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
        raise SystemExit("systemd start barrier manifest changed identity")
    data = b""
    while len(data) <= limit:
        chunk = os.read(descriptor, min(65536, limit - len(data) + 1))
        if not chunk:
            break
        data += chunk
finally:
    os.close(descriptor)
if len(data) > limit:
    raise SystemExit("systemd start barrier manifest exceeds its read bound")
units = []
pattern = re.compile(r"start-barrier:([A-Za-z0-9_.@-]+\.(?:service|socket|path|timer)):Required")
for line in data.decode("utf-8").splitlines():
    fields = line.split("\t", 1)
    if len(fields) != 2:
        continue
    match = pattern.fullmatch(fields[0])
    if match is not None and fields[1] == "1":
        units.append(match.group(1))
if len(units) != len(set(units)) or units[:2] != [
    "codexswitch.service",
    "signul-codex-app-server.service",
] or len(units) < 3:
    raise SystemExit("systemd start barrier manifest is incomplete or duplicated")
print("\n".join(units))
PY
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer is for Linux devboxes. On macOS, build/run the CodexSwitch app instead." >&2
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_flag() {
  local name="$1"
  local value="$2"
  case "$value" in
    0|1) ;;
    *) fail "$name must be 0 or 1" ;;
  esac
}

reject_parent_component() {
  local name="$1"
  local value="$2"
  case "/$value/" in
    *"/../"*) fail "$name must not contain a .. path component: $value" ;;
  esac
}

canonicalize_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

require_safe_path() {
  local name="$1"
  local value="$2"
  [[ "$value" == /* ]] || fail "$name must be an absolute path: $value"
  [[ "$value" != "/" ]] || fail "$name must not be /"
  reject_parent_component "$name" "$value"
}

paths_overlap() {
  local left="$1"
  local right="$2"
  [[ "$left" == "$right" || "$left" == "$right/"* || "$right" == "$left/"* ]]
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer"
}

require_reviewed_runtime_provenance() {
  [[ -n "$CODEX_VERSION" ]] || fail "CODEXSWITCH_CODEX_VERSION is required to reuse or activate a release"
  [[ "$CODEX_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || fail "CODEXSWITCH_CODEX_VERSION contains unsafe characters"
  [[ -n "$CODEX_SOURCE_SHA" ]] || fail "CODEXSWITCH_CODEX_SOURCE_SHA is required to reuse or activate a release"
  [[ "$CODEX_SOURCE_SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail "CODEXSWITCH_CODEX_SOURCE_SHA must be a full lowercase 40- or 64-character Git SHA"
}

validate_derived_path() {
  local label="$1"
  local root="$2"
  local path="$3"
  local canonical=""

  reject_parent_component "$label" "$path"
  [[ "$path" == "$root/"* && "$path" != "$root" ]] || fail "$label must remain below $root: $path"
  canonical="$(canonicalize_path "$path")"
  [[ "$canonical" == "$path" ]] || fail "$label resolves through a symlink or alias: $path -> $canonical"
  [[ ! -L "$path" ]] || fail "$label must not be a symlink: $path"
}

validate_derived_parent_path() {
  local label="$1"
  local root="$2"
  local path="$3"
  local parent=""
  local canonical_parent=""

  reject_parent_component "$label" "$path"
  [[ "$path" == "$root/"* && "$path" != "$root" ]] || fail "$label must remain below $root: $path"
  parent="$(dirname "$path")"
  canonical_parent="$(canonicalize_path "$parent")"
  [[ "$canonical_parent" == "$parent" ]] || fail "$label parent resolves through a symlink or alias: $parent -> $canonical_parent"
}

validate_private_mutation_path() {
  local label="$1"
  local path="$2"
  local parent=""
  local canonical_parent=""

  require_safe_path "$label" "$path"
  [[ ! -L "$path" ]] || fail "$label must not be a symlink: $path"
  parent="$(dirname "$path")"
  canonical_parent="$(canonicalize_path "$parent")"
  [[ "$canonical_parent" == "$parent" ]] || fail "$label parent resolves through a symlink or alias: $parent -> $canonical_parent"
  [[ "$path" == "$HOME_ROOT/"* ]] || fail "$label must remain below HOME: $path"
}

validate_build_derived_path() {
  local label="$1"
  local path="$2"
  local live_path=""

  validate_derived_path "$label" "$BUILD_ROOT" "$path"
  for live_path in "$INSTALL_ROOT" "$SOURCE_DIR" "$BIN_DIR" "$SERVICE_DIR" "$CODEX_RUNTIME_DIR" "$RUNTIME_STORAGE_ROOT" "$RELEASES_DIR"; do
    paths_overlap "$path" "$live_path" && fail "$label overlaps live path: $path <-> $live_path"
  done
  return 0
}

directory_is_nonempty() {
  [[ -d "$1" ]] && [[ -n "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

is_git_worktree() {
  [[ -d "$1" ]] && [[ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]]
}

sha256_file() {
  python3 - "$1" "$SCAN_MAX_BYTES" <<'PY'
import hashlib
import os
import stat
import sys

path = sys.argv[1]
max_bytes = int(sys.argv[2])
before = os.lstat(path)
if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
    raise SystemExit(f"hash source is linked or special: {path}")
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    opened = os.fstat(fd)
    if (opened.st_dev, opened.st_ino, opened.st_mode) != (
        before.st_dev,
        before.st_ino,
        before.st_mode,
    ):
        raise SystemExit(f"hash source changed identity: {path}")
    digest = hashlib.sha256()
    consumed = 0
    while True:
        chunk = os.read(fd, min(1024 * 1024, max_bytes - consumed + 1))
        if not chunk:
            break
        consumed += len(chunk)
        if consumed > max_bytes:
            raise SystemExit(f"hash source exceeds scan byte bound: {path}")
        digest.update(chunk)
    print(digest.hexdigest())
finally:
    os.close(fd)
PY
}

validate_import_bundle_digest() {
  [[ -n "$IMPORT_BUNDLE" ]] || return 0
  [[ "$(sha256_file "$IMPORT_BUNDLE")" == "$IMPORT_BUNDLE_SHA256" ]] || fail "CODEXSWITCH_IMPORT_BUNDLE SHA-256 mismatch: $IMPORT_BUNDLE"
}

manifest_value() {
  local manifest="$1"
  local key="$2"
  python3 - "$manifest" "$key" "$STATE_FILE_MAX_BYTES" <<'PY'
import os
import stat
import sys

path, wanted, limit_text = sys.argv[1:]
limit = int(limit_text)
before = os.lstat(path)
if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
    raise SystemExit(1)
if before.st_size > limit:
    raise SystemExit(f"bounded state file exceeds limit: {path}")
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    opened = os.fstat(fd)
    if (opened.st_dev, opened.st_ino, opened.st_mode) != (
        before.st_dev,
        before.st_ino,
        before.st_mode,
    ):
        raise SystemExit(f"bounded state file changed identity: {path}")
    data = b""
    while True:
        chunk = os.read(fd, min(65536, limit - len(data) + 1))
        if not chunk:
            break
        data += chunk
        if len(data) > limit:
            raise SystemExit(f"bounded state file exceeds limit: {path}")
finally:
    os.close(fd)
matches = []
for line in data.decode("utf-8").splitlines():
    fields = line.split("\t", 1)
    if len(fields) == 2 and fields[0] == wanted:
        matches.append(fields[1])
if len(matches) != 1:
    raise SystemExit(1)
print(matches[0])
PY
}

process_start_identity() {
  if [[ "$TEST_MODE" == "1" && "$1" == "$$" && -n "$TEST_PROCESS_START_IDENTITY" ]]; then
    printf '%s\n' "$TEST_PROCESS_START_IDENTITY"
    return 0
  fi
  python3 - "$PROC_ROOT" "$1" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1]) / sys.argv[2] / "stat"
try:
    value = path.read_text(encoding="utf-8")
except (FileNotFoundError, PermissionError, OSError):
    print("UNKNOWN")
else:
    fields = value[value.rfind(")") + 2 :].split()
    print(fields[19] if len(fields) > 19 else "UNKNOWN")
PY
}

observe_managed_systemd_owner() {
  python3 "$RUNTIME_OBSERVER_HELPER_ROOT/observe-managed-systemd.py" \
    "$MANAGED_APP_SERVER_UNIT" \
    "$SERVICE_DIR/$MANAGED_APP_SERVER_UNIT" \
    "$RUNTIME_OBSERVATION_TIMEOUT_SECONDS" \
    "$STATE_FILE_MAX_BYTES" \
    /usr/bin/flock --shared --no-fork \
    "$RUNTIME_START_INSTALL_GUARD" \
    /usr/bin/flock --exclusive --nonblock --no-fork \
    "$DAEMON_RESERVATION_GUARD" \
    "$CURRENT_LINK/patched-codex/codex" \
    -c features.local_thread_store_compression=true \
    app-server --remote-control --listen ws://127.0.0.1:8390
}

observe_managed_app_server_daemon() {
  local reservation_held="${1:-0}"
  local allow_missing_runtime="${2:-0}"
  python3 "$RUNTIME_OBSERVER_HELPER_ROOT/observe-managed-daemon.py" \
    "$PROC_ROOT" \
    "$RUNTIME_STORAGE_ROOT" \
    "$CURRENT_LINK/patched-codex/codex" \
    "$DAEMON_RESERVATION_GUARD" \
    "$reservation_held" \
    "$RUNTIME_OBSERVATION_TIMEOUT_SECONDS" \
    "$SCAN_MAX_ENTRIES" \
    "$STATE_FILE_MAX_BYTES" \
    "$allow_missing_runtime"
}

require_managed_runtime_inactive() {
  local context="$1"
  local reservation_held="${2:-0}"
  local systemd_observation=""
  local daemon_observation=""
  local systemd_state=""
  local daemon_state=""
  local allow_missing_runtime=0

  if [[ ! -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
    allow_missing_runtime=1
  fi

  systemd_observation="$(observe_managed_systemd_owner)" || fail "systemd runtime observation failed to execute"
  daemon_observation="$(observe_managed_app_server_daemon "$reservation_held" "$allow_missing_runtime")" || fail "daemon runtime observation failed to execute"
  systemd_state="${systemd_observation%%$'\t'*}"
  daemon_state="${daemon_observation%%$'\t'*}"
  [[ "$systemd_state" == "inactive" ]] || fail "$context systemd runtime observation is ${systemd_observation}"
  [[ "$daemon_state" == "inactive" ]] || fail "$context daemon runtime observation is ${daemon_observation}"
}

start_runtime_guard_holder() {
  local attempts=0
  local record=""
  local ready=""
  local reported_pid=""
  local helper_pid=""
  local status_file="$INSTALL_ROOT/.runtime-guard-holder.$$.$ACTIVATION_LOCK_TOKEN.ready"

  [[ ! -e "$status_file" && ! -L "$status_file" ]] || fail "runtime guard holder status path already exists"
  python3 - \
    "$RUNTIME_START_INSTALL_GUARD" "$DAEMON_RESERVATION_GUARD" \
    "$status_file" "$$" <<'PY' &
import fcntl
import os
import signal
import stat
import sys
import time
from pathlib import Path

paths = [Path(value) for value in sys.argv[1:3]]
status_path = Path(sys.argv[3])
parent_pid = int(sys.argv[4])
opened = []
stopping = False


def publish(record: str) -> None:
    descriptor = os.open(
        status_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(record + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def stop(_signal: int, _frame: object) -> None:
    global stopping
    stopping = True


signal.signal(signal.SIGTERM, stop)

try:
    for path in paths:
        parent_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            descriptor = os.open(
                path.name,
                os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=parent_fd,
            )
            descriptor_stat = os.fstat(descriptor)
            path_stat = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        finally:
            os.close(parent_fd)
        if not stat.S_ISREG(descriptor_stat.st_mode):
            raise OSError(f"guard-not-regular:{path}")
        identity = (descriptor_stat.st_dev, descriptor_stat.st_ino)
        if identity != (path_stat.st_dev, path_stat.st_ino):
            raise OSError(f"guard-open-identity-drift:{path}")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            publish(f"ERROR\tguard-held:{path}")
            raise SystemExit(1)
        opened.append((path, descriptor, identity))
except SystemExit:
    raise
except Exception as error:
    publish(f"ERROR\tguard-open:{path}:{error.__class__.__name__}")
    raise SystemExit(1)

identity_fields = [f"{device}:{inode}" for _path, _fd, (device, inode) in opened]
publish(f"READY\t{os.getpid()}\t" + "\t".join(identity_fields))

while not stopping:
    if os.getppid() != parent_pid:
        raise SystemExit(4)
    for path, _descriptor, identity in opened:
        try:
            observed = path.lstat()
        except OSError:
            raise SystemExit(2)
        if stat.S_ISLNK(observed.st_mode) or not stat.S_ISREG(observed.st_mode):
            raise SystemExit(2)
        if (observed.st_dev, observed.st_ino) != identity:
            raise SystemExit(2)
    time.sleep(0.02)
PY
  helper_pid=$!
  while [[ ! -e "$status_file" && ! -L "$status_file" && "$attempts" -lt 200 ]]; do
    kill -0 "$helper_pid" 2>/dev/null || break
    attempts=$((attempts + 1))
    sleep 0.01
  done
  if [[ ! -f "$status_file" || -L "$status_file" ]]; then
    wait "$helper_pid" >/dev/null 2>&1 || true
    fail "runtime guard holder exited before publishing descriptor identities"
  fi
  record="$(python3 - "$status_file" "$STATE_FILE_MAX_BYTES" <<'PY'
import os
import stat
import sys

descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > int(sys.argv[2]):
        raise SystemExit(1)
    data = os.read(descriptor, int(sys.argv[2]) + 1)
finally:
    os.close(descriptor)
if len(data) > int(sys.argv[2]):
    raise SystemExit(1)
sys.stdout.write(data.decode("ascii").rstrip("\n"))
PY
)" || {
    kill -TERM "$helper_pid" >/dev/null 2>&1 || true
    wait "$helper_pid" >/dev/null 2>&1 || true
    rm -f -- "$status_file"
    fail "runtime guard holder readiness record is invalid"
  }
  rm -f -- "$status_file"
  IFS=$'\t' read -r ready reported_pid RUNTIME_START_GUARD_IDENTITY DAEMON_RESERVATION_GUARD_IDENTITY <<< "$record"
  if [[ "$ready" == "ERROR" ]]; then
    wait "$helper_pid" >/dev/null 2>&1 || true
    fail "runtime guard holder refused activation: ${record#ERROR$'\t'}"
  fi
  if [[ "$ready" != "READY" || "$reported_pid" != "$helper_pid" || ! "$RUNTIME_START_GUARD_IDENTITY" =~ ^[0-9]+:[0-9]+$ || ! "$DAEMON_RESERVATION_GUARD_IDENTITY" =~ ^[0-9]+:[0-9]+$ ]]; then
    kill -TERM "$helper_pid" >/dev/null 2>&1 || true
    wait "$helper_pid" >/dev/null 2>&1 || true
    fail "runtime guard holder returned an invalid readiness record: ${ready:-<empty>}"
  fi
  RUNTIME_GUARD_HOLDER_PID="$helper_pid"
}

verify_runtime_guard_identities() {
  [[ "${RUNTIME_GUARD_HOLDER_PID:-}" =~ ^[1-9][0-9]*$ ]] || {
    echo "runtime guard holder PID is unavailable" >&2
    return 1
  }
  kill -0 "$RUNTIME_GUARD_HOLDER_PID" 2>/dev/null || {
    echo "runtime guard holder exited; guard identity is no longer continuous" >&2
    return 1
  }
  python3 - \
    "$RUNTIME_START_INSTALL_GUARD" "$RUNTIME_START_GUARD_IDENTITY" \
    "$DAEMON_RESERVATION_GUARD" "$DAEMON_RESERVATION_GUARD_IDENTITY" <<'PY'
import stat
import sys
from pathlib import Path

for offset in range(1, len(sys.argv), 2):
    path = Path(sys.argv[offset])
    expected = tuple(int(value) for value in sys.argv[offset + 1].split(":"))
    try:
        observed = path.lstat()
    except OSError as error:
        raise SystemExit(f"guard path unavailable: {path}: {error.__class__.__name__}")
    if stat.S_ISLNK(observed.st_mode) or not stat.S_ISREG(observed.st_mode):
        raise SystemExit(f"guard path is linked or special: {path}")
    if (observed.st_dev, observed.st_ino) != expected:
        raise SystemExit(f"guard path inode changed: {path}")
PY
}

stop_runtime_guard_holder() {
  local helper_pid="${RUNTIME_GUARD_HOLDER_PID:-}"

  [[ "$helper_pid" =~ ^[1-9][0-9]*$ ]] || fail "runtime guard holder release state is invalid"
  kill -TERM "$helper_pid" || fail "failed to request runtime guard release"
  wait "$helper_pid" || fail "runtime guard holder failed during release"
  RUNTIME_GUARD_HOLDER_PID=""
  RUNTIME_START_GUARD_IDENTITY=""
  DAEMON_RESERVATION_GUARD_IDENTITY=""
}

acquire_runtime_guards_for_commit() {
  [[ "$RUNTIME_GUARDS_HELD" == "0" ]] || fail "runtime guards are already held"
  require_managed_runtime_inactive initial 0
  require_activation_systemd_units_inactive initial
  mkdir -p "$(dirname "$RUNTIME_START_INSTALL_GUARD")" "$(dirname "$DAEMON_RESERVATION_GUARD")"
  start_runtime_guard_holder
  RUNTIME_GUARDS_HELD=1
  install_systemd_start_barriers
  verify_runtime_guard_identities || fail "runtime guard path identity changed while activation held the descriptors"
  require_activation_systemd_units_inactive final
  require_managed_runtime_inactive final 1
}

release_runtime_guards() {
  local identity_valid=1

  [[ "$RUNTIME_GUARDS_HELD" == "1" ]] || return 0
  verify_runtime_guard_identities || identity_valid=0
  remove_systemd_start_barriers
  stop_runtime_guard_holder
  RUNTIME_GUARDS_HELD=0
  [[ "$identity_valid" == "1" ]] || fail "runtime guard path identity changed before release"
}

release_test_start_guard() {
  [[ "$TEST_START_GUARD_HELD" == "1" ]] || return 0
  flock --unlock 9 >/dev/null 2>&1 || true
  exec 9>&-
  TEST_START_GUARD_HELD=0
}

release_test_daemon_guard() {
  [[ "$TEST_DAEMON_GUARD_HELD" == "1" ]] || return 0
  flock --unlock 10 >/dev/null 2>&1 || true
  exec 10>&-
  TEST_DAEMON_GUARD_HELD=0
}

activation_lock_owner_is_live() {
  local owner_pid="$1"
  local owner_start="$2"
  local observed_start=""

  kill -0 "$owner_pid" 2>/dev/null || return 1
  [[ "$owner_start" != "UNKNOWN" ]] || return 0
  observed_start="$(process_start_identity "$owner_pid")"
  [[ "$observed_start" == "$owner_start" ]]
}

release_activation_lock() {
  local recorded_token=""

  [[ "$ACTIVATION_LOCK_HELD" == "1" ]] || return
  if [[ -f "$ACTIVATION_LOCK_FILE" && ! -L "$ACTIVATION_LOCK_FILE" ]]; then
    recorded_token="$(manifest_value "$ACTIVATION_LOCK_FILE" token 2>/dev/null || true)"
  fi
  if [[ -n "$ACTIVATION_LOCK_TOKEN" && "$recorded_token" == "$ACTIVATION_LOCK_TOKEN" ]]; then
    rm -f -- "$ACTIVATION_LOCK_FILE"
    fsync_directory "$INSTALL_ROOT" >/dev/null 2>&1 || true
  fi
  ACTIVATION_LOCK_HELD=0
  ACTIVATION_LOCK_TOKEN=""
}

cleanup() {
  local exit_status=$?

  if [[ "$BUILD_DESCENDANTS_REAPED" != "1" ]]; then
    echo "ERROR: build descendants were not proven reaped; preserving build lock, worktree, stage, publish directory, and Cargo target" >&2
    exit "$exit_status"
  fi

  if [[ "$ACTIVATION_TRANSACTION_ACTIVE" == "1" ]]; then
    if (recover_activation_transaction cleanup); then
      ACTIVATION_TRANSACTION_ACTIVE=0
      SYSTEMD_TRANSACTION_DIR=""
    else
      echo "ERROR: activation rollback could not complete; journal preserved for manual recovery" >&2
    fi
  fi
  if [[ "$ACTIVATION_TRANSACTION_ACTIVE" == "0" && -n "$SYSTEMD_TRANSACTION_DIR" && -d "$SYSTEMD_TRANSACTION_DIR" && ! -e "$ACTIVATION_JOURNAL" ]]; then
    remove_tree_without_links "$SYSTEMD_TRANSACTION_DIR" >/dev/null 2>&1 || true
    fsync_directory "$SERVICE_DIR" >/dev/null 2>&1 || true
  fi
  if [[ "$RUNTIME_GUARDS_HELD" == "1" ]]; then
    release_runtime_guards
  fi
  release_test_start_guard
  release_test_daemon_guard
  if [[ "$ACTIVATION_LOCK_HELD" == "1" ]]; then
    release_activation_lock
  fi
  if [[ "$BUILD_LOCK_HELD" == "1" ]]; then
    release_build_lock >/dev/null 2>&1 || true
  fi
  if [[ -n "$STAGE_DIR" && ( -e "$STAGE_DIR" || -L "$STAGE_DIR" ) ]]; then
    remove_tree_without_links "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$PUBLISH_DIR" && ( -e "$PUBLISH_DIR" || -L "$PUBLISH_DIR" ) ]]; then
    remove_tree_without_links "$PUBLISH_DIR" >/dev/null 2>&1 || true
  fi
  if [[ "$WORKTREE_REGISTERED" == "1" && -n "$WORK_DIR" ]]; then
    git -C "$SOURCE_DIR" worktree remove --force "$WORK_DIR" >/dev/null 2>&1 || true
    git -C "$SOURCE_DIR" worktree prune >/dev/null 2>&1 || true
  elif [[ -n "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
  if [[ -n "$CARGO_TARGET_DIR_PATH" && -d "$CARGO_TARGET_DIR_PATH" && ! -L "$CARGO_TARGET_DIR_PATH" ]]; then
    rm -rf -- "$CARGO_TARGET_DIR_PATH"
  fi
  exit "$exit_status"
}
validate_configuration() {
  local flag=""
  local live_path=""

  [[ "$TARGET_SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail "CODEXSWITCH_GIT_SHA must be a full lowercase 40- or 64-character Git SHA"
  [[ "$APPROVED_ORIGIN_REF" =~ ^refs/remotes/origin/[A-Za-z0-9._/-]+$ ]] || fail "CODEXSWITCH_APPROVED_ORIGIN_REF must name a refs/remotes/origin/... ref"
  reject_parent_component CODEXSWITCH_APPROVED_ORIGIN_REF "$APPROVED_ORIGIN_REF"
  [[ "$BUILD_NICE" =~ ^([1-9]|1[0-9])$ ]] || fail "CODEXSWITCH_BUILD_NICE must be between 1 and 19"
  [[ "$BUILD_MEMORY_HIGH" =~ ^[1-9][0-9]*[KMGT]$ ]] || fail "CODEXSWITCH_BUILD_MEMORY_HIGH must be a systemd byte size such as 4G"
  [[ "$BUILD_MEMORY_MAX" =~ ^[1-9][0-9]*[KMGT]$ ]] || fail "CODEXSWITCH_BUILD_MEMORY_MAX must be a systemd byte size such as 6G"
  [[ "$BUILD_SWAP_MAX" =~ ^[0-9]+[KMGT]$ ]] || fail "CODEXSWITCH_BUILD_SWAP_MAX must be a systemd byte size such as 2G"
  require_positive_integer CODEXSWITCH_BUILD_MIN_FREE_BYTES "$BUILD_MIN_FREE_BYTES"
  require_positive_integer CODEXSWITCH_BUILD_MAX_BYTES "$BUILD_MAX_BYTES"
  require_positive_integer CODEXSWITCH_RELEASE_MAX_BYTES "$RELEASE_MAX_BYTES"
  require_positive_integer CODEXSWITCH_RELEASE_RETENTION_MAX_COUNT "$RELEASE_RETENTION_MAX_COUNT"
  require_positive_integer CODEXSWITCH_RELEASE_RETENTION_MAX_AGE_DAYS "$RELEASE_RETENTION_MAX_AGE_DAYS"
  require_positive_integer CODEXSWITCH_RELEASE_RETENTION_MAX_BYTES "$RELEASE_RETENTION_MAX_BYTES"
  require_positive_integer CODEXSWITCH_BUILD_RETENTION_MAX_COUNT "$BUILD_RETENTION_MAX_COUNT"
  require_positive_integer CODEXSWITCH_BUILD_RETENTION_MAX_AGE_HOURS "$BUILD_RETENTION_MAX_AGE_HOURS"
  require_positive_integer CODEXSWITCH_RUNTIME_STORAGE_MAX_COUNT "$RUNTIME_STORAGE_MAX_COUNT"
  require_positive_integer CODEXSWITCH_RUNTIME_STORAGE_MAX_AGE_DAYS "$RUNTIME_STORAGE_MAX_AGE_DAYS"
  require_positive_integer CODEXSWITCH_RUNTIME_STORAGE_MAX_BYTES "$RUNTIME_STORAGE_MAX_BYTES"
  require_positive_integer CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_COUNT "$SYSTEMD_TRANSACTION_MAX_COUNT"
  require_positive_integer CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_AGE_HOURS "$SYSTEMD_TRANSACTION_MAX_AGE_HOURS"
  require_positive_integer CODEXSWITCH_SYSTEMD_TRANSACTION_MAX_BYTES "$SYSTEMD_TRANSACTION_MAX_BYTES"
  require_positive_integer CODEXSWITCH_SCAN_MAX_ENTRIES "$SCAN_MAX_ENTRIES"
  require_positive_integer CODEXSWITCH_SCAN_MAX_DEPTH "$SCAN_MAX_DEPTH"
  require_positive_integer CODEXSWITCH_SCAN_MAX_BYTES "$SCAN_MAX_BYTES"
  require_positive_integer CODEXSWITCH_STATE_FILE_MAX_BYTES "$STATE_FILE_MAX_BYTES"
  require_positive_integer CODEXSWITCH_RUNTIME_OBSERVATION_TIMEOUT_SECONDS "$RUNTIME_OBSERVATION_TIMEOUT_SECONDS"
  require_safe_path CODEXSWITCH_PROC_ROOT "$PROC_ROOT"
  require_safe_path CODEXSWITCH_RUNTIME_OBSERVER_HELPER_ROOT "$RUNTIME_OBSERVER_HELPER_ROOT"
  [[ -d "$RUNTIME_OBSERVER_HELPER_ROOT" && ! -L "$RUNTIME_OBSERVER_HELPER_ROOT" ]] || fail "runtime observer helper root must be a regular directory: $RUNTIME_OBSERVER_HELPER_ROOT"
  RUNTIME_OBSERVER_HELPER_ROOT="$(canonicalize_path "$RUNTIME_OBSERVER_HELPER_ROOT")"
  for helper in observe-managed-systemd.py observe-managed-daemon.py; do
    [[ -f "$RUNTIME_OBSERVER_HELPER_ROOT/$helper" && ! -L "$RUNTIME_OBSERVER_HELPER_ROOT/$helper" ]] || fail "runtime observer helper is missing or unsafe: $RUNTIME_OBSERVER_HELPER_ROOT/$helper"
  done
  require_safe_path CODEXSWITCH_SYSTEMD_CONTRACT_MANIFEST "$SYSTEMD_CONTRACT_MANIFEST"
  [[ -f "$SYSTEMD_CONTRACT_MANIFEST" && ! -L "$SYSTEMD_CONTRACT_MANIFEST" ]] || fail "systemd contract manifest is missing or unsafe: $SYSTEMD_CONTRACT_MANIFEST"
  SYSTEMD_CONTRACT_MANIFEST="$(canonicalize_path "$SYSTEMD_CONTRACT_MANIFEST")"

  if [[ -n "$CODEX_SOURCE_SHA" ]]; then
    [[ "$CODEX_SOURCE_SHA" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail "CODEXSWITCH_CODEX_SOURCE_SHA must be a full lowercase 40- or 64-character Git SHA"
  fi
  if [[ -n "$CODEX_VERSION" ]]; then
    [[ "$CODEX_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || fail "CODEXSWITCH_CODEX_VERSION contains unsafe characters"
  fi
  if [[ -n "$IMPORT_BUNDLE" ]]; then
    [[ "$IMPORT_BUNDLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "CODEXSWITCH_IMPORT_BUNDLE_SHA256 must be a full lowercase 64-character SHA-256 when import is requested"
    require_safe_path CODEXSWITCH_IMPORT_BUNDLE "$IMPORT_BUNDLE"
    [[ -f "$IMPORT_BUNDLE" && ! -L "$IMPORT_BUNDLE" ]] || fail "CODEXSWITCH_IMPORT_BUNDLE must be a regular non-symlink file: $IMPORT_BUNDLE"
    IMPORT_BUNDLE="$(canonicalize_path "$IMPORT_BUNDLE")"
  else
    [[ -z "$IMPORT_BUNDLE_SHA256" ]] || fail "CODEXSWITCH_IMPORT_BUNDLE_SHA256 requires CODEXSWITCH_IMPORT_BUNDLE"
  fi

  for flag in \
    "DRY_RUN:$DRY_RUN" \
    "ACTIVATE:$ACTIVATE" \
    "INSTALL_SYSTEMD:$INSTALL_SYSTEMD" \
    "APPROVE_SYSTEMD_CONFLICTS:$APPROVE_SYSTEMD_CONFLICTS" \
    "ENABLE_DAEMON:$ENABLE_DAEMON" \
    "START_DAEMON:$START_DAEMON" \
    "ENABLE_APP_SERVER:$ENABLE_APP_SERVER" \
    "START_APP_SERVER:$START_APP_SERVER" \
    "TEST_MODE:$TEST_MODE" \
    "TEST_CONCURRENT_START:$TEST_CONCURRENT_START" \
    "TEST_CONCURRENT_DAEMON_START:$TEST_CONCURRENT_DAEMON_START"; do
    require_flag "${flag%%:*}" "${flag#*:}"
  done
  if [[ "$ACTIVATE" == "1" ]]; then
    require_reviewed_runtime_provenance
  fi
  if [[ "${CODEXSWITCH_RESTART_DAEMON:-0}" != "0" || "${CODEXSWITCH_RESTART_APP_SERVER:-0}" != "0" ]]; then
    fail "restart flags are obsolete; activation never restarts a runtime (use an explicit post-commit CODEXSWITCH_START_* flag only for a positively inactive owner)"
  fi
  if [[ -n "$TEST_PROCESS_START_IDENTITY" ]]; then
    [[ "$TEST_MODE" == "1" && "$TEST_PROCESS_START_IDENTITY" =~ ^[1-9][0-9]*$ ]] || fail "CODEXSWITCH_TEST_PROCESS_START_IDENTITY requires test mode and a numeric identity"
  fi
  [[ "$TEST_CONCURRENT_START" == "0" || "$TEST_MODE" == "1" ]] || fail "CODEXSWITCH_TEST_CONCURRENT_START requires test mode"
  [[ "$TEST_CONCURRENT_DAEMON_START" == "0" || "$TEST_MODE" == "1" ]] || fail "CODEXSWITCH_TEST_CONCURRENT_DAEMON_START requires test mode"
  if [[ -n "$TEST_BUILD_TIMEOUT_SECONDS" ]]; then
    [[ "$TEST_MODE" == "1" ]] || fail "CODEXSWITCH_TEST_BUILD_TIMEOUT_SECONDS requires test mode"
    require_positive_integer CODEXSWITCH_TEST_BUILD_TIMEOUT_SECONDS "$TEST_BUILD_TIMEOUT_SECONDS"
    [[ "$TEST_BUILD_TIMEOUT_SECONDS" -le 10 ]] || fail "CODEXSWITCH_TEST_BUILD_TIMEOUT_SECONDS must be at most 10"
    BUILD_TIMEOUT_SECONDS="$TEST_BUILD_TIMEOUT_SECONDS"
  fi

  if [[ "$ACTIVATE" == "0" ]] && {
    [[ "$APPROVE_SYSTEMD_CONFLICTS" == "1" ]] ||
    [[ "$ENABLE_DAEMON" == "1" ]] ||
    [[ "$START_DAEMON" == "1" ]] ||
    [[ "$ENABLE_APP_SERVER" == "1" ]] ||
    [[ "$START_APP_SERVER" == "1" ]] ||
    [[ -n "$IMPORT_BUNDLE" ]];
  }; then
    fail "systemd approval, cleanup, import, enable, and start actions require CODEXSWITCH_ACTIVATE=1"
  fi
  if [[ "$ACTIVATE" == "1" && "$INSTALL_SYSTEMD" != "1" ]]; then
    fail "activation requires CODEXSWITCH_INSTALL_SYSTEMD=1 for merged-unit verification"
  fi
  if [[ -n "$IMPORT_BUNDLE" && "$START_DAEMON" != "$START_APP_SERVER" ]]; then
    fail "post-start import convergence requires CODEXSWITCH_START_DAEMON=1 and CODEXSWITCH_START_APP_SERVER=1 together"
  fi
  if [[ -n "$TEST_FAULT_POINT" && "$TEST_MODE" != "1" ]]; then
    fail "fault injection requires CODEXSWITCH_TEST_MODE=1"
  fi
  case "$TEST_FAULT_MODE" in
    fail|crash) ;;
    *) fail "CODEXSWITCH_TEST_FAULT_MODE must be fail or crash" ;;
  esac

  require_safe_path CODEXSWITCH_INSTALL_ROOT "$INSTALL_ROOT"
  require_safe_path CODEXSWITCH_SOURCE_DIR "$SOURCE_DIR"
  require_safe_path CODEXSWITCH_BUILD_ROOT "$BUILD_ROOT"
  require_safe_path CODEXSWITCH_BIN_DIR "$BIN_DIR"
  require_safe_path CODEXSWITCH_SYSTEMD_USER_DIR "$SERVICE_DIR"
  require_safe_path CODEXSWITCH_CODEX_RUNTIME_DIR "$CODEX_RUNTIME_DIR"
  require_safe_path CODEXSWITCH_RUNTIME_STORAGE_ROOT "$RUNTIME_STORAGE_ROOT"
  [[ ! -L "$CODEX_RUNTIME_DIR" ]] || fail "CODEXSWITCH_CODEX_RUNTIME_DIR must not be a symlink: $CODEX_RUNTIME_DIR"
  [[ ! -L "$RUNTIME_STORAGE_ROOT" ]] || fail "CODEXSWITCH_RUNTIME_STORAGE_ROOT must not be a symlink: $RUNTIME_STORAGE_ROOT"

  HOME_ROOT="$(canonicalize_path "$HOME")"
  INSTALL_ROOT="$(canonicalize_path "$INSTALL_ROOT")"
  SOURCE_DIR="$(canonicalize_path "$SOURCE_DIR")"
  BUILD_ROOT="$(canonicalize_path "$BUILD_ROOT")"
  BIN_DIR="$(canonicalize_path "$BIN_DIR")"
  SERVICE_DIR="$(canonicalize_path "$SERVICE_DIR")"
  CODEX_RUNTIME_DIR="$(canonicalize_path "$CODEX_RUNTIME_DIR")"
  RUNTIME_STORAGE_ROOT="$(canonicalize_path "$RUNTIME_STORAGE_ROOT")"
  if [[ -n "$IMPORT_BUNDLE" ]]; then
    [[ ! -L "$ACCOUNT_STORE_PATH" ]] || fail "CODEXSWITCH_ACCOUNT_STORE_PATH must not be a symlink: $ACCOUNT_STORE_PATH"
    [[ ! -L "$AUTH_PATH" ]] || fail "CODEXSWITCH_AUTH_PATH must not be a symlink: $AUTH_PATH"
    ACCOUNT_STORE_PATH="$(canonicalize_path "$ACCOUNT_STORE_PATH")"
    AUTH_PATH="$(canonicalize_path "$AUTH_PATH")"
    validate_private_mutation_path CODEXSWITCH_ACCOUNT_STORE_PATH "$ACCOUNT_STORE_PATH"
    validate_private_mutation_path CODEXSWITCH_AUTH_PATH "$AUTH_PATH"
    [[ "$ACCOUNT_STORE_PATH" != "$AUTH_PATH" ]] || fail "account store and auth paths must be distinct"
  fi

  RELEASES_DIR="$INSTALL_ROOT/releases"
  CURRENT_LINK="$INSTALL_ROOT/current"
  PREVIOUS_LINK="$INSTALL_ROOT/previous"
  ACTIVATION_LOCK_FILE="$INSTALL_ROOT/.activation.lock"
  ACTIVATION_JOURNAL="$INSTALL_ROOT/.activation-transaction.tsv"
  RUNTIME_START_INSTALL_GUARD="$INSTALL_ROOT/runtime-start-install.lock"
  DAEMON_RESERVATION_GUARD="$RUNTIME_STORAGE_ROOT/app-server-daemon/app-server.pid.lock"
  CARGO_TARGET_ROOT="$BUILD_ROOT/cargo-target"
  CARGO_TARGET_DIR_PATH="$CARGO_TARGET_ROOT/shared"
  WORKTREE_ROOT="$BUILD_ROOT/worktrees"
  BUILD_STAGE_ROOT="$BUILD_ROOT/stage"
  BUILD_LOCK_DIR="$BUILD_ROOT/.build.lock"
  TRANSACTION_OWNER_KEY="$INSTALL_ROOT/.transaction-owner.key"

  for live_path in "$INSTALL_ROOT" "$SOURCE_DIR" "$BIN_DIR" "$SERVICE_DIR" "$CODEX_RUNTIME_DIR" "$RUNTIME_STORAGE_ROOT"; do
    paths_overlap "$BUILD_ROOT" "$live_path" && fail "canonical build root overlaps live path: $BUILD_ROOT <-> $live_path"
  done
  [[ "$SOURCE_DIR" != "$INSTALL_ROOT" ]] || fail "source cache must not equal the install root"
  validate_derived_path RELEASES_DIR "$INSTALL_ROOT" "$RELEASES_DIR"
  validate_derived_parent_path CURRENT_LINK "$INSTALL_ROOT" "$CURRENT_LINK"
  validate_derived_parent_path PREVIOUS_LINK "$INSTALL_ROOT" "$PREVIOUS_LINK"
  validate_derived_parent_path ACTIVATION_LOCK_FILE "$INSTALL_ROOT" "$ACTIVATION_LOCK_FILE"
  validate_derived_parent_path ACTIVATION_JOURNAL "$INSTALL_ROOT" "$ACTIVATION_JOURNAL"
  validate_derived_parent_path RUNTIME_START_INSTALL_GUARD "$INSTALL_ROOT" "$RUNTIME_START_INSTALL_GUARD"
  validate_derived_parent_path DAEMON_RESERVATION_GUARD "$RUNTIME_STORAGE_ROOT" "$DAEMON_RESERVATION_GUARD"
  validate_build_derived_path CARGO_TARGET_ROOT "$CARGO_TARGET_ROOT"
  validate_build_derived_path CARGO_TARGET_DIR "$CARGO_TARGET_DIR_PATH"
  validate_build_derived_path WORKTREE_ROOT "$WORKTREE_ROOT"
  validate_build_derived_path BUILD_STAGE_ROOT "$BUILD_STAGE_ROOT"
  validate_build_derived_path BUILD_LOCK_DIR "$BUILD_LOCK_DIR"
  validate_derived_parent_path TRANSACTION_OWNER_KEY "$INSTALL_ROOT" "$TRANSACTION_OWNER_KEY"
}
