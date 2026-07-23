# shellcheck shell=bash
validate_source_destination() {
  if [[ -e "$SOURCE_DIR" && ! -d "$SOURCE_DIR" ]]; then
    fail "source path exists and is not a directory: $SOURCE_DIR"
  fi
  if directory_is_nonempty "$SOURCE_DIR" && ! is_git_worktree "$SOURCE_DIR"; then
    fail "refusing to clone into nonempty non-Git directory: $SOURCE_DIR"
  fi
}

directory_size_bytes() {
  local path="$1"
  [[ -e "$path" ]] || { printf '0\n'; return; }
  python3 - "$path" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" <<'PY'
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
max_entries, max_depth, max_bytes = map(int, sys.argv[2:])
metadata = root.lstat()
if stat.S_ISLNK(metadata.st_mode):
    raise SystemExit(f"size inventory root is a symlink: {root}")
if stat.S_ISREG(metadata.st_mode):
    print(metadata.st_size)
    raise SystemExit(0)
if not stat.S_ISDIR(metadata.st_mode):
    raise SystemExit(f"size inventory root is special: {root}")
count = 0
total = 0
stack = [(root, 0)]
while stack:
    directory, depth = stack.pop()
    with os.scandir(directory) as entries:
        for entry in entries:
            path = Path(entry.path)
            child = entry.stat(follow_symlinks=False)
            count += 1
            if count > max_entries:
                raise SystemExit("size inventory scan entry bound exceeded")
            next_depth = depth + 1
            if next_depth > max_depth:
                raise SystemExit(f"size inventory scan depth bound exceeded: {path}")
            if stat.S_ISLNK(child.st_mode):
                raise SystemExit(f"size inventory contains a symlink: {path}")
            if stat.S_ISDIR(child.st_mode):
                stack.append((path, next_depth))
            elif stat.S_ISREG(child.st_mode):
                total += child.st_size
                if total > max_bytes:
                    raise SystemExit("size inventory scan byte bound exceeded")
            else:
                raise SystemExit(f"size inventory contains a special entry: {path}")
print(total)
PY
}

available_bytes() {
  python3 - "$1" <<'PY'
import shutil
import sys

print(shutil.disk_usage(sys.argv[1]).free)
PY
}

acquire_build_lock() {
  local owner_pid=""
  local owner_start=""
  local owner_token=""
  local owner_format=""
  local observed_start=""

  mkdir -p "$BUILD_ROOT"
  validate_build_derived_path BUILD_LOCK_DIR "$BUILD_LOCK_DIR"
  if mkdir "$BUILD_LOCK_DIR" 2>/dev/null; then
    BUILD_LOCK_HELD=1
    BUILD_LOCK_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    owner_start="$(process_start_identity "$$")"
    python3 - "$BUILD_LOCK_DIR/owner.tsv" "$$" "$owner_start" "$BUILD_LOCK_TOKEN" <<'PY'
import os
import sys

path, pid, start, token = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write("format\tcodexswitch-build-lock-v1\n")
    handle.write(f"pid\t{pid}\n")
    handle.write(f"start\t{start}\n")
    handle.write(f"token\t{token}\n")
    handle.flush()
    os.fsync(handle.fileno())
directory = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
    return
  fi
  [[ -d "$BUILD_LOCK_DIR" && ! -L "$BUILD_LOCK_DIR" ]] || fail "build lock owner record is invalid: $BUILD_LOCK_DIR"
  [[ -f "$BUILD_LOCK_DIR/owner.tsv" && ! -L "$BUILD_LOCK_DIR/owner.tsv" ]] || fail "build lock owner record is invalid: $BUILD_LOCK_DIR"
  [[ -z "$(find "$BUILD_LOCK_DIR" -mindepth 1 -maxdepth 1 ! -name owner.tsv -print -quit)" ]] || fail "build lock owner record is invalid: $BUILD_LOCK_DIR"
  owner_format="$(manifest_value "$BUILD_LOCK_DIR/owner.tsv" format 2>/dev/null || true)"
  owner_pid="$(manifest_value "$BUILD_LOCK_DIR/owner.tsv" pid 2>/dev/null || true)"
  owner_start="$(manifest_value "$BUILD_LOCK_DIR/owner.tsv" start 2>/dev/null || true)"
  owner_token="$(manifest_value "$BUILD_LOCK_DIR/owner.tsv" token 2>/dev/null || true)"
  [[ "$owner_format" == "codexswitch-build-lock-v1" && "$owner_pid" =~ ^[1-9][0-9]*$ && "$owner_start" =~ ^([0-9]+|UNKNOWN)$ && "$owner_token" =~ ^[0-9a-f]{64}$ ]] || fail "build lock owner record is invalid: $BUILD_LOCK_DIR"
  if kill -0 "$owner_pid" 2>/dev/null; then
    observed_start="$(process_start_identity "$owner_pid")"
    [[ "$owner_start" != "UNKNOWN" && "$observed_start" != "$owner_start" ]] || fail "another build holds $BUILD_LOCK_DIR"
  else
    [[ "$owner_start" != "UNKNOWN" ]] || fail "build lock owner identity cannot be proven stale: $BUILD_LOCK_DIR"
  fi
  remove_tree_without_links "$BUILD_LOCK_DIR" || fail "failed to remove proven stale build lock: $BUILD_LOCK_DIR"
  acquire_build_lock
}

