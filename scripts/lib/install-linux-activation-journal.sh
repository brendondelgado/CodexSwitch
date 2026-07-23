# shellcheck shell=bash
write_activation_journal() {
  local phase="$1"
  local old_current="$2"
  local old_previous="$3"
  local old_public="$4"
  local new_current="$5"
  local systemd_transaction="${6:-ABSENT}"

  python3 - "$ACTIVATION_JOURNAL" "$phase" "$old_current" "$old_previous" "$old_public" "$new_current" "$systemd_transaction" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
values = {
    "format": "codexswitch-activation-v4",
    "phase": sys.argv[2],
    "old_current": sys.argv[3],
    "old_previous": sys.argv[4],
    "old_public": sys.argv[5],
    "new_current": sys.argv[6],
    "systemd_transaction": sys.argv[7],
    "systemd_observation": "inactive",
    "daemon_observation": "inactive",
}
temp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
with temp.open("x", encoding="utf-8") as handle:
    for key, value in values.items():
        handle.write(f"{key}\t{value}\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temp, path)
directory = os.open(path.parent, os.O_RDONLY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
}
remove_activation_journal() {
  python3 - "$ACTIVATION_JOURNAL" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    path.unlink()
except FileNotFoundError:
    pass
directory = os.open(path.parent, os.O_RDONLY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
}

update_activation_journal_phase() {
  local phase="$1"
  python3 - "$ACTIVATION_JOURNAL" "$phase" "$STATE_FILE_MAX_BYTES" <<'PY'
import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
phase = sys.argv[2]
limit = int(sys.argv[3])
if phase not in {"prepared", "current_updated", "previous_updated", "committed"}:
    raise SystemExit("invalid activation journal phase")
metadata = path.lstat()
if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode) or metadata.st_size > limit:
    raise SystemExit("unsafe activation journal")
descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    data = os.read(descriptor, limit + 1)
    if len(data) > limit or os.read(descriptor, 1):
        raise SystemExit("activation journal exceeds read limit")
finally:
    os.close(descriptor)
lines = data.decode("utf-8").splitlines()
matches = [index for index, line in enumerate(lines) if line.startswith("phase\t")]
if matches != [1]:
    raise SystemExit("activation journal phase row is malformed")
lines[1] = f"phase\t{phase}"
encoded = ("\n".join(lines) + "\n").encode("utf-8")
temporary = path.with_name(f".{path.name}.phase.{os.getpid()}")
target = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
try:
    os.write(target, encoded)
    os.fsync(target)
finally:
    os.close(target)
os.replace(temporary, path)
directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
}

validate_journal_target() {
  local value="$1"
  local label="$2"
  local release_id=""

  [[ "$value" == "ABSENT" ]] && return
  case "$value" in
    releases/*) ;;
    *) fail "activation journal has unsafe $label target: $value" ;;
  esac
  release_id="${value#releases/}"
  [[ -n "$release_id" && "$release_id" != */* && "$release_id" != *..* ]] || fail "activation journal has unsafe $label target: $value"
  validate_release "$INSTALL_ROOT/$value"
}

restore_managed_link() {
  local link="$1"
  local target="$2"

  if [[ "$target" == "ABSENT" ]]; then
    [[ ! -e "$link" || -L "$link" ]] || fail "refusing to remove non-symlink during activation recovery: $link"
    rm -f -- "$link"
    fsync_directory "$(dirname "$link")"
    return
  fi
  atomic_symlink "$target" "$link"
}

