# shellcheck shell=bash
begin_systemd_transaction() {
  local systemd_source="$RELEASE_DIR/systemd"
  local transaction_name=".codexswitch-activation.$$"

  validate_systemd_payload "$systemd_source"
  mkdir -p "$SERVICE_DIR"
  SYSTEMD_TRANSACTION_DIR="$SERVICE_DIR/$transaction_name"
  validate_derived_path SYSTEMD_TRANSACTION_DIR "$SERVICE_DIR" "$SYSTEMD_TRANSACTION_DIR"
  mkdir -m 0700 "$SYSTEMD_TRANSACTION_DIR"
  python3 - "$SYSTEMD_TRANSACTION_DIR/owner.tsv" "$$" "$(process_start_identity "$$")" "$ACTIVATION_LOCK_TOKEN" "$TRANSACTION_OWNER_KEY" <<'PY'
import hashlib
import hmac
import os
import secrets
import sys
from pathlib import Path

path = Path(sys.argv[1])
pid, start, lock_token = sys.argv[2:5]
key_path = Path(sys.argv[5])
directory_metadata = path.parent.stat()
token = secrets.token_hex(32)
generation = secrets.token_hex(32)
fields = (
    ("format", "codexswitch-systemd-transaction-v2"),
    ("pid", pid),
    ("start", start),
    ("lock_token", lock_token),
    ("token", token),
    ("generation", generation),
    ("directory_dev", str(directory_metadata.st_dev)),
    ("directory_ino", str(directory_metadata.st_ino)),
)
signing_key = bytes.fromhex(key_path.read_text(encoding="ascii").strip())
payload = "".join(f"{name}\t{value}\n" for name, value in fields).encode()
signature = hmac.new(signing_key, payload, hashlib.sha256).hexdigest()
descriptor = os.open(
    path,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
    0o600,
)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    handle.write(payload.decode("utf-8"))
    handle.write(f"signature\t{signature}\n")
    handle.flush()
    os.fsync(handle.fileno())
for directory_path in (path.parent, path.parent.parent):
    directory = os.open(directory_path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
PY
  python3 - "$SERVICE_DIR" "$SYSTEMD_TRANSACTION_DIR" "$(managed_systemd_entries)" "$TEST_MODE" "$TEST_FAULT_POINT" "$TEST_FAULT_MODE" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" <<'PY'
import os
import signal
import shutil
import stat
import sys
from pathlib import Path

service_dir = Path(sys.argv[1])
transaction = Path(sys.argv[2])
managed = [value for value in sys.argv[3].splitlines() if value]
test_mode = sys.argv[4]
test_fault_point = sys.argv[5]
test_fault_mode = sys.argv[6]
max_entries = int(sys.argv[7])
max_depth = int(sys.argv[8])
max_bytes = int(sys.argv[9])
before = transaction / "before"
before.mkdir(mode=0o700)
state = transaction / "state.tsv"

def reject_links(path: Path) -> None:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)):
        raise SystemExit(f"unsafe managed systemd entry: {path}")
    if stat.S_ISREG(metadata.st_mode):
        if metadata.st_size > max_bytes:
            raise SystemExit("managed systemd snapshot scan byte bound exceeded")
        return
    count = 0
    total = 0
    stack = [(path, 0)]
    while stack:
        directory, depth = stack.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                candidate = Path(entry.path)
                child = entry.stat(follow_symlinks=False)
                count += 1
                if count > max_entries:
                    raise SystemExit("managed systemd snapshot scan entry bound exceeded")
                next_depth = depth + 1
                if next_depth > max_depth:
                    raise SystemExit(f"managed systemd snapshot scan depth bound exceeded: {candidate}")
                if stat.S_ISLNK(child.st_mode):
                    raise SystemExit(f"unsafe managed systemd entry: {candidate}")
                if stat.S_ISDIR(child.st_mode):
                    stack.append((candidate, next_depth))
                elif stat.S_ISREG(child.st_mode):
                    total += child.st_size
                    if total > max_bytes:
                        raise SystemExit("managed systemd snapshot scan byte bound exceeded")
                else:
                    raise SystemExit(f"unsafe managed systemd entry: {candidate}")