release_build_lock() {
  local recorded_token=""

  [[ "$BUILD_LOCK_HELD" == "1" ]] || return 0
  [[ -f "$BUILD_LOCK_DIR/owner.tsv" && ! -L "$BUILD_LOCK_DIR/owner.tsv" ]] || fail "owned build lock record disappeared"
  recorded_token="$(manifest_value "$BUILD_LOCK_DIR/owner.tsv" token)"
  [[ -n "$BUILD_LOCK_TOKEN" && "$recorded_token" == "$BUILD_LOCK_TOKEN" ]] || fail "owned build lock token changed"
  remove_tree_without_links "$BUILD_LOCK_DIR"
  BUILD_LOCK_HELD=0
  BUILD_LOCK_TOKEN=""
}

prune_owned_build_storage() {
  python3 - "$BUILD_ROOT" "$BUILD_RETENTION_MAX_COUNT" "$BUILD_RETENTION_MAX_AGE_HOURS" "$BUILD_MAX_BYTES" <<'PY'
import os
import re
import shutil
import stat
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
max_count = int(sys.argv[2])
max_age = int(sys.argv[3]) * 3600
max_bytes = int(sys.argv[4])
now = time.time()
patterns = {
    "worktrees": re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})-[0-9]+$"),
    "stage": re.compile(r"^[0-9A-Za-z._+-]+-(?:[0-9a-f]{40}|[0-9a-f]{64})-[0-9]+$"),
    "cargo-target": re.compile(r"^shared$"),
}

def tree_size(path: Path) -> int:
    total = 0
    for base, dirs, files in os.walk(path, followlinks=False):
        base_path = Path(base)
        for name in dirs:
            item = base_path / name
            mode = item.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                raise SystemExit(f"owned build artifact contains a linked or special entry: {item}")
        for name in files:
            item = base_path / name
            mode = item.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
                raise SystemExit(f"owned build artifact contains a linked or special entry: {item}")
            total += item.stat().st_size
    return total

def remove_tree(path: Path) -> None:
    directories = [path]
    files = []
    for base, dirs, names in os.walk(path, followlinks=False):
        base_path = Path(base)
        for name in dirs:
            item = base_path / name
            mode = item.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                raise SystemExit(f"refusing to clean linked or special build entry: {item}")
            directories.append(item)
        for name in names:
            item = base_path / name
            mode = item.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
                raise SystemExit(f"refusing to clean linked or special build entry: {item}")
            files.append((item, mode))
    for item, mode in files:
        os.chmod(item, stat.S_IMODE(mode) | stat.S_IWUSR, follow_symlinks=False)
    for item in sorted(directories, key=lambda value: len(value.parts), reverse=True):
        mode = item.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise SystemExit(f"build artifact changed during cleanup: {item}")
        os.chmod(item, stat.S_IMODE(mode) | stat.S_IWUSR, follow_symlinks=False)
    shutil.rmtree(path)

