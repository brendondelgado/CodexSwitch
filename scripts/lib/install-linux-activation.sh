# shellcheck shell=bash
inject_fault() {
  local point="$1"
  if [[ "$TEST_MODE" == "1" && "$TEST_FAULT_POINT" == "$point" ]]; then
    if [[ "$TEST_FAULT_MODE" == "crash" ]]; then
      kill -KILL "$$"
    fi
    fail "injected activation fault at $point"
  fi
}

ensure_transaction_owner_key() {
  python3 - "$TRANSACTION_OWNER_KEY" <<'PY'
import os
import secrets
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
if os.path.lexists(path):
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise SystemExit(f"transaction owner key is linked or special: {path}")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit(f"transaction owner key permissions are not 0600: {path}")
    value = path.read_text(encoding="ascii").strip()
    if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        raise SystemExit(f"transaction owner key is invalid: {path}")
    raise SystemExit(0)
temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(descriptor, "w", encoding="ascii") as handle:
    handle.write(secrets.token_hex(32) + "\n")
    handle.flush()
    os.fsync(handle.fileno())
try:
    os.link(temporary, path, follow_symlinks=False)
except FileExistsError:
    pass
finally:
    temporary.unlink(missing_ok=True)
directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
}

publish_activation_lock() {
  local candidate=""
  local owner_start=""

  ACTIVATION_LOCK_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(16))')" || fail "failed to generate activation lock token"
  [[ "$ACTIVATION_LOCK_TOKEN" =~ ^[0-9a-f]{32}$ ]] || fail "generated activation lock token is invalid"
  owner_start="$(process_start_identity "$$")" || fail "failed to read activation owner identity"
  candidate="$INSTALL_ROOT/.activation.lock.candidate.$$.$ACTIVATION_LOCK_TOKEN"
  validate_derived_path ACTIVATION_LOCK_CANDIDATE "$INSTALL_ROOT" "$candidate"
  python3 - "$candidate" "$$" "$owner_start" "$ACTIVATION_LOCK_TOKEN" <<'PY' || fail "failed to persist activation lock owner"
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    handle.write("format\tcodexswitch-activation-lock-v1\n")
    handle.write(f"pid\t{sys.argv[2]}\n")
    handle.write(f"start\t{sys.argv[3]}\n")
    handle.write(f"token\t{sys.argv[4]}\n")
    handle.flush()
    os.fsync(handle.fileno())
directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
  if ! ln -- "$candidate" "$ACTIVATION_LOCK_FILE" 2>/dev/null; then
    rm -f -- "$candidate"
    ACTIVATION_LOCK_TOKEN=""
    return 1
  fi
  ACTIVATION_LOCK_HELD=1
  rm -f -- "$candidate" || fail "failed to remove activation lock candidate"
  fsync_directory "$INSTALL_ROOT" || fail "failed to persist activation lock publication"
}

prune_activation_lock_candidates() {
  local candidate=""
  local candidate_name=""
  local removed=0

  for candidate in "$INSTALL_ROOT"/.activation.lock.candidate.*; do
    [[ -e "$candidate" || -L "$candidate" ]] || continue
    candidate_name="$(basename "$candidate")"
    [[ "$candidate_name" =~ ^\.activation\.lock\.candidate\.[1-9][0-9]*\.[0-9a-f]{32}$ ]] || fail "unsafe activation lock candidate: $candidate"
    [[ -f "$candidate" && ! -L "$candidate" ]] || fail "activation lock candidate is not a regular file: $candidate"
    rm -f -- "$candidate"
    removed=1
  done
  [[ "$removed" == "0" ]] || fsync_directory "$INSTALL_ROOT"
}