validate_systemd_transaction() {
  local transaction_name="$1"

  [[ "$transaction_name" =~ ^\.codexswitch-activation\.[1-9][0-9]*$ ]] || fail "activation journal has unsafe systemd transaction: $transaction_name"
  SYSTEMD_TRANSACTION_DIR="$SERVICE_DIR/$transaction_name"
  validate_derived_path SYSTEMD_TRANSACTION_DIR "$SERVICE_DIR" "$SYSTEMD_TRANSACTION_DIR"
  [[ -f "$SYSTEMD_TRANSACTION_DIR/state.tsv" && ! -L "$SYSTEMD_TRANSACTION_DIR/state.tsv" ]] || fail "systemd transaction state is missing or linked"
  [[ -d "$SYSTEMD_TRANSACTION_DIR/before" && ! -L "$SYSTEMD_TRANSACTION_DIR/before" ]] || fail "systemd transaction snapshot is missing or linked"
  [[ -f "$SYSTEMD_TRANSACTION_DIR/import-state.tsv" && ! -L "$SYSTEMD_TRANSACTION_DIR/import-state.tsv" ]] || fail "import transaction state is missing or linked"
}

validate_recovery_payload() {
  local old_public="$1"

  [[ "$old_public" == "ABSENT" || "$old_public" == "$CURRENT_LINK/codexswitch-cli" ]] || fail "activation journal has unsafe public target"
  python3 - "$SYSTEMD_TRANSACTION_DIR" "$SERVICE_DIR" "$TRANSACTION_OWNER_KEY" "$STATE_FILE_MAX_BYTES" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" "$(managed_systemd_entries)" <<'PY' || return $?
import hashlib
import hmac
import os
import re
import stat
import sys
from pathlib import Path

transaction = Path(sys.argv[1])
service_dir = Path(sys.argv[2])
key_path = Path(sys.argv[3])
state_limit = int(sys.argv[4])
max_entries = int(sys.argv[5])
max_depth = int(sys.argv[6])
max_bytes = int(sys.argv[7])
managed = [value for value in sys.argv[8].splitlines() if value]

directory_metadata = transaction.lstat()
if stat.S_ISLNK(directory_metadata.st_mode) or not stat.S_ISDIR(directory_metadata.st_mode):
    raise SystemExit("recovery transaction directory is linked or special")
if stat.S_IMODE(directory_metadata.st_mode) != 0o700:
    raise SystemExit("recovery transaction directory permissions are invalid")
directory_fd = os.open(transaction, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    opened_directory = os.fstat(directory_fd)
    if (opened_directory.st_dev, opened_directory.st_ino) != (
        directory_metadata.st_dev,
        directory_metadata.st_ino,
    ):
        raise SystemExit("recovery transaction directory changed identity")
finally:
    os.close(directory_fd)

def bounded_text(path: Path):
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise SystemExit(f"recovery state is linked or special: {path}")
    if metadata.st_size > state_limit:
        raise SystemExit(f"recovery state exceeds bounded limit: {path}")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise SystemExit(f"recovery state changed identity: {path}")
        data = os.read(descriptor, state_limit + 1)
        if len(data) > state_limit or os.read(descriptor, 1):
            raise SystemExit(f"recovery state exceeds bounded limit: {path}")
    finally:
        os.close(descriptor)
    return data.decode("utf-8")

owner_lines = bounded_text(transaction / "owner.tsv").splitlines()
owner = []
seen = set()
for line in owner_lines:
    name, separator, value = line.partition("\t")
    if not separator or name in seen:
        raise SystemExit("invalid recovery transaction owner")
    seen.add(name)
    owner.append((name, value))
expected_owner_keys = [
    "format", "pid", "start", "lock_token", "token", "generation",
    "directory_dev", "directory_ino", "signature",
]
if [name for name, _value in owner] != expected_owner_keys:
    raise SystemExit("invalid recovery transaction owner")
owner_values = dict(owner)
key = bytes.fromhex(bounded_text(key_path).strip())
payload = "".join(f"{name}\t{value}\n" for name, value in owner[:-1]).encode()
expected_signature = hmac.new(key, payload, hashlib.sha256).hexdigest()
if not all((
    owner_values["format"] == "codexswitch-systemd-transaction-v2",
    owner_values["pid"] == transaction.name.rsplit(".", 1)[-1],
    bool(re.fullmatch(r"(?:[0-9]+|UNKNOWN)", owner_values["start"])),
    bool(re.fullmatch(r"[0-9a-f]{32}", owner_values["lock_token"])),
    bool(re.fullmatch(r"[0-9a-f]{64}", owner_values["token"])),
    bool(re.fullmatch(r"[0-9a-f]{64}", owner_values["generation"])),
    owner_values["directory_dev"] == str(directory_metadata.st_dev),
    owner_values["directory_ino"] == str(directory_metadata.st_ino),
    hmac.compare_digest(owner_values["signature"], expected_signature),
)):
    raise SystemExit("invalid recovery transaction owner")

states = {}
for line in bounded_text(transaction / "state.tsv").splitlines():
    fields = line.split("\t", 2)
    if len(fields) < 2:
        raise SystemExit("invalid recovery systemd state")
    name, state = fields[:2]
    target = fields[2] if len(fields) == 3 else ""
    if name in states or name not in managed or state not in {"ABSENT", "PRESENT", "SYMLINK"}:
        raise SystemExit("invalid recovery systemd state")
    if state == "SYMLINK" and (not target or "\n" in target or "\t" in target):
        raise SystemExit("invalid recovery systemd symlink state")
    if state != "SYMLINK" and target:
        raise SystemExit("invalid recovery systemd state payload")
    states[name] = state
if set(states) != set(managed):
    raise SystemExit("incomplete recovery systemd state")

before = transaction / "before"
before_metadata = before.lstat()
if stat.S_ISLNK(before_metadata.st_mode) or not stat.S_ISDIR(before_metadata.st_mode):
    raise SystemExit("recovery snapshot root is linked or special")
count = 0
total = 0
stack = [(before, 0)]
while stack:
    directory, depth = stack.pop()
    with os.scandir(directory) as entries:
        for entry in entries:
            path = Path(entry.path)
            metadata = entry.stat(follow_symlinks=False)
            count += 1
            if count > max_entries:
                raise SystemExit("recovery snapshot scan entry bound exceeded")
            next_depth = depth + 1
            if next_depth > max_depth:
                raise SystemExit(f"recovery snapshot scan depth bound exceeded: {path}")
            if stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"recovery snapshot is linked or special: {path}")
            if stat.S_ISDIR(metadata.st_mode):
                stack.append((path, next_depth))
            elif stat.S_ISREG(metadata.st_mode):
                total += metadata.st_size
                if total > max_bytes:
                    raise SystemExit("recovery snapshot scan byte bound exceeded")
            else:
                raise SystemExit(f"recovery snapshot is linked or special: {path}")

for name, state in states.items():
    snapshot = before / name
    exists = os.path.lexists(snapshot)
    if state == "PRESENT" and not exists:
        raise SystemExit(f"recovery snapshot is missing: {snapshot}")
    if state != "PRESENT" and exists:
        raise SystemExit(f"unexpected recovery snapshot: {snapshot}")
PY
  validate_import_transaction_for_recovery || return $?
}