owned = []
for parent_name, pattern in patterns.items():
    parent = root / parent_name
    if parent.is_symlink():
        raise SystemExit(f"derived build root is a symlink: {parent}")
    if not parent.exists():
        continue
    for child in parent.iterdir():
        if child.is_symlink() or not child.is_dir() or not pattern.fullmatch(child.name):
            continue
        owned.append((child, child.stat().st_mtime, tree_size(child)))

for path, mtime, _size in list(owned):
    if now - mtime <= max_age:
        continue
    remove_tree(path)
    owned = [entry for entry in owned if entry[0] != path]

if len(owned) > max_count:
    raise SystemExit(f"owned build artifacts exceed count bound: {len(owned)} > {max_count}")
if sum(size for _path, _mtime, size in owned) > max_bytes:
    raise SystemExit("owned build artifacts exceed byte bound after age cleanup")
PY
}

preflight_storage() {
  local free_bytes=""
  local build_bytes=""

  mkdir -p "$BUILD_ROOT" "$RELEASES_DIR" "$CARGO_TARGET_ROOT" "$WORKTREE_ROOT" "$BUILD_STAGE_ROOT"
  validate_derived_path RELEASES_DIR "$INSTALL_ROOT" "$RELEASES_DIR"
  validate_build_derived_path CARGO_TARGET_ROOT "$CARGO_TARGET_ROOT"
  validate_build_derived_path CARGO_TARGET_DIR "$CARGO_TARGET_DIR_PATH"
  validate_build_derived_path WORKTREE_ROOT "$WORKTREE_ROOT"
  validate_build_derived_path BUILD_STAGE_ROOT "$BUILD_STAGE_ROOT"
  prune_owned_build_storage
  free_bytes="$(available_bytes "$BUILD_ROOT")"
  [[ "$free_bytes" -ge "$BUILD_MIN_FREE_BYTES" ]] || fail "build filesystem free space $free_bytes is below required $BUILD_MIN_FREE_BYTES bytes"
  build_bytes="$(directory_size_bytes "$BUILD_ROOT")"
  [[ "$build_bytes" -le "$BUILD_MAX_BYTES" ]] || fail "build root uses $build_bytes bytes, above $BUILD_MAX_BYTES"
}

enforce_build_size_bound() {
  local build_bytes=""
  build_bytes="$(directory_size_bytes "$BUILD_ROOT")"
  [[ "$build_bytes" -le "$BUILD_MAX_BYTES" ]] || fail "build root grew to $build_bytes bytes, above $BUILD_MAX_BYTES"
}