acquire_activation_lock() {
  local owner_pid=""
  local owner_start=""
  local owner_format=""
  local owner_token=""

  mkdir -p "$INSTALL_ROOT"
  ensure_transaction_owner_key || fail "failed to establish transaction owner key"
  exec 9< "$INSTALL_ROOT" || fail "failed to open activation lock mutex"
  python3 - 9 <<'PY' || fail "failed to acquire activation lock mutex"
import fcntl
import sys

fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX)
PY
  prune_activation_lock_candidates
  if [[ -e "$ACTIVATION_LOCK_FILE" || -L "$ACTIVATION_LOCK_FILE" ]]; then
    [[ -f "$ACTIVATION_LOCK_FILE" && ! -L "$ACTIVATION_LOCK_FILE" && -s "$ACTIVATION_LOCK_FILE" ]] || fail "activation lock has no durable owner record: $ACTIVATION_LOCK_FILE"
    owner_format="$(manifest_value "$ACTIVATION_LOCK_FILE" format 2>/dev/null || true)"
    owner_pid="$(manifest_value "$ACTIVATION_LOCK_FILE" pid 2>/dev/null || true)"
    owner_start="$(manifest_value "$ACTIVATION_LOCK_FILE" start 2>/dev/null || true)"
    owner_token="$(manifest_value "$ACTIVATION_LOCK_FILE" token 2>/dev/null || true)"
    [[ "$owner_format" == "codexswitch-activation-lock-v1" && "$owner_pid" =~ ^[1-9][0-9]*$ && -n "$owner_start" && "$owner_token" =~ ^[0-9a-f]{32}$ ]] || fail "activation lock owner record is invalid: $ACTIVATION_LOCK_FILE"
    activation_lock_owner_is_live "$owner_pid" "$owner_start" && fail "another activation holds $ACTIVATION_LOCK_FILE"
    rm -f -- "$ACTIVATION_LOCK_FILE"
    fsync_directory "$INSTALL_ROOT"
  fi
  publish_activation_lock || fail "failed to publish activation lock"
  exec 9<&-
  if [[ -e "$ACTIVATION_JOURNAL" || -L "$ACTIVATION_JOURNAL" ]]; then
    acquire_runtime_guards_for_commit
    recover_activation_transaction startup || fail "activation rollback recovery failed; journal preserved"
    release_runtime_guards
  fi
  prune_abandoned_systemd_transactions
}

validate_public_cli_contract() {
  local public_cli="$BIN_DIR/codexswitch-cli"
  local expected="$CURRENT_LINK/codexswitch-cli"
  local resolved_public=""
  local resolved_current_cli=""

  if [[ ! -e "$public_cli" && ! -L "$public_cli" ]]; then
    return
  fi
  if [[ -L "$public_cli" && "$(readlink "$public_cli")" == "$expected" ]]; then
    return
  fi
  if [[ -L "$public_cli" && ( -e "$CURRENT_LINK" || -L "$CURRENT_LINK" ) ]]; then
    resolved_public="$(canonicalize_path "$public_cli")"
    resolved_current_cli="$(canonicalize_path "$CURRENT_LINK/codexswitch-cli")"
    [[ "$resolved_public" == "$resolved_current_cli" ]] && return
  fi
  fail "public CLI must permanently resolve through $expected"
}

observe_import_activation_barrier() {
  local mode="$1"
  local expected_identity="${2:-}"

  python3 - "$mode" "$ACCOUNT_STORE_PATH" "$STATE_FILE_MAX_BYTES" "$RUNTIME_OBSERVATION_TIMEOUT_SECONDS" "$expected_identity" <<'PY'
import hashlib
import json
import os
import stat
import sys
import time
from pathlib import Path

mode = sys.argv[1]
record_path = Path(sys.argv[2]).with_suffix(".activation.json")
max_bytes = int(sys.argv[3])
timeout_seconds = int(sys.argv[4])
expected_identity = sys.argv[5]

def read_record():
    before = record_path.lstat()
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or stat.S_IMODE(before.st_mode) != 0o600
        or before.st_size > max_bytes
    ):
        raise RuntimeError(f"import activation barrier is linked, special, unowned, incorrectly permissioned, or oversized: {record_path}")
    descriptor = os.open(record_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise RuntimeError("import activation barrier changed identity while opened")
        chunks = []
        consumed = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, max_bytes - consumed + 1))
            if not chunk:
                break
            consumed += len(chunk)
            if consumed > max_bytes:
                raise RuntimeError("import activation barrier exceeds its bounded read limit")
            chunks.append(chunk)
        data = b"".join(chunks)
    finally:
        os.close(descriptor)
    after = record_path.lstat()
    if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
        raise RuntimeError("import activation barrier changed identity while read")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise RuntimeError("import activation barrier is not an object")
    return value

def barrier_identity(record):
    version = record.get("version")
    kind = record.get("kind")
    previous = record.get("previousAccountId")
    target = record.get("targetAccountId")
    generation = record.get("storeGeneration")
    fingerprint = record.get("authFingerprint")
    if not isinstance(version, int) or isinstance(version, bool) or version < 3:
        raise RuntimeError("import activation barrier version is invalid")
    if kind != "import":
        raise RuntimeError("activation barrier is not an import")
    if not isinstance(previous, str) or len(previous) > 4096:
        raise RuntimeError("import activation prior identity is invalid")
    if not isinstance(target, str) or not target or len(target) > 4096:
        raise RuntimeError("import activation target identity is invalid")
    for label, value in (("store generation", generation), ("auth fingerprint", fingerprint)):
        if (
            not isinstance(value, str)
            or len(value) != 64
            or any(character not in "0123456789abcdef" for character in value)
        ):
            raise RuntimeError(f"import activation {label} is invalid")
    encoded = json.dumps(
        [version, kind, previous, target, generation, fingerprint],
        ensure_ascii=True,
        separators=(",", ":"),
    ).encode("ascii")
    return hashlib.sha256(encoded).hexdigest()