def inject_partial_snapshot_fault(index: int, handle) -> None:
    if index != 0 or test_mode != "1" or test_fault_point != "partial_snapshot":
        return
    handle.flush()
    os.fsync(handle.fileno())
    for directory_path in (before, transaction):
        descriptor = os.open(directory_path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    if test_fault_mode == "crash":
        os.kill(os.getppid(), signal.SIGKILL)
        os._exit(97)
    raise SystemExit("injected activation fault at partial_snapshot")

with state.open("x", encoding="utf-8") as handle:
    for index, name in enumerate(managed):
        source = service_dir / name
        for parent in source.parents:
            if parent == service_dir:
                break
            if parent.is_symlink():
                raise SystemExit(f"managed systemd parent is a symlink: {parent}")
        if not source.exists() and not source.is_symlink():
            handle.write(f"{name}\tABSENT\n")
            inject_partial_snapshot_fault(index, handle)
            continue
        if source.is_symlink():
            target = os.readlink(source)
            if "\t" in target or "\n" in target:
                raise SystemExit(f"unsafe managed systemd symlink target: {source}")
            handle.write(f"{name}\tSYMLINK\t{target}\n")
            inject_partial_snapshot_fault(index, handle)
            continue
        reject_links(source)
        handle.write(f"{name}\tPRESENT\n")
        (before / name).parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, before / name, symlinks=False)
        else:
            shutil.copy2(source, before / name, follow_symlinks=False)
        inject_partial_snapshot_fault(index, handle)
    handle.flush()
    os.fsync(handle.fileno())
for directory in (before, transaction, service_dir):
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
  snapshot_import_transaction
  fsync_tree "$SYSTEMD_TRANSACTION_DIR/before"
  mkdir -m 0700 "$SYSTEMD_TRANSACTION_DIR/staged"
  cp -a -- "$systemd_source/." "$SYSTEMD_TRANSACTION_DIR/staged/"
  chmod_tree_bounded "$SYSTEMD_TRANSACTION_DIR/staged" 0644 0755
  validate_systemd_payload "$SYSTEMD_TRANSACTION_DIR/staged"
  fsync_tree "$SYSTEMD_TRANSACTION_DIR/staged"
}

apply_systemd_transaction() {
  python3 - "$SERVICE_DIR" "$SYSTEMD_TRANSACTION_DIR/staged" "$(managed_systemd_entries)" <<'PY'
import os
import shutil
import sys
from pathlib import Path

service_dir = Path(sys.argv[1])
staged = Path(sys.argv[2])
managed = [value for value in sys.argv[3].splitlines() if value]
targets = {
    "codexswitch.service",
    "codexswitch.service.d",
    "signul-codex-app-server.service",
    "signul-codex-app-server.service.d",
}

def remove(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)

for name in managed:
    for parent in (service_dir / name).parents:
        if parent == service_dir:
            break
        if parent.is_symlink():
            raise SystemExit(f"managed systemd parent is a symlink: {parent}")
    remove(service_dir / name)
for name in sorted(targets):
    os.replace(staged / name, service_dir / name)
parents = {service_dir, *((service_dir / name).parent for name in managed)}
for parent in sorted(parents, key=lambda value: len(value.parts), reverse=True):
    if not parent.is_dir() or parent.is_symlink():
        continue
    fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
  systemctl --user daemon-reload
  validate_merged_systemd_unit codexswitch.service
  validate_merged_systemd_unit signul-codex-app-server.service
  validate_effective_systemd_resources
  validate_effective_systemd_dependencies
}

complete_systemd_transaction() {
  remove_tree_without_links "$SYSTEMD_TRANSACTION_DIR"
  fsync_directory "$SERVICE_DIR"
  SYSTEMD_TRANSACTION_DIR=""
}