enforce_runtime_storage_bounds() {
  [[ -e "$RUNTIME_STORAGE_ROOT" || -L "$RUNTIME_STORAGE_ROOT" ]] || return 0
  [[ -d "$RUNTIME_STORAGE_ROOT" && ! -L "$RUNTIME_STORAGE_ROOT" ]] || fail "runtime storage root must be a regular directory: $RUNTIME_STORAGE_ROOT"
  python3 - "$RUNTIME_STORAGE_ROOT" "$RUNTIME_STORAGE_MAX_COUNT" "$RUNTIME_STORAGE_MAX_AGE_DAYS" "$RUNTIME_STORAGE_MAX_BYTES" "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" "$TEST_MODE" <<'PY'
import fcntl
import os
import re
import stat
import sys
import time
import uuid
from pathlib import Path

root = Path(sys.argv[1])
max_count = int(sys.argv[2])
max_age_seconds = int(sys.argv[3]) * 86400
max_bytes = int(sys.argv[4])
scan_max_entries = int(sys.argv[5])
scan_max_depth = int(sys.argv[6])
scan_max_bytes = int(sys.argv[7])
test_mode = sys.argv[8] == "1"
now = time.time()
uuid_pattern = re.compile(
    r"(?<![0-9a-f])([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f])"
)

def canonical_uuid(value: str):
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        return None
    if str(parsed) != value or parsed.variant != uuid.RFC_4122:
        return None
    return str(parsed)

def uuid_from_name(name: str):
    matches = [
        parsed
        for match in uuid_pattern.finditer(name)
        if (parsed := canonical_uuid(match.group(1))) is not None
    ]
    return matches[0] if len(matches) == 1 else None

scan_entries = 0
scan_bytes = 0

def account_scan(path: Path, metadata: os.stat_result, depth: int) -> None:
    global scan_entries, scan_bytes
    scan_entries += 1
    if scan_entries > scan_max_entries:
        raise SystemExit(f"scan entry bound exceeded: count={scan_entries}>{scan_max_entries}")
    if depth > scan_max_depth:
        raise SystemExit(f"scan depth bound exceeded: depth={depth}>{scan_max_depth}: {path}")
    if stat.S_ISREG(metadata.st_mode):
        scan_bytes += metadata.st_size
        if scan_bytes > scan_max_bytes:
            raise SystemExit(f"scan byte bound exceeded: bytes={scan_bytes}>{scan_max_bytes}")

def require_real_directory(path: Path, label: str) -> bool:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise SystemExit(f"{label} is linked or special: {path}")
    return True

active_threads = set()
tmp_dir = root / ".tmp"
lease_dir = tmp_dir / "rollout-leases"
if require_real_directory(tmp_dir, "runtime lease ancestor") and require_real_directory(
    lease_dir, "runtime lease ancestor"
):
    with os.scandir(lease_dir) as entries:
        for entry in entries:
            lease = Path(entry.path)
            metadata = entry.stat(follow_symlinks=False)
            account_scan(lease, metadata, 1)
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise SystemExit(f"runtime lease entry is linked or special: {lease}")
            if not lease.name.endswith(".lock"):
                raise SystemExit(f"invalid runtime lease identifier: {lease.name}")
            thread_id = canonical_uuid(lease.name[:-5])
            if thread_id is None:
                raise SystemExit(f"invalid runtime lease identifier: {lease.name}")
            replacement = os.environ.get("CODEXSWITCH_TEST_LEASE_INODE_REPLACEMENT", "")
            if test_mode and replacement == str(lease):
                backup = lease.with_name(f".{lease.name}.replaced")
                os.replace(lease, backup)
                lease.write_text("replacement inode\n", encoding="utf-8")
            fd = os.open(lease, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                opened = os.fstat(fd)
                if (
                    opened.st_dev,
                    opened.st_ino,
                    stat.S_IFMT(opened.st_mode),
                ) != (
                    metadata.st_dev,
                    metadata.st_ino,
                    stat.S_IFMT(metadata.st_mode),
                ):
                    raise SystemExit(f"runtime lease entry changed identity: {lease}")
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    active_threads.add(thread_id)
                else:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)

file_count = 0
total_bytes = 0
oldest_age = 0
active_leased = 0

def account_runtime_file(path: Path, metadata: os.stat_result, depth: int) -> None:
    global file_count, total_bytes, oldest_age, active_leased
    account_scan(path, metadata, depth)
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise SystemExit(f"runtime/archive storage contains a linked or special entry: {path}")
    file_count += 1
    total_bytes += metadata.st_size
    oldest_age = max(oldest_age, max(0, int(now - metadata.st_mtime)))
    thread_id = uuid_from_name(path.name)
    if thread_id is not None and thread_id in active_threads:
        active_leased += 1

for storage_dir in (root / "sessions", root / "archived_sessions"):
    if not require_real_directory(storage_dir, "runtime/archive storage"):
        continue
    stack = [(storage_dir, 0)]
    while stack:
        directory, depth = stack.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                candidate = Path(entry.path)
                metadata = entry.stat(follow_symlinks=False)
                candidate_depth = depth + 1
                if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
                    account_scan(candidate, metadata, candidate_depth)
                    stack.append((candidate, candidate_depth))
                else:
                    account_runtime_file(candidate, metadata, candidate_depth)

with os.scandir(root) as entries:
    for entry in entries:
        if not re.fullmatch(r"logs_.*\.sqlite.*", entry.name):
            continue
        account_runtime_file(Path(entry.path), entry.stat(follow_symlinks=False), 1)

violations = []
if file_count > max_count:
    violations.append(f"count={file_count}>{max_count}")
if oldest_age > max_age_seconds:
    violations.append(f"oldest_age_seconds={oldest_age}>{max_age_seconds}")
if total_bytes > max_bytes:
    violations.append(f"bytes={total_bytes}>{max_bytes}")
if violations:
    raise SystemExit(
        "runtime/archive storage exceeds bounds: "
        + ", ".join(violations)
        + f"; active_leased={active_leased}; no files removed"
    )
PY
}