if mode == "capture":
    record = read_record()
    if record.get("state") != "file_only":
        raise SystemExit("offline import did not durably publish an Import/FileOnly barrier")
    print(barrier_identity(record))
    raise SystemExit(0)

if mode != "wait" or len(expected_identity) != 64:
    raise SystemExit("invalid import activation barrier observation request")

deadline = time.monotonic() + timeout_seconds
last_state = "unread"
while True:
    try:
        record = read_record()
        observed_identity = barrier_identity(record)
    except (FileNotFoundError, RuntimeError, json.JSONDecodeError) as error:
        last_state = f"unreadable ({error})"
    else:
        if observed_identity != expected_identity:
            raise SystemExit("post-start activation record does not identify the prepared Import/FileOnly barrier")
        last_state = record.get("state")
        if last_state == "confirmed":
            raise SystemExit(0)
        if last_state not in {"file_only", "committed_degraded"}:
            raise SystemExit(f"prepared import barrier entered terminal state {last_state!r}")
    if time.monotonic() >= deadline:
        raise SystemExit(
            f"prepared Import/FileOnly barrier did not reach confirmed convergence within {timeout_seconds}s (last state: {last_state})"
        )
    time.sleep(0.1)
PY
}

capture_import_activation_barrier() {
  IMPORT_ACTIVATION_BARRIER_IDENTITY="$(observe_import_activation_barrier capture)" ||
    fail "offline import barrier could not be captured"
  [[ "$IMPORT_ACTIVATION_BARRIER_IDENTITY" =~ ^[0-9a-f]{64}$ ]] ||
    fail "offline import barrier identity is invalid"
}

require_import_activation_convergence() {
  [[ "$IMPORT_ACTIVATION_BARRIER_IDENTITY" =~ ^[0-9a-f]{64}$ ]] ||
    fail "post-start convergence has no captured Import/FileOnly barrier"
  observe_import_activation_barrier wait "$IMPORT_ACTIVATION_BARRIER_IDENTITY" ||
    fail "post-start convergence did not confirm the prepared import barrier"
  IMPORT_BARRIER_CONVERGED=1
}