prune_abandoned_systemd_transactions() {
  local retained_count="$((SYSTEMD_TRANSACTION_MAX_COUNT - 1))"

  [[ ! -e "$ACTIVATION_JOURNAL" ]] || return 0
  [[ -d "$SERVICE_DIR" ]] || return 0
  python3 - "$SERVICE_DIR" "$retained_count" "$SYSTEMD_TRANSACTION_MAX_AGE_HOURS" "$SYSTEMD_TRANSACTION_MAX_BYTES" "$TRANSACTION_OWNER_KEY" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" "$STATE_FILE_MAX_BYTES" "$PROC_ROOT" <<'PY'
import hashlib
import hmac
import os
import re
import shutil
import stat
import sys
import time
from pathlib import Path

service_dir = Path(sys.argv[1])
max_count = int(sys.argv[2])
max_age_seconds = int(sys.argv[3]) * 3600
max_bytes = int(sys.argv[4])
key_path = Path(sys.argv[5])
scan_max_entries = int(sys.argv[6])
scan_max_depth = int(sys.argv[7])
scan_max_bytes = int(sys.argv[8])
state_max_bytes = int(sys.argv[9])
proc_root = Path(sys.argv[10])
pattern = re.compile(r"^\.codexswitch-activation\.[1-9][0-9]*$")
now = time.time()
removed = False
key = bytes.fromhex(key_path.read_text(encoding="ascii").strip())

def tree_size(path: Path) -> int:
    total = 0
    count = 0
    stack = [(path, 0)]
    while stack:
        directory, depth = stack.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                candidate = Path(entry.path)
                metadata = entry.stat(follow_symlinks=False)
                count += 1
                if count > scan_max_entries:
                    raise SystemExit("abandoned transaction scan entry bound exceeded")
                next_depth = depth + 1
                if next_depth > scan_max_depth:
                    raise SystemExit(f"abandoned transaction scan depth bound exceeded: {candidate}")
                if stat.S_ISLNK(metadata.st_mode):
                    raise SystemExit(f"unsafe abandoned systemd transaction link: {candidate}")
                if stat.S_ISDIR(metadata.st_mode):
                    stack.append((candidate, next_depth))
                elif stat.S_ISREG(metadata.st_mode):
                    total += metadata.st_size
                    if total > scan_max_bytes:
                        raise SystemExit("abandoned transaction scan byte bound exceeded")
                else:
                    raise SystemExit(f"unsafe abandoned systemd transaction special entry: {candidate}")
    return total

def validated_owner(path: Path):
    owner = path / "owner.tsv"
    if not owner.is_file() or owner.is_symlink():
        return None
    directory_metadata = path.lstat()
    if stat.S_ISLNK(directory_metadata.st_mode) or not stat.S_ISDIR(directory_metadata.st_mode):
        return None
    if stat.S_IMODE(directory_metadata.st_mode) != 0o700:
        return None
    directory_fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        opened_directory = os.fstat(directory_fd)
        if (opened_directory.st_dev, opened_directory.st_ino) != (
            directory_metadata.st_dev,
            directory_metadata.st_ino,
        ):
            return None
        owner_metadata = owner.lstat()
        if owner_metadata.st_size > state_max_bytes or stat.S_IMODE(owner_metadata.st_mode) != 0o600:
            return None
        owner_fd = os.open("owner.tsv", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
        try:
            opened_owner = os.fstat(owner_fd)
            if (opened_owner.st_dev, opened_owner.st_ino) != (
                owner_metadata.st_dev,
                owner_metadata.st_ino,
            ):
                return None
            raw = os.read(owner_fd, state_max_bytes + 1)
            if len(raw) > state_max_bytes or os.read(owner_fd, 1):
                return None
        finally:
            os.close(owner_fd)
    finally:
        os.close(directory_fd)
    values = {}
    ordered = []
    for line in raw.decode("utf-8").splitlines():
        field_name, separator, value = line.partition("\t")
        if not separator or field_name in values:
            return None
        values[field_name] = value
        ordered.append((field_name, value))
    expected_keys = [
        "format", "pid", "start", "lock_token", "token", "generation",
        "directory_dev", "directory_ino", "signature",
    ]
    if [name for name, _value in ordered] != expected_keys:
        return None
    payload = "".join(f"{name}\t{value}\n" for name, value in ordered[:-1]).encode()
    expected_signature = hmac.new(key, payload, hashlib.sha256).hexdigest()
    if not all((
        values["format"] == "codexswitch-systemd-transaction-v2",
        values["pid"] == path.name.rsplit(".", 1)[-1],
        bool(re.fullmatch(r"(?:[0-9]+|UNKNOWN)", values["start"])),
        bool(re.fullmatch(r"[0-9a-f]{32}", values["lock_token"])),
        bool(re.fullmatch(r"[0-9a-f]{64}", values["token"])),
        bool(re.fullmatch(r"[0-9a-f]{64}", values["generation"])),
        values["directory_dev"] == str(directory_metadata.st_dev),
        values["directory_ino"] == str(directory_metadata.st_ino),
        hmac.compare_digest(values["signature"], expected_signature),
    )):
        return None
    return values

def owner_process_is_live(values) -> bool:
    pid = int(values["pid"])
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    if values["start"] == "UNKNOWN":
        return True
    process_state = proc_root / str(pid) / "stat"
    try:
        metadata = process_state.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            return True
        descriptor = os.open(process_state, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                return True
            raw_bytes = os.read(descriptor, 4097)
            if len(raw_bytes) > 4096 or os.read(descriptor, 1):
                return True
        finally:
            os.close(descriptor)
        raw = raw_bytes.decode("utf-8")
    except OSError:
        return True
    fields = raw[raw.rfind(")") + 2 :].split()
    observed = fields[19] if len(fields) > 19 else "UNKNOWN"
    return observed == values["start"]

owned = []
root_count = 0
with os.scandir(service_dir) as root_entries:
  for root_entry in root_entries:
    path = Path(root_entry.path)
    if not pattern.fullmatch(path.name):
        continue
    root_count += 1
    if root_count > scan_max_entries:
        raise SystemExit("transaction root scan entry bound exceeded")
    owner = validated_owner(path)
    if owner is None:
        raise SystemExit(f"unowned abandoned systemd transaction: {path}")
    size = tree_size(path)
    mtime = path.stat().st_mtime
    owned.append([path, mtime, size, path.stat().st_dev, path.stat().st_ino, owner])

def remove(entry) -> None:
    global removed
    metadata = entry[0].lstat()
    if (metadata.st_dev, metadata.st_ino) != (entry[3], entry[4]):
        raise SystemExit(f"abandoned transaction changed identity: {entry[0]}")
    shutil.rmtree(entry[0])
    removed = True

for entry in list(owned):
    if not owner_process_is_live(entry[5]) or now - entry[1] > max_age_seconds:
        remove(entry)
        owned.remove(entry)
owned.sort(key=lambda entry: (entry[1], entry[0].name))
while len(owned) > max_count:
    remove(owned.pop(0))
while sum(entry[2] for entry in owned) > max_bytes:
    remove(owned.pop(0))

if removed:
    fd = os.open(service_dir, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
}
enforce_systemd_transaction_storage_bound() {
  python3 - "$SERVICE_DIR" "$SYSTEMD_TRANSACTION_MAX_COUNT" "$SYSTEMD_TRANSACTION_MAX_BYTES" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" <<'PY'
import os
import re
import stat
import sys
from pathlib import Path

service_dir = Path(sys.argv[1])
max_count = int(sys.argv[2])
max_bytes = int(sys.argv[3])
scan_max_entries = int(sys.argv[4])
scan_max_depth = int(sys.argv[5])
scan_max_bytes = int(sys.argv[6])
pattern = re.compile(r"^\.codexswitch-activation\.[1-9][0-9]*$")
transaction_count = 0
scan_count = 0
total = 0
with os.scandir(service_dir) as root_entries:
 for root_entry in root_entries:
    path = Path(root_entry.path)
    if not pattern.fullmatch(path.name):
        continue
    if path.is_symlink() or not path.is_dir():
        raise SystemExit(f"unsafe systemd transaction storage entry: {path}")
    transaction_count += 1
    stack = [(path, 0)]
    while stack:
        directory, depth = stack.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                candidate = Path(entry.path)
                metadata = entry.stat(follow_symlinks=False)
                scan_count += 1
                if scan_count > scan_max_entries:
                    raise SystemExit("systemd transaction scan entry bound exceeded")
                next_depth = depth + 1
                if next_depth > scan_max_depth:
                    raise SystemExit(f"systemd transaction scan depth bound exceeded: {candidate}")
                if stat.S_ISLNK(metadata.st_mode):
                    raise SystemExit(f"unsafe systemd transaction storage link: {candidate}")
                if stat.S_ISDIR(metadata.st_mode):
                    stack.append((candidate, next_depth))
                elif stat.S_ISREG(metadata.st_mode):
                    total += metadata.st_size
                    if total > scan_max_bytes:
                        raise SystemExit("systemd transaction scan byte bound exceeded")
                else:
                    raise SystemExit(f"unsafe systemd transaction storage special entry: {candidate}")
if transaction_count > max_count or total > max_bytes:
    raise SystemExit(
        f"systemd transaction storage exceeds bounds: count={transaction_count}/{max_count}, bytes={total}/{max_bytes}"
    )
PY
}