validate_release_pointers_for_retention() {
  [[ ! -e "$ACTIVATION_JOURNAL" && ! -L "$ACTIVATION_JOURNAL" ]] || fail "activation recovery is required before release retention"
  if [[ -e "$CURRENT_LINK" || -L "$CURRENT_LINK" ]]; then
    managed_release_from_link "$CURRENT_LINK" current >/dev/null
  fi
  if [[ -e "$PREVIOUS_LINK" || -L "$PREVIOUS_LINK" ]]; then
    managed_release_from_link "$PREVIOUS_LINK" previous >/dev/null
  fi
}

prune_owned_releases() {
  local current_target=""
  local previous_target=""
  local journal_current=""
  local journal_previous=""

  validate_release_pointers_for_retention
  [[ ! -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]] || current_target="$(managed_release_from_link "$CURRENT_LINK" current)"
  [[ ! -e "$PREVIOUS_LINK" && ! -L "$PREVIOUS_LINK" ]] || previous_target="$(managed_release_from_link "$PREVIOUS_LINK" previous)"
  python3 - "$RELEASES_DIR" "$RELEASE_ID" "$current_target" "$previous_target" "$journal_current" "$journal_previous" \
    "$RELEASE_RETENTION_MAX_COUNT" "$RELEASE_RETENTION_MAX_AGE_DAYS" "$RELEASE_RETENTION_MAX_BYTES" \
    "$SCAN_MAX_ENTRIES" "$SCAN_MAX_DEPTH" "$SCAN_MAX_BYTES" "$STATE_FILE_MAX_BYTES" <<'PY'
import os
import re
import shutil
import stat
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
candidate = sys.argv[2]
pointer_values = sys.argv[3:7]
max_count = int(sys.argv[7])
max_age = int(sys.argv[8]) * 86400
max_bytes = int(sys.argv[9])
max_entries = int(sys.argv[10])
max_depth = int(sys.argv[11])
scan_max_bytes = int(sys.argv[12])
state_max_bytes = int(sys.argv[13])
now = time.time()
name_re = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+-]*-(?:[0-9a-f]{40}|[0-9a-f]{64})$")
protected = {candidate}
for value in pointer_values:
    if value.startswith("releases/") and "/" not in value[len("releases/"):]:
        protected.add(value[len("releases/"):])