activate_release() {
  require_reviewed_runtime_provenance
  local current_target=""
  local previous_target=""
  local new_target="releases/$RELEASE_ID"
  local public_cli="$BIN_DIR/codexswitch-cli"
  local old_current="ABSENT"
  local old_previous="ABSENT"
  local old_public="ABSENT"
  local is_first_activation=0
  local is_rollback=0

  [[ "$ACTIVATION_LOCK_HELD" == "1" ]] || acquire_activation_lock
  inject_fault after_lock
  validate_candidate_release
  acquire_runtime_guards_for_commit
  if [[ -e "$CURRENT_LINK" || -L "$CURRENT_LINK" ]]; then
    current_target="$(managed_release_from_link "$CURRENT_LINK" current)"
    old_current="$current_target"
  else
    is_first_activation=1
  fi
  if [[ -e "$PREVIOUS_LINK" || -L "$PREVIOUS_LINK" ]]; then
    previous_target="$(managed_release_from_link "$PREVIOUS_LINK" previous)"
    old_previous="$previous_target"
  fi
  validate_public_cli_contract
  [[ -z "$previous_target" ]] || validate_release "$INSTALL_ROOT/$previous_target"
  if [[ -L "$public_cli" ]]; then
    old_public="$(readlink "$public_cli")"
    [[ "$old_public" == /* ]] || fail "legacy public CLI symlink must use an absolute managed target before activation"
  fi
  [[ "$new_target" != "$previous_target" ]] || is_rollback=1

  mkdir -p "$BIN_DIR"
  validate_systemd_preconditions
  begin_systemd_transaction
  enforce_systemd_transaction_storage_bound
  inject_fault before_journal
  write_activation_journal prepared "$old_current" "$old_previous" "$old_public" "$new_target" "$(basename "$SYSTEMD_TRANSACTION_DIR")"
  ACTIVATION_TRANSACTION_ACTIVE=1
  apply_systemd_transaction
  inject_fault after_systemd
  validate_candidate_release
  if [[ -n "$current_target" && ( ! -L "$public_cli" || "$(readlink "$public_cli")" != "$CURRENT_LINK/codexswitch-cli" ) ]]; then
    atomic_symlink "$CURRENT_LINK/codexswitch-cli" "$public_cli"
    validate_public_cli_contract
  fi
  atomic_symlink "$new_target" "$CURRENT_LINK"
  write_activation_journal current_updated "$old_current" "$old_previous" "$old_public" "$new_target" "$(basename "$SYSTEMD_TRANSACTION_DIR")"
  [[ "$is_first_activation" == "0" ]] || inject_fault first_activation
  inject_fault after_current

  if [[ ! -L "$public_cli" || "$(readlink "$public_cli")" != "$CURRENT_LINK/codexswitch-cli" ]]; then
    atomic_symlink "$CURRENT_LINK/codexswitch-cli" "$public_cli"
  fi
  validate_public_cli_contract
  [[ "$is_rollback" == "0" ]] || inject_fault rollback

  if [[ -n "$current_target" && "$current_target" != "$new_target" ]]; then
    atomic_symlink "$current_target" "$PREVIOUS_LINK"
  fi
  write_activation_journal previous_updated "$old_current" "$old_previous" "$old_public" "$new_target" "$(basename "$SYSTEMD_TRANSACTION_DIR")"
  inject_fault after_previous

  [[ "$(managed_release_from_link "$CURRENT_LINK" current)" == "$new_target" ]] || fail "current pointer verification failed"
  [[ -z "$current_target" || "$current_target" == "$new_target" || "$(managed_release_from_link "$PREVIOUS_LINK" previous)" == "$current_target" ]] || fail "previous pointer verification failed"
  validate_public_cli_contract
}

run_transaction_actions() {
  local import_status=0

  [[ "$ENABLE_DAEMON" == "0" ]] || systemctl --user enable codexswitch.service
  [[ "$ENABLE_APP_SERVER" == "0" ]] || systemctl --user enable signul-codex-app-server.service
  if [[ -n "$IMPORT_BUNDLE" ]]; then
    set +e
    "$BIN_DIR/codexswitch-cli" \
      --store "$ACCOUNT_STORE_PATH" \
      --auth "$AUTH_PATH" \
      import --offline-file-only "$IMPORT_BUNDLE_STAGED"
    import_status=$?
    set -e
    record_import_owned_generation
    [[ "$import_status" == "0" ]] || return "$import_status"
    capture_import_activation_barrier
  fi
  validate_exact_systemd_filesystem_state
}

require_unit_positively_inactive_for_start() {
  local unit="$1"
  local fragment="$SERVICE_DIR/$unit"
  local observation=""
  local -a expected_argv=()

  if [[ "$unit" == "$MANAGED_APP_SERVER_UNIT" ]]; then
    observation="$(observe_managed_systemd_owner)" || fail "post-commit systemd observation failed"
    [[ "${observation%%$'\t'*}" == "inactive" ]] || fail "post-commit start refused: $observation"
    return 0
  fi
  case "$unit" in
    codexswitch.service) expected_argv=("$BIN_DIR/codexswitch-cli" daemon) ;;
    *) fail "post-commit start has no exact ExecStart contract for $unit" ;;
  esac
  observation="$(python3 "$RUNTIME_OBSERVER_HELPER_ROOT/observe-managed-systemd.py" \
    "$unit" \
    "$fragment" \
    "$RUNTIME_OBSERVATION_TIMEOUT_SECONDS" \
    "$STATE_FILE_MAX_BYTES" \
    "${expected_argv[@]}")" || fail "post-commit unit observation failed"
  [[ "${observation%%$'\t'*}" == "inactive" ]] || fail "post-commit start refused: unit=$unit observation=$observation"
}

run_requested_starts() {
  [[ "$ACTIVATION_TRANSACTION_ACTIVE" == "0" && "$RUNTIME_GUARDS_HELD" == "0" ]] || fail "post-commit starts require completed journal cleanup and released guards"
  if [[ -n "$IMPORT_BUNDLE" && "$START_APP_SERVER" == "1" ]]; then
    require_managed_runtime_inactive post-commit-start 0
    validate_release "$(canonicalize_path "$CURRENT_LINK")"
    systemctl --user start "$MANAGED_APP_SERVER_UNIT"
    require_unit_positively_inactive_for_start codexswitch.service
    systemctl --user start codexswitch.service
    require_import_activation_convergence
    return
  fi
  if [[ "$START_DAEMON" == "1" ]]; then
    require_unit_positively_inactive_for_start codexswitch.service
    systemctl --user start codexswitch.service
  fi
  if [[ "$START_APP_SERVER" == "1" ]]; then
    require_managed_runtime_inactive post-commit-start 0
    validate_release "$(canonicalize_path "$CURRENT_LINK")"
    systemctl --user start "$MANAGED_APP_SERVER_UNIT"
  fi
}

commit_activation_transaction() {
  [[ "$ACTIVATION_TRANSACTION_ACTIVE" == "1" ]] || fail "activation transaction is not active at commit"
  [[ "$RUNTIME_GUARDS_HELD" == "1" ]] || fail "activation commit lost its runtime guards"
  update_activation_journal_phase committed
  complete_systemd_transaction
  remove_activation_journal
  ACTIVATION_TRANSACTION_ACTIVE=0
  release_runtime_guards
}