restore_systemd_transaction() {
  python3 - "$SERVICE_DIR" "$SYSTEMD_TRANSACTION_DIR" "$(managed_systemd_entries)" "$STATE_FILE_MAX_BYTES" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" <<'PY'
import os
import shutil
import stat
import sys
from pathlib import Path

service_dir = Path(sys.argv[1])
transaction = Path(sys.argv[2])
managed = [value for value in sys.argv[3].splitlines() if value]
state_limit = int(sys.argv[4])
max_entries = int(sys.argv[5])
max_depth = int(sys.argv[6])
max_bytes = int(sys.argv[7])
before = transaction / "before"
recovery_stage = transaction / "recovery-staged"
states = {}
state_path = transaction / "state.tsv"
state_metadata = state_path.lstat()
if stat.S_ISLNK(state_metadata.st_mode) or not stat.S_ISREG(state_metadata.st_mode) or state_metadata.st_size > state_limit:
    raise SystemExit("invalid systemd transaction state")
state_fd = os.open(state_path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    opened_state = os.fstat(state_fd)
    if (opened_state.st_dev, opened_state.st_ino) != (state_metadata.st_dev, state_metadata.st_ino):
        raise SystemExit("systemd transaction state changed identity")
    state_data = os.read(state_fd, state_limit + 1)
    if len(state_data) > state_limit or os.read(state_fd, 1):
        raise SystemExit("systemd transaction state exceeds bounded limit")
finally:
    os.close(state_fd)
for line in state_data.decode("utf-8").splitlines():
    fields = line.split("\t", 2)
    if len(fields) < 2:
        raise SystemExit("invalid systemd transaction state")
    name, state = fields[:2]
    target = fields[2] if len(fields) == 3 else ""
    if name in states or name not in managed or state not in {"ABSENT", "PRESENT", "SYMLINK"}:
        raise SystemExit("invalid systemd transaction state")
    if state == "SYMLINK" and (not target or "\n" in target):
        raise SystemExit("invalid systemd transaction symlink state")
    if state != "SYMLINK" and target:
        raise SystemExit("invalid systemd transaction state payload")
    states[name] = (state, target)
if set(states) != set(managed):
    raise SystemExit("incomplete systemd transaction state")

def remove(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)

def copy_file(source: Path, destination: Path, metadata) -> None:
    source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, stat.S_IMODE(metadata.st_mode))
    try:
        opened = os.fstat(source_fd)
        if (opened.st_dev, opened.st_ino, opened.st_mode) != (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mode,
        ):
            raise SystemExit(f"recovery snapshot changed identity: {source}")
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                view = view[os.write(destination_fd, view):]
        os.fsync(destination_fd)
    finally:
        os.close(source_fd)
        os.close(destination_fd)

def copy_snapshot(source: Path, destination: Path) -> None:
    root_metadata = source.lstat()
    if stat.S_ISLNK(root_metadata.st_mode):
        raise SystemExit(f"recovery snapshot is linked or special: {source}")
    if stat.S_ISREG(root_metadata.st_mode):
        destination.parent.mkdir(parents=True, exist_ok=True)
        copy_file(source, destination, root_metadata)
        return
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise SystemExit(f"recovery snapshot is linked or special: {source}")
    destination.mkdir(parents=True, mode=stat.S_IMODE(root_metadata.st_mode))
    count = 0
    total = 0
    stack = [(source, destination, 0)]
    while stack:
        source_dir, destination_dir, depth = stack.pop()
        with os.scandir(source_dir) as entries:
            for entry in entries:
                source_path = Path(entry.path)
                destination_path = destination_dir / entry.name
                metadata = entry.stat(follow_symlinks=False)
                count += 1
                if count > max_entries:
                    raise SystemExit("recovery copy scan entry bound exceeded")
                next_depth = depth + 1
                if next_depth > max_depth:
                    raise SystemExit(f"recovery copy scan depth bound exceeded: {source_path}")
                if stat.S_ISLNK(metadata.st_mode):
                    raise SystemExit(f"recovery snapshot is linked or special: {source_path}")
                if stat.S_ISDIR(metadata.st_mode):
                    destination_path.mkdir(mode=stat.S_IMODE(metadata.st_mode))
                    stack.append((source_path, destination_path, next_depth))
                elif stat.S_ISREG(metadata.st_mode):
                    total += metadata.st_size
                    if total > max_bytes:
                        raise SystemExit("recovery copy scan byte bound exceeded")
                    copy_file(source_path, destination_path, metadata)
                else:
                    raise SystemExit(f"recovery snapshot is linked or special: {source_path}")

if os.path.lexists(recovery_stage):
    if recovery_stage.is_symlink() or not recovery_stage.is_dir():
        raise SystemExit("recovery staging path is linked or special")
    shutil.rmtree(recovery_stage)
recovery_stage.mkdir(mode=0o700)
for name, (state, _target) in states.items():
    if state == "PRESENT":
        copy_snapshot(before / name, recovery_stage / name)

for base, directories, files in os.walk(recovery_stage, topdown=False, followlinks=False):
    base_path = Path(base)
    for name in files:
        descriptor = os.open(base_path / name, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    descriptor = os.open(base_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

for name in managed:
    for parent in (service_dir / name).parents:
        if parent == service_dir:
            break
        if parent.is_symlink():
            raise SystemExit(f"managed systemd recovery parent is a symlink: {parent}")
    remove(service_dir / name)
for name in managed:
    state, target = states[name]
    if state == "ABSENT":
        continue
    destination = service_dir / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    if state == "SYMLINK":
        destination.symlink_to(target)
        continue
    source = recovery_stage / name
    mode = source.lstat().st_mode
    if stat.S_ISLNK(mode):
        raise SystemExit(f"linked systemd snapshot entry: {name}")
    if stat.S_ISDIR(mode) or stat.S_ISREG(mode):
        os.replace(source, destination)
    else:
        raise SystemExit(f"unsupported systemd snapshot entry: {name}")

shutil.rmtree(recovery_stage)

for name in managed:
    path = service_dir / name
    if not os.path.lexists(path) or path.is_symlink():
        continue
    mode = path.lstat().st_mode
    if stat.S_ISREG(mode):
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    elif stat.S_ISDIR(mode):
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    else:
        continue
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
fd = os.open(service_dir, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

recover_activation_transaction() {
  local context="${1:-activation}"
  local format=""
  local phase=""
  local old_current=""
  local old_previous=""
  local old_public=""
  local new_current=""
  local systemd_transaction=""
  local systemd_observation=""
  local daemon_observation=""
  local public_cli="$BIN_DIR/codexswitch-cli"

  [[ -f "$ACTIVATION_JOURNAL" && ! -L "$ACTIVATION_JOURNAL" ]] || fail "activation journal is missing or unsafe: $ACTIVATION_JOURNAL"
  python3 - "$ACTIVATION_JOURNAL" "$STATE_FILE_MAX_BYTES" <<'PY' || return $?
import os
import stat
import sys

path = sys.argv[1]
limit = int(sys.argv[2])
metadata = os.lstat(path)
if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode) or metadata.st_size > limit:
    raise SystemExit("activation journal is linked, special, or oversized")
descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
        raise SystemExit("activation journal changed identity")
    data = os.read(descriptor, limit + 1)
    if len(data) > limit or os.read(descriptor, 1):
        raise SystemExit("activation journal is oversized")
finally:
    os.close(descriptor)
lines = data.decode("utf-8").splitlines()
expected = [
    "format", "phase", "old_current", "old_previous", "old_public",
    "new_current", "systemd_transaction", "systemd_observation",
    "daemon_observation",
]
fields = [line.split("\t", 1) for line in lines]
if len(fields) != len(expected) or any(len(field) != 2 for field in fields):
    raise SystemExit("activation journal structure is invalid")
if [field[0] for field in fields] != expected:
    raise SystemExit("activation journal keys are invalid")
if fields[1][1] not in {"prepared", "current_updated", "previous_updated", "committed"}:
    raise SystemExit("activation journal phase is invalid")
PY
  format="$(manifest_value "$ACTIVATION_JOURNAL" format)"
  [[ "$format" == "codexswitch-activation-v4" ]] || fail "unsupported activation journal: $ACTIVATION_JOURNAL"
  phase="$(manifest_value "$ACTIVATION_JOURNAL" phase)"
  old_current="$(manifest_value "$ACTIVATION_JOURNAL" old_current)"
  old_previous="$(manifest_value "$ACTIVATION_JOURNAL" old_previous)"
  old_public="$(manifest_value "$ACTIVATION_JOURNAL" old_public)"
  new_current="$(manifest_value "$ACTIVATION_JOURNAL" new_current)"
  systemd_transaction="$(manifest_value "$ACTIVATION_JOURNAL" systemd_transaction)"
  systemd_observation="$(manifest_value "$ACTIVATION_JOURNAL" systemd_observation)"
  daemon_observation="$(manifest_value "$ACTIVATION_JOURNAL" daemon_observation)"
  [[ "$systemd_observation" == "inactive" && "$daemon_observation" == "inactive" ]] || fail "activation journal lacks positive inactive runtime evidence"
  [[ "$RUNTIME_GUARDS_HELD" == "1" ]] || fail "activation recovery requires both runtime guards"
  require_managed_runtime_inactive final-recovery 1
  validate_journal_target "$old_current" old_current || return $?
  validate_journal_target "$old_previous" old_previous || return $?
  validate_journal_target "$new_current" new_current || return $?

  if [[ "$phase" == "committed" ]]; then
    [[ "$systemd_transaction" =~ ^\.codexswitch-activation\.[1-9][0-9]*$ ]] || fail "activation journal has unsafe committed systemd transaction"
    SYSTEMD_TRANSACTION_DIR="$SERVICE_DIR/$systemd_transaction"
    validate_derived_path SYSTEMD_TRANSACTION_DIR "$SERVICE_DIR" "$SYSTEMD_TRANSACTION_DIR"
    if [[ -e "$SYSTEMD_TRANSACTION_DIR" || -L "$SYSTEMD_TRANSACTION_DIR" ]]; then
      validate_systemd_transaction "$systemd_transaction" || return $?
      validate_recovery_payload "$old_public" || return $?
      remove_tree_without_links "$SYSTEMD_TRANSACTION_DIR" || return $?
      fsync_directory "$SERVICE_DIR" || return $?
    fi
    remove_activation_journal || return $?
    SYSTEMD_TRANSACTION_DIR=""
    ACTIVATION_TRANSACTION_ACTIVE=0
    echo "Completed cleanup for committed activation transaction ($context)" >&2
    return 0
  fi

  validate_systemd_transaction "$systemd_transaction" || return $?
  validate_recovery_payload "$old_public" || return $?

  if [[ "$TEST_MODE" == "1" && "$TEST_FAULT_POINT" == "rollback_recovery" ]]; then
    echo "ERROR: injected activation fault at rollback_recovery" >&2
    return 97
  fi

  restore_import_transaction || return $?
  restore_systemd_transaction || return $?
  systemctl --user daemon-reload || return $?
  restore_managed_link "$CURRENT_LINK" "$old_current" || return $?
  restore_managed_link "$PREVIOUS_LINK" "$old_previous" || return $?
  if [[ "$old_public" == "ABSENT" ]]; then
    [[ ! -e "$public_cli" || -L "$public_cli" ]] || fail "refusing to remove non-symlink public CLI during recovery"
    rm -f -- "$public_cli"
    fsync_directory "$BIN_DIR" || return $?
  else
    atomic_symlink "$old_public" "$public_cli" || return $?
  fi
  remove_activation_journal || return $?
  remove_tree_without_links "$SYSTEMD_TRANSACTION_DIR" || return $?
  fsync_directory "$SERVICE_DIR" || return $?
  SYSTEMD_TRANSACTION_DIR=""
  ACTIVATION_TRANSACTION_ACTIVE=0
  echo "Recovered incomplete activation transaction ($context)" >&2
}

managed_release_from_link() {
  local link="$1"
  local label="$2"
  local target=""
  local release_id=""
  local release_dir=""

  if [[ ! -e "$link" && ! -L "$link" ]]; then
    return 1
  fi
  [[ -L "$link" ]] || fail "$label path is not a symlink: $link"
  target="$(readlink "$link")"
  case "$target" in
    releases/*)
      release_id="${target#releases/}"
      ;;
    "$RELEASES_DIR"/*)
      release_id="${target#"$RELEASES_DIR"/}"
      target="releases/$release_id"
      ;;
    *) fail "$label symlink has an unmanaged target: $target" ;;
  esac
  [[ -n "$release_id" && "$release_id" != */* && "$release_id" != *..* ]] || fail "$label symlink target is unsafe: $target"
  release_dir="$RELEASES_DIR/$release_id"
  validate_release "$release_dir"
  printf '%s\n' "$target"
}