def manifest_owned(path: Path) -> bool:
    manifest = path / "release-manifest.tsv"
    if path.is_symlink() or not path.is_dir() or not name_re.fullmatch(path.name):
        return False
    if manifest.is_symlink() or not manifest.is_file():
        return False
    metadata = manifest.lstat()
    if metadata.st_size > state_max_bytes:
        raise SystemExit(f"release manifest exceeds bounded state limit: {manifest}")
    descriptor = os.open(manifest, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            raise SystemExit(f"release manifest changed identity: {manifest}")
        raw = os.read(descriptor, state_max_bytes + 1)
        if len(raw) > state_max_bytes or os.read(descriptor, 1):
            raise SystemExit(f"release manifest exceeds bounded state limit: {manifest}")
    finally:
        os.close(descriptor)
    values = {}
    for line in raw.decode("utf-8").splitlines():
        if "\t" in line:
            key, value = line.split("\t", 1)
            values.setdefault(key, value)
    return values.get("format") == "codexswitch-release-v3" and values.get("release_id") == path.name

def scan_tree(path: Path):
    total = 0
    count = 0
    directories = [path]
    files = []
    stack = [(path, 0)]
    while stack:
        directory, depth = stack.pop()
        with os.scandir(directory) as children:
            for child in children:
                item = Path(child.path)
                metadata = child.stat(follow_symlinks=False)
                count += 1
                if count > max_entries:
                    raise SystemExit("release scan entry bound exceeded")
                next_depth = depth + 1
                if next_depth > max_depth:
                    raise SystemExit(f"release scan depth bound exceeded: {item}")
                if stat.S_ISLNK(metadata.st_mode):
                    raise SystemExit(f"owned release contains a linked or special entry: {item}")
                if stat.S_ISDIR(metadata.st_mode):
                    directories.append((item, metadata.st_dev, metadata.st_ino))
                    stack.append((item, next_depth))
                elif stat.S_ISREG(metadata.st_mode):
                    total += metadata.st_size
                    if total > scan_max_bytes:
                        raise SystemExit("release scan byte bound exceeded")
                    files.append((item, metadata.st_mode, metadata.st_dev, metadata.st_ino))
                else:
                    raise SystemExit(f"owned release contains a linked or special entry: {item}")
    return total, directories, files

def remove_tree(path: Path, directories, files) -> None:
    for item, mode, expected_dev, expected_ino in files:
        observed = item.lstat()
        if (observed.st_dev, observed.st_ino) != (expected_dev, expected_ino):
            raise SystemExit(f"release file changed during cleanup: {item}")
        os.chmod(item, stat.S_IMODE(mode) | stat.S_IWUSR, follow_symlinks=False)
    for entry in sorted(directories, key=lambda value: len(value[0].parts) if isinstance(value, tuple) else len(value.parts), reverse=True):
        item = entry[0] if isinstance(entry, tuple) else entry
        mode = item.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise SystemExit(f"release changed during cleanup: {item}")
        os.chmod(item, stat.S_IMODE(mode) | stat.S_IWUSR, follow_symlinks=False)
    shutil.rmtree(path)

entries = []
if root.exists():
    root_count = 0
    with os.scandir(root) as children:
      for child in children:
        root_count += 1
        if root_count > max_entries:
            raise SystemExit("release root scan entry bound exceeded")
        path = Path(child.path)
        if manifest_owned(path):
            size, directories, files = scan_tree(path)
            entries.append({"path": path, "mtime": path.stat().st_mtime, "size": size, "directories": directories, "files": files})

kept = [entry for entry in entries if entry["path"].name in protected]
unprotected = sorted(
    (entry for entry in entries if entry["path"].name not in protected),
    key=lambda entry: entry["mtime"],
    reverse=True,
)
if len(kept) > max_count or sum(entry["size"] for entry in kept) > max_bytes:
    raise SystemExit("protected releases alone exceed retention bounds")

for entry in unprotected:
    age_ok = now - entry["mtime"] <= max_age
    count_ok = len(kept) < max_count
    bytes_ok = sum(item["size"] for item in kept) + entry["size"] <= max_bytes
    if age_ok and count_ok and bytes_ok:
        kept.append(entry)
        continue
    remove_tree(entry["path"], entry["directories"], entry["files"])
PY
}

enforce_release_retention() {
  if prune_owned_releases; then
    return
  fi
  if [[ "$RELEASE_PUBLISHED_THIS_RUN" == "1" && -d "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]]; then
    remove_tree_without_links "$RELEASE_DIR"
    fsync_directory "$RELEASES_DIR"
  fi
  fail "release retention bounds could not be satisfied"
}

print_dry_run() {
  cat <<EOF
CodexSwitch Linux deployment dry run
  Git SHA:             $TARGET_SHA
  approved origin ref: $APPROVED_ORIGIN_REF
  repository:          $REPO_URL
  source cache:        $SOURCE_DIR
  build root:          $BUILD_ROOT
  release:             $RELEASES_DIR/<package-version>-$TARGET_SHA
  current link:        $CURRENT_LINK
  public CLI:          $BIN_DIR/codexswitch-cli -> $CURRENT_LINK/codexswitch-cli
  public Codex:        $BIN_DIR/codex -> $CURRENT_LINK/patched-codex/codex
  runtime input:       $CODEX_RUNTIME_DIR
  activate:            $ACTIVATE

Planned build: clean detached worktree; SOURCE_DATE_EPOCH=<commit-epoch>; CARGO_TARGET_DIR=$BUILD_ROOT/cargo-target/<version>-$TARGET_SHA nice -n $BUILD_NICE ionice -c 3 cargo build --locked --release --jobs 1 -p codexswitch-cli
Stage-only default: publish and validate; do not change current, previous, public CLI, systemd, imports, boot policy, or processes.
EOF
}
