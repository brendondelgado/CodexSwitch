# shellcheck shell=bash

run_import_transaction_helper() {
  local operation="$1"
  local requested="${2:-0}"

  python3 - \
    "$operation" \
    "$SYSTEMD_TRANSACTION_DIR" \
    "$HOME_ROOT" \
    "$ACCOUNT_STORE_PATH" \
    "$AUTH_PATH" \
    "$IMPORT_BUNDLE" \
    "$IMPORT_BUNDLE_SHA256" \
    "$SCAN_MAX_BYTES" \
    "$STATE_FILE_MAX_BYTES" \
    "$requested" \
    "$TEST_MODE" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys
import time
from pathlib import Path

(
    operation,
    transaction_text,
    home_text,
    account_store_text,
    auth_text,
    bundle_text,
    expected_bundle_digest,
    max_bytes_text,
    state_limit_text,
    requested_text,
    test_mode_text,
) = sys.argv[1:]

transaction = Path(transaction_text)
home = Path(home_text)
account_store = Path(account_store_text)
auth_path = Path(auth_text)
bundle = Path(bundle_text) if bundle_text else None
max_bytes = int(max_bytes_text)
state_limit = int(state_limit_text)
requested = requested_text == "1"
test_mode = test_mode_text == "1"
euid = os.geteuid()

DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
HEX = frozenset("0123456789abcdef")
TARGET_NAMES = {
    "account_store": "accounts.json",
    "account_activation": "accounts.activation.json",
    "auth": "auth.json",
}


def fail(message):
    raise SystemExit(message)


def fsync_fd(descriptor):
    os.fsync(descriptor)


def validate_hex_digest(value, label):
    if len(value) != 64 or any(character not in HEX for character in value):
        fail(f"invalid {label}")


class RootedHome:
    def __init__(self, root):
        if not root.is_absolute():
            fail(f"HOME root is not absolute: {root}")
        before = root.lstat()
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
            fail(f"HOME root is linked or special: {root}")
        if before.st_uid != euid:
            fail(f"HOME root is not owned by the effective user: {root}")
        self.path = root
        self.fd = os.open(root, DIR_FLAGS)
        opened = os.fstat(self.fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            os.close(self.fd)
            fail(f"HOME root changed identity while opened: {root}")

    def close(self):
        os.close(self.fd)

    def parts(self, path):
        if not path.is_absolute() or "\t" in str(path) or "\n" in str(path):
            fail(f"unsafe import transaction path: {path}")
        try:
            relative = path.relative_to(self.path)
        except ValueError:
            fail(f"import transaction path escapes HOME: {path}")
        if any(part in {"", ".", ".."} for part in relative.parts):
            fail(f"unsafe import transaction path components: {path}")
        return relative.parts

    def open_directory(self, path, create=False):
        parts = self.parts(path)
        descriptor = os.dup(self.fd)
        current = self.path
        created = []
        try:
            for component in parts:
                try:
                    child = os.open(component, DIR_FLAGS, dir_fd=descriptor)
                except FileNotFoundError:
                    if not create:
                        raise
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                    fsync_fd(descriptor)
                    created.append(current / component)
                    child = os.open(component, DIR_FLAGS, dir_fd=descriptor)
                except OSError as error:
                    fail(
                        f"import transaction directory is linked or special: "
                        f"{current / component}: {error}"
                    )
                metadata = os.fstat(child)
                if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != euid:
                    os.close(child)
                    fail(
                        f"import transaction directory is not effective-user-owned: "
                        f"{current / component}"
                    )
                os.close(descriptor)
                descriptor = child
                current /= component
            return descriptor, created
        except BaseException:
            os.close(descriptor)
            raise

    def probe_directory(self, path):
        try:
            descriptor, _created = self.open_directory(path)
        except FileNotFoundError:
            return None
        try:
            return os.fstat(descriptor)
        finally:
            os.close(descriptor)

    def verify_directory(self, path, expected_device, expected_inode):
        try:
            descriptor, _created = self.open_directory(path)
        except FileNotFoundError:
            fail(f"import transaction parent disappeared: {path}")
        try:
            metadata = os.fstat(descriptor)
            if (metadata.st_dev, metadata.st_ino) != (
                expected_device,
                expected_inode,
            ):
                fail(f"import transaction parent changed identity: {path}")
        finally:
            os.close(descriptor)

    def remove_empty_directory(self, path):
        parts = self.parts(path)
        if not parts:
            fail("refusing to remove HOME during import rollback")
        parent = self.path.joinpath(*parts[:-1])
        parent_fd, _created = self.open_directory(parent)
        try:
            os.rmdir(parts[-1], dir_fd=parent_fd)
            fsync_fd(parent_fd)
        finally:
            os.close(parent_fd)


def entry_stat(parent_fd, name):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def open_regular_at(parent_fd, name, display_path, writable=False):
    metadata = entry_stat(parent_fd, name)
    if metadata is None:
        raise FileNotFoundError(display_path)
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != euid
    ):
        fail(f"import transaction file is linked, special, or unowned: {display_path}")
    flags = (os.O_RDWR if writable else os.O_RDONLY) | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(name, flags, dir_fd=parent_fd)
    opened = os.fstat(descriptor)
    if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
        os.close(descriptor)
        fail(f"import transaction file changed identity: {display_path}")
    return descriptor, opened


def digest_descriptor(descriptor, display_path, bound=max_bytes):
    metadata = os.fstat(descriptor)
    if metadata.st_size > bound:
        fail(f"import transaction file exceeds byte bound: {display_path}")
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    consumed = 0
    while True:
        chunk = os.read(descriptor, min(1024 * 1024, bound - consumed + 1))
        if not chunk:
            break
        consumed += len(chunk)
        if consumed > bound:
            fail(f"import transaction file exceeds byte bound: {display_path}")
        digest.update(chunk)
    return digest.hexdigest(), consumed


def generation_at(parent_fd, name, display_path):
    if entry_stat(parent_fd, name) is None:
        return "MISSING"
    descriptor, _metadata = open_regular_at(parent_fd, name, display_path)
    try:
        digest, _size = digest_descriptor(descriptor, display_path)
        return digest
    finally:
        os.close(descriptor)


def copy_descriptor_to_new_file(source_fd, destination_fd, destination_name, mode):
    descriptor = os.open(
        destination_name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        mode,
        dir_fd=destination_fd,
    )
    succeeded = False
    try:
        os.lseek(source_fd, 0, os.SEEK_SET)
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                view = view[os.write(descriptor, view) :]
        os.fchmod(descriptor, mode)
        fsync_fd(descriptor)
        succeeded = True
    finally:
        os.close(descriptor)
        if not succeeded:
            try:
                os.unlink(destination_name, dir_fd=destination_fd)
            except FileNotFoundError:
                pass


def write_bounded_file(parent_fd, name, text, mode=0o600):
    encoded = text.encode("utf-8")
    if len(encoded) > state_limit:
        fail(f"import transaction state exceeds bounded limit: {name}")
    descriptor = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        mode,
        dir_fd=parent_fd,
    )
    succeeded = False
    try:
        view = memoryview(encoded)
        while view:
            view = view[os.write(descriptor, view) :]
        fsync_fd(descriptor)
        succeeded = True
    finally:
        os.close(descriptor)
        if not succeeded:
            try:
                os.unlink(name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass


def replace_bounded_file(parent_fd, name, text):
    temporary = f".{name}.tmp.{os.getpid()}.{time.monotonic_ns()}"
    write_bounded_file(parent_fd, temporary, text)
    try:
        os.replace(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        fsync_fd(parent_fd)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError:
            pass


def read_bounded_file(parent_fd, name, required=True):
    metadata = entry_stat(parent_fd, name)
    if metadata is None:
        if required:
            fail(f"missing import transaction state: {name}")
        return None
    descriptor, opened = open_regular_at(parent_fd, name, transaction / name)
    try:
        if opened.st_size > state_limit:
            fail(f"import transaction state exceeds bounded limit: {name}")
        data = os.read(descriptor, state_limit + 1)
        if len(data) > state_limit or os.read(descriptor, 1):
            fail(f"import transaction state exceeds bounded limit: {name}")
    finally:
        os.close(descriptor)
    try:
        return data.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        fail(f"import transaction state is not UTF-8: {name}")


def test_barrier(prefix):
    if not test_mode:
        return
    ready = os.environ.get(f"{prefix}_READY")
    resume = os.environ.get(f"{prefix}_CONTINUE")
    if ready is None and resume is None:
        return
    if not ready or not resume:
        fail(f"incomplete test barrier configuration: {prefix}")
    ready_path = Path(ready)
    descriptor = os.open(
        ready_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
    )
    try:
        os.write(descriptor, b"ready\n")
        fsync_fd(descriptor)
    finally:
        os.close(descriptor)
    deadline = time.monotonic() + 10
    while not os.path.exists(resume):
        if time.monotonic() >= deadline:
            fail(f"timed out waiting at test barrier: {prefix}")
        time.sleep(0.01)


def parse_generation_receipt(lines, format_name, include_pairs):
    if lines is None:
        return None
    if lines[:1] != [f"format\t{format_name}"]:
        fail(f"invalid {format_name} receipt")
    phase = None
    values = {}
    for line in lines[1:]:
        fields = line.split("\t")
        if fields[0] == "phase" and len(fields) == 2 and phase is None:
            phase = fields[1]
            continue
        expected_length = 3 if include_pairs else 2
        if len(fields) != expected_length or fields[0] in values:
            fail(f"invalid {format_name} receipt")
        for value in fields[1:]:
            if value != "MISSING":
                validate_hex_digest(value, f"{format_name} generation")
        values[fields[0]] = tuple(fields[1:]) if include_pairs else fields[1]
    if phase not in {"planned", "committed"}:
        fail(f"invalid {format_name} receipt phase")
    return phase, values


tree = RootedHome(home)
transaction_fd = None
try:
    transaction_before = transaction.lstat()
    if (
        stat.S_ISLNK(transaction_before.st_mode)
        or not stat.S_ISDIR(transaction_before.st_mode)
        or transaction_before.st_uid != euid
    ):
        fail(f"import transaction directory is linked, special, or unowned: {transaction}")
    transaction_fd = os.open(transaction, DIR_FLAGS)
    transaction_metadata = os.fstat(transaction_fd)
    if (transaction_metadata.st_dev, transaction_metadata.st_ino) != (
        transaction_before.st_dev,
        transaction_before.st_ino,
    ):
        fail(f"import transaction directory changed identity: {transaction}")
    if stat.S_IMODE(transaction_metadata.st_mode) & 0o077:
        fail(f"import transaction directory is not private: {transaction}")

    if operation == "snapshot":
        lines = ["format\tcodexswitch-import-state-v3", f"requested\t{int(requested)}"]
        if not requested:
            write_bounded_file(transaction_fd, "import-state.tsv", "\n".join(lines) + "\n")
            fsync_fd(transaction_fd)
            raise SystemExit(0)

        if bundle is None:
            fail("missing import bundle")
        if account_store.with_suffix(".activation.json") == auth_path:
            fail("import transaction paths must be distinct")
        targets = {
            "account_store": account_store,
            "account_activation": account_store.with_suffix(".activation.json"),
            "auth": auth_path,
        }
        if len(set(targets.values())) != len(targets):
            fail("import transaction paths must be distinct")
        lock_path = account_store.with_suffix(".json.lock")
        for path in (*targets.values(), lock_path):
            tree.parts(path)

        os.mkdir("import-before", 0o700, dir_fd=transaction_fd)
        os.mkdir("import-work", 0o700, dir_fd=transaction_fd)
        before_fd = os.open("import-before", DIR_FLAGS, dir_fd=transaction_fd)
        work_fd = os.open("import-work", DIR_FLAGS, dir_fd=transaction_fd)

        bundle_before = bundle.lstat()
        if (
            stat.S_ISLNK(bundle_before.st_mode)
            or not stat.S_ISREG(bundle_before.st_mode)
            or bundle_before.st_uid != euid
        ):
            fail(f"import bundle is linked, special, or unowned: {bundle}")
        bundle_fd = os.open(bundle, READ_FLAGS)
        try:
            bundle_opened = os.fstat(bundle_fd)
            if (bundle_opened.st_dev, bundle_opened.st_ino) != (
                bundle_before.st_dev,
                bundle_before.st_ino,
            ):
                fail(f"import bundle changed identity: {bundle}")
            bundle_digest, bundle_size = digest_descriptor(bundle_fd, bundle)
            if bundle_digest != expected_bundle_digest:
                fail(f"CODEXSWITCH_IMPORT_BUNDLE SHA-256 mismatch: {bundle}")
            copy_descriptor_to_new_file(
                bundle_fd,
                transaction_fd,
                "import-bundle.csbundle",
                0o600,
            )
            staged_fd, staged_metadata = open_regular_at(
                transaction_fd,
                "import-bundle.csbundle",
                transaction / "import-bundle.csbundle",
            )
            try:
                staged_digest, staged_size = digest_descriptor(
                    staged_fd, transaction / "import-bundle.csbundle"
                )
            finally:
                os.close(staged_fd)
            if (
                staged_digest != bundle_digest
                or staged_size != bundle_size
                or stat.S_IMODE(staged_metadata.st_mode) != 0o600
            ):
                fail("anchored import bundle changed while it was copied")
        finally:
            os.close(bundle_fd)

        unique_parents = sorted({path.parent for path in targets.values()}, key=str)
        prior_parent_probe = {
            path: tree.probe_directory(path) for path in unique_parents
        }
        prior_parent_state = {
            path: "PRESENT" if metadata is not None else "ABSENT"
            for path, metadata in prior_parent_probe.items()
        }
        parent_handles = {}
        created_directories = []
        lock_fd = None
        lock_created = False
        lock_identity = None
        snapshot_complete = False
        try:
            for parent in unique_parents:
                descriptor, created = tree.open_directory(parent, create=True)
                created_directories.extend(created)
                opened_parent = os.fstat(descriptor)
                probed_parent = prior_parent_probe[parent]
                if probed_parent is None and parent not in created:
                    os.close(descriptor)
                    fail(f"import transaction parent appeared concurrently: {parent}")
                if probed_parent is not None and (
                    opened_parent.st_dev,
                    opened_parent.st_ino,
                ) != (probed_parent.st_dev, probed_parent.st_ino):
                    os.close(descriptor)
                    fail(f"import transaction parent changed identity: {parent}")
                parent_handles[parent] = descriptor

            account_parent_fd = parent_handles[lock_path.parent]
            lock_before = entry_stat(account_parent_fd, lock_path.name)
            lock_state = "PRESENT" if lock_before is not None else "ABSENT"
            lock_mode = 0
            lock_generation = "MISSING"
            if lock_before is None:
                lock_fd = os.open(
                    lock_path.name,
                    os.O_RDWR
                    | os.O_CREAT
                    | os.O_EXCL
                    | os.O_NOFOLLOW
                    | os.O_NONBLOCK
                    | os.O_CLOEXEC,
                    0o600,
                    dir_fd=account_parent_fd,
                )
                lock_created = True
                fsync_fd(account_parent_fd)
            else:
                lock_fd, lock_opened = open_regular_at(
                    account_parent_fd,
                    lock_path.name,
                    lock_path,
                    writable=True,
                )
                lock_mode = stat.S_IMODE(lock_opened.st_mode)
            lock_opened = os.fstat(lock_fd)
            if not stat.S_ISREG(lock_opened.st_mode) or lock_opened.st_uid != euid:
                fail(f"canonical account lock is linked, special, or unowned: {lock_path}")
            lock_identity = (lock_opened.st_dev, lock_opened.st_ino)
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                fail(f"canonical account lock is busy: {lock_path}")

            current_lock = entry_stat(account_parent_fd, lock_path.name)
            if current_lock is None or (current_lock.st_dev, current_lock.st_ino) != lock_identity:
                fail(f"canonical account lock changed identity: {lock_path}")
            if lock_state == "PRESENT":
                lock_generation, _lock_size = digest_descriptor(lock_fd, lock_path)
                copy_descriptor_to_new_file(
                    lock_fd,
                    before_fd,
                    "account_lock",
                    lock_mode,
                )
            else:
                lock_generation = hashlib.sha256(b"").hexdigest()
                lock_mode = 0

            for label, path in targets.items():
                parent_fd = parent_handles[path.parent]
                parent_metadata = os.fstat(parent_fd)
                source_metadata = entry_stat(parent_fd, path.name)
                if source_metadata is None:
                    state = "ABSENT"
                    mode = 0
                    generation = "MISSING"
                else:
                    source_fd, opened = open_regular_at(parent_fd, path.name, path)
                    try:
                        generation, _size = digest_descriptor(source_fd, path)
                        mode = stat.S_IMODE(opened.st_mode)
                        copy_descriptor_to_new_file(source_fd, before_fd, label, mode)
                        copy_descriptor_to_new_file(
                            source_fd,
                            work_fd,
                            TARGET_NAMES[label],
                            mode,
                        )
                        if (
                            generation_at(
                                before_fd,
                                label,
                                transaction / "import-before" / label,
                            )
                            != generation
                        ):
                            fail(f"import snapshot changed while copied: {path}")
                        if (
                            generation_at(
                                work_fd,
                                TARGET_NAMES[label],
                                transaction / "import-work" / TARGET_NAMES[label],
                            )
                            != generation
                        ):
                            fail(f"isolated import seed changed while copied: {path}")
                    finally:
                        os.close(source_fd)
                    state = "PRESENT"
                lines.append(
                    "\t".join(
                        (
                            "target",
                            label,
                            state,
                            f"{mode:04o}",
                            prior_parent_state[path.parent],
                            str(path),
                            generation,
                            str(parent_metadata.st_dev),
                            str(parent_metadata.st_ino),
                        )
                    )
                )

            account_parent_metadata = os.fstat(account_parent_fd)
            lines.append(
                "\t".join(
                    (
                        "lock",
                        lock_state,
                        f"{lock_mode:04o}",
                        prior_parent_state[lock_path.parent],
                        str(lock_path),
                        lock_generation,
                        str(account_parent_metadata.st_dev),
                        str(account_parent_metadata.st_ino),
                        str(lock_identity[0]),
                        str(lock_identity[1]),
                    )
                )
            )
            lines.append(f"bundle\t{bundle_digest}\t{bundle_size}")
            write_bounded_file(
                transaction_fd,
                "import-state.tsv",
                "\n".join(lines) + "\n",
            )
            for descriptor in (before_fd, work_fd, transaction_fd):
                fsync_fd(descriptor)
            snapshot_complete = True
        finally:
            if lock_fd is not None:
                if not snapshot_complete and lock_created and lock_identity is not None:
                    current = entry_stat(account_parent_fd, lock_path.name)
                    if current is not None and (current.st_dev, current.st_ino) == lock_identity:
                        os.unlink(lock_path.name, dir_fd=account_parent_fd)
                        fsync_fd(account_parent_fd)
                os.close(lock_fd)
            for descriptor in parent_handles.values():
                os.close(descriptor)
            if not snapshot_complete:
                for directory in sorted(
                    set(created_directories), key=lambda value: len(value.parts), reverse=True
                ):
                    try:
                        tree.remove_empty_directory(directory)
                    except OSError:
                        pass
            os.close(before_fd)
            os.close(work_fd)
        raise SystemExit(0)

    state_lines = read_bounded_file(transaction_fd, "import-state.tsv")
    if state_lines[:2] == [
        "format\tcodexswitch-import-state-v3",
        "requested\t0",
    ]:
        if len(state_lines) != 2:
            fail("unexpected disabled import transaction entries")
        raise SystemExit(0)
    if state_lines[:2] != [
        "format\tcodexswitch-import-state-v3",
        "requested\t1",
    ]:
        fail("invalid import transaction state")

    targets = {}
    lock_record = None
    bundle_record = None
    for line in state_lines[2:]:
        fields = line.split("\t")
        if fields[0] == "target":
            if len(fields) != 9:
                fail("invalid import transaction target")
            (
                _kind,
                label,
                state,
                mode_text,
                parent_state,
                path_text,
                generation,
                parent_device,
                parent_inode,
            ) = fields
            if label in targets or label not in TARGET_NAMES:
                fail("invalid import transaction target label")
            if state not in {"PRESENT", "ABSENT"} or parent_state not in {
                "PRESENT",
                "ABSENT",
            }:
                fail("invalid import transaction target state")
            if len(mode_text) != 4 or any(character not in "01234567" for character in mode_text):
                fail("invalid import transaction target mode")
            if not parent_device.isdigit() or not parent_inode.isdigit():
                fail("invalid import transaction parent identity")
            path = Path(path_text)
            tree.parts(path)
            if state == "PRESENT":
                validate_hex_digest(generation, "present import target generation")
            elif generation != "MISSING":
                fail("invalid absent import target generation")
            targets[label] = {
                "state": state,
                "mode": int(mode_text, 8),
                "parent_state": parent_state,
                "path": path,
                "before": generation,
                "parent_device": int(parent_device),
                "parent_inode": int(parent_inode),
            }
            continue
        if fields[0] == "lock":
            if len(fields) != 10 or lock_record is not None:
                fail("invalid import transaction lock record")
            (
                _kind,
                state,
                mode_text,
                parent_state,
                path_text,
                generation,
                parent_device,
                parent_inode,
                active_device,
                active_inode,
            ) = fields
            if state not in {"PRESENT", "ABSENT"} or parent_state not in {
                "PRESENT",
                "ABSENT",
            }:
                fail("invalid import transaction lock state")
            if len(mode_text) != 4 or any(character not in "01234567" for character in mode_text):
                fail("invalid import transaction lock mode")
            validate_hex_digest(generation, "import transaction lock generation")
            if not all(
                value.isdigit()
                for value in (parent_device, parent_inode, active_device, active_inode)
            ):
                fail("invalid import transaction lock identity")
            path = Path(path_text)
            tree.parts(path)
            lock_record = {
                "state": state,
                "mode": int(mode_text, 8),
                "parent_state": parent_state,
                "path": path,
                "before": generation,
                "parent_device": int(parent_device),
                "parent_inode": int(parent_inode),
                "active_device": int(active_device),
                "active_inode": int(active_inode),
            }
            continue
        if fields[0] == "bundle":
            if len(fields) != 3 or bundle_record is not None or not fields[2].isdigit():
                fail("invalid anchored import bundle record")
            validate_hex_digest(fields[1], "anchored import bundle digest")
            bundle_record = (fields[1], int(fields[2]))
            continue
        fail("invalid import transaction state entry")

    if set(targets) != set(TARGET_NAMES) or lock_record is None or bundle_record is None:
        fail("incomplete import transaction state")
    if targets["account_activation"]["path"] != targets["account_store"][
        "path"
    ].with_suffix(".activation.json"):
        fail("invalid canonical activation path")
    if lock_record["path"] != targets["account_store"]["path"].with_suffix(
        ".json.lock"
    ):
        fail("invalid canonical account lock path")

    parent_records = {}
    for record in (*targets.values(), lock_record):
        parent = record["path"].parent
        identity = (
            record["parent_state"],
            record["parent_device"],
            record["parent_inode"],
        )
        if parent in parent_records and parent_records[parent] != identity:
            fail("inconsistent import transaction parent identity")
        parent_records[parent] = identity

    before_fd = os.open("import-before", DIR_FLAGS, dir_fd=transaction_fd)
    work_fd = os.open("import-work", DIR_FLAGS, dir_fd=transaction_fd)
    staged_bundle_generation = generation_at(
        transaction_fd,
        "import-bundle.csbundle",
        transaction / "import-bundle.csbundle",
    )
    staged_bundle_metadata = entry_stat(transaction_fd, "import-bundle.csbundle")
    if (
        staged_bundle_generation != bundle_record[0]
        or staged_bundle_metadata is None
        or staged_bundle_metadata.st_size != bundle_record[1]
    ):
        fail("anchored import bundle identity mismatch")

    for label, record in targets.items():
        snapshot_generation = generation_at(before_fd, label, transaction / "import-before" / label)
        if snapshot_generation != record["before"]:
            fail(f"import rollback snapshot generation mismatch: {label}")
    lock_snapshot_generation = generation_at(
        before_fd,
        "account_lock",
        transaction / "import-before" / "account_lock",
    )
    if lock_record["state"] == "PRESENT":
        if lock_snapshot_generation != lock_record["before"]:
            fail("import rollback lock snapshot generation mismatch")
    elif lock_snapshot_generation != "MISSING":
        fail("unexpected import rollback lock snapshot")

    ownership = parse_generation_receipt(
        read_bounded_file(transaction_fd, "import-owned.tsv", required=False),
        "codexswitch-import-owned-v2",
        include_pairs=True,
    )
    restored = parse_generation_receipt(
        read_bounded_file(transaction_fd, "import-restored.tsv", required=False),
        "codexswitch-import-restored-v2",
        include_pairs=False,
    )
    if ownership is not None and set(ownership[1]) != set(targets):
        fail("invalid import ownership receipt labels")
    if restored is not None:
        expected_restored = {
            **{label: record["before"] for label, record in targets.items()},
            "account_lock": (
                lock_record["before"]
                if lock_record["state"] == "PRESENT"
                else "MISSING"
            ),
        }
        if restored[1] != expected_restored or restored[0] != "committed":
            fail("invalid import restored receipt")
        if operation in {"validate", "restore"}:
            raise SystemExit(0)
        fail("cannot commit an already restored import transaction")

    if operation not in {"commit", "abort", "validate", "restore"}:
        fail("invalid import transaction operation")

    if operation == "commit":
        test_barrier("CODEXSWITCH_TEST_IMPORT_BEFORE_COMMIT")

    parent_handles = {}
    try:
        for parent, (prior_state, expected_device, expected_inode) in parent_records.items():
            try:
                descriptor, _created = tree.open_directory(parent)
                metadata = os.fstat(descriptor)
                if (metadata.st_dev, metadata.st_ino) != (
                    expected_device,
                    expected_inode,
                ):
                    os.close(descriptor)
                    fail(f"import transaction parent changed identity: {parent}")
            except FileNotFoundError:
                if operation == "validate" and prior_state == "ABSENT":
                    raise SystemExit(0)
                if operation != "restore" or prior_state != "ABSENT":
                    fail(f"import transaction parent disappeared: {parent}")
                descriptor, _created = tree.open_directory(parent, create=True)
            parent_handles[parent] = descriptor

        lock_parent_fd = parent_handles[lock_record["path"].parent]
        lock_metadata = entry_stat(lock_parent_fd, lock_record["path"].name)
        if lock_metadata is None:
            if operation == "validate" and lock_record["state"] == "ABSENT":
                raise SystemExit(0)
            if operation != "restore" or lock_record["state"] != "ABSENT":
                fail(f"canonical account transaction lock is missing: {lock_record['path']}")
            lock_fd = os.open(
                lock_record["path"].name,
                os.O_RDWR
                | os.O_CREAT
                | os.O_EXCL
                | os.O_NOFOLLOW
                | os.O_NONBLOCK
                | os.O_CLOEXEC,
                0o600,
                dir_fd=lock_parent_fd,
            )
            fsync_fd(lock_parent_fd)
        else:
            lock_fd, opened_lock = open_regular_at(
                lock_parent_fd,
                lock_record["path"].name,
                lock_record["path"],
                writable=True,
            )
            if (opened_lock.st_dev, opened_lock.st_ino) != (
                lock_record["active_device"],
                lock_record["active_inode"],
            ):
                os.close(lock_fd)
                fail(f"canonical account transaction lock changed identity: {lock_record['path']}")
        commit_prepared = {}
        try:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                fail(f"canonical account transaction lock is busy: {lock_record['path']}")

            lock_generation, _lock_size = digest_descriptor(lock_fd, lock_record["path"])
            if lock_generation != lock_record["before"]:
                fail("canonical account transaction lock contents changed")

            def current_generations():
                return {
                    label: generation_at(
                        parent_handles[record["path"].parent],
                        record["path"].name,
                        record["path"],
                    )
                    for label, record in targets.items()
                }

            observed = current_generations()
            before_generations = {
                label: record["before"] for label, record in targets.items()
            }
            if ownership is None:
                allowed_generations = {
                    label: {generation} for label, generation in before_generations.items()
                }
            else:
                allowed_generations = {
                    label: set(pair) for label, pair in ownership[1].items()
                }
            if any(
                observed[label] not in allowed_generations[label]
                for label in targets
            ):
                fail("import rollback ownership changed; later writer preserved")

            if operation == "validate":
                raise SystemExit(0)

            if operation in {"commit", "abort"}:
                if ownership is not None:
                    fail("import ownership receipt already exists")
                if observed != before_generations:
                    fail("import compare-and-swap lost; concurrent account writer preserved")

                if operation == "abort":
                    owned_generations = before_generations
                    receipt_lines = [
                        "format\tcodexswitch-import-owned-v2",
                        "phase\tcommitted",
                    ]
                    receipt_lines.extend(
                        f"{label}\t{before_generations[label]}\t{owned_generations[label]}"
                        for label in sorted(targets)
                    )
                    replace_bounded_file(
                        transaction_fd,
                        "import-owned.tsv",
                        "\n".join(receipt_lines) + "\n",
                    )
                    raise SystemExit(0)

                owned_generations = {}
                for label, record in targets.items():
                    work_name = TARGET_NAMES[label]
                    source_fd, source_metadata = open_regular_at(
                        work_fd,
                        work_name,
                        transaction / "import-work" / work_name,
                    )
                    try:
                        if stat.S_IMODE(source_metadata.st_mode) != 0o600:
                            fail(f"isolated import output is not mode 0600: {work_name}")
                        owned_generation, _size = digest_descriptor(
                            source_fd, transaction / "import-work" / work_name
                        )
                        parent_fd = parent_handles[record["path"].parent]
                        temporary = (
                            f".{record['path'].name}.codexswitch-import."
                            f"{os.getpid()}.{time.monotonic_ns()}"
                        )
                        copy_descriptor_to_new_file(
                            source_fd,
                            parent_fd,
                            temporary,
                            0o600,
                        )
                        commit_prepared[label] = (
                            parent_fd,
                            temporary,
                            record["path"].name,
                        )
                        owned_generations[label] = owned_generation
                    finally:
                        os.close(source_fd)

                planned_lines = [
                    "format\tcodexswitch-import-owned-v2",
                    "phase\tplanned",
                ]
                planned_lines.extend(
                    f"{label}\t{before_generations[label]}\t{owned_generations[label]}"
                    for label in sorted(targets)
                )
                replace_bounded_file(
                    transaction_fd,
                    "import-owned.tsv",
                    "\n".join(planned_lines) + "\n",
                )

                test_barrier("CODEXSWITCH_TEST_IMPORT_BEFORE_PUBLISH")
                for parent, descriptor in parent_handles.items():
                    metadata = os.fstat(descriptor)
                    tree.verify_directory(parent, metadata.st_dev, metadata.st_ino)
                current_lock = entry_stat(lock_parent_fd, lock_record["path"].name)
                opened_lock = os.fstat(lock_fd)
                if current_lock is None or (current_lock.st_dev, current_lock.st_ino) != (
                    opened_lock.st_dev,
                    opened_lock.st_ino,
                ):
                    fail("canonical account transaction lock changed identity before publish")
                if current_generations() != before_generations:
                    fail("import compare-and-swap changed before publish")

                for label in sorted(targets):
                    parent_fd, temporary, target_name = commit_prepared[label]
                    os.replace(
                        temporary,
                        target_name,
                        src_dir_fd=parent_fd,
                        dst_dir_fd=parent_fd,
                    )
                    commit_prepared[label] = (parent_fd, None, target_name)
                for descriptor in set(parent_handles.values()):
                    fsync_fd(descriptor)
                if current_generations() != owned_generations:
                    fail("canonical import publication generation mismatch")

                committed_lines = [
                    "format\tcodexswitch-import-owned-v2",
                    "phase\tcommitted",
                ]
                committed_lines.extend(
                    f"{label}\t{before_generations[label]}\t{owned_generations[label]}"
                    for label in sorted(targets)
                )
                replace_bounded_file(
                    transaction_fd,
                    "import-owned.tsv",
                    "\n".join(committed_lines) + "\n",
                )

                if test_mode and os.environ.get(
                    "CODEXSWITCH_TEST_CONCURRENT_ACCOUNT_STORE"
                ) is not None:
                    test_values = {
                        "account_store": os.environ[
                            "CODEXSWITCH_TEST_CONCURRENT_ACCOUNT_STORE"
                        ],
                        "auth": os.environ.get("CODEXSWITCH_TEST_CONCURRENT_AUTH", ""),
                    }
                    for label, value in test_values.items():
                        record = targets[label]
                        descriptor = os.open(
                            record["path"].name,
                            os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=parent_handles[record["path"].parent],
                        )
                        try:
                            os.write(descriptor, value.encode("utf-8"))
                            fsync_fd(descriptor)
                        finally:
                            os.close(descriptor)
                    for descriptor in set(parent_handles.values()):
                        fsync_fd(descriptor)
                raise SystemExit(0)

            if operation != "restore":
                fail("invalid import transaction operation")

            prepared = {}
            try:
                for label, record in targets.items():
                    if record["state"] != "PRESENT":
                        continue
                    source_fd, _source_metadata = open_regular_at(
                        before_fd,
                        label,
                        transaction / "import-before" / label,
                    )
                    try:
                        parent_fd = parent_handles[record["path"].parent]
                        temporary = (
                            f".{record['path'].name}.codexswitch-rollback."
                            f"{os.getpid()}.{time.monotonic_ns()}"
                        )
                        copy_descriptor_to_new_file(
                            source_fd,
                            parent_fd,
                            temporary,
                            record["mode"],
                        )
                        prepared[label] = (parent_fd, temporary, record["path"].name)
                    finally:
                        os.close(source_fd)

                for parent, descriptor in parent_handles.items():
                    metadata = os.fstat(descriptor)
                    tree.verify_directory(parent, metadata.st_dev, metadata.st_ino)
                refreshed = current_generations()
                if any(
                    refreshed[label] not in allowed_generations[label]
                    for label in targets
                ):
                    fail("import rollback ownership changed; later writer preserved")

                for label in sorted(targets):
                    record = targets[label]
                    parent_fd = parent_handles[record["path"].parent]
                    if record["state"] == "PRESENT":
                        _parent_fd, temporary, target_name = prepared[label]
                        os.replace(
                            temporary,
                            target_name,
                            src_dir_fd=parent_fd,
                            dst_dir_fd=parent_fd,
                        )
                        prepared[label] = (parent_fd, None, target_name)
                    elif entry_stat(parent_fd, record["path"].name) is not None:
                        current = entry_stat(parent_fd, record["path"].name)
                        if stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode):
                            fail(f"import rollback target is linked or special: {record['path']}")
                        os.unlink(record["path"].name, dir_fd=parent_fd)
                for descriptor in set(parent_handles.values()):
                    fsync_fd(descriptor)
                if current_generations() != before_generations:
                    fail("import rollback generation verification failed")

                if lock_record["state"] == "PRESENT":
                    source_fd, _source_metadata = open_regular_at(
                        before_fd,
                        "account_lock",
                        transaction / "import-before" / "account_lock",
                    )
                    try:
                        os.ftruncate(lock_fd, 0)
                        os.lseek(source_fd, 0, os.SEEK_SET)
                        while True:
                            chunk = os.read(source_fd, 1024 * 1024)
                            if not chunk:
                                break
                            view = memoryview(chunk)
                            while view:
                                view = view[os.write(lock_fd, view) :]
                        os.fchmod(lock_fd, lock_record["mode"])
                        fsync_fd(lock_fd)
                    finally:
                        os.close(source_fd)
                else:
                    current_lock = entry_stat(lock_parent_fd, lock_record["path"].name)
                    opened_lock = os.fstat(lock_fd)
                    if current_lock is None or (current_lock.st_dev, current_lock.st_ino) != (
                        opened_lock.st_dev,
                        opened_lock.st_ino,
                    ):
                        fail("canonical account lock changed identity during rollback")
                    os.unlink(lock_record["path"].name, dir_fd=lock_parent_fd)
                    fsync_fd(lock_parent_fd)

                for parent, (prior_state, _device, _inode) in sorted(
                    parent_records.items(), key=lambda item: len(item[0].parts), reverse=True
                ):
                    if prior_state != "ABSENT":
                        continue
                    try:
                        tree.remove_empty_directory(parent)
                    except OSError as error:
                        fail(
                            f"import rollback could not restore absent parent {parent}: {error}"
                        )

                restored_values = {
                    **before_generations,
                    "account_lock": (
                        lock_record["before"]
                        if lock_record["state"] == "PRESENT"
                        else "MISSING"
                    ),
                }
                restored_lines = [
                    "format\tcodexswitch-import-restored-v2",
                    "phase\tcommitted",
                ]
                restored_lines.extend(
                    f"{label}\t{restored_values[label]}"
                    for label in sorted(restored_values)
                )
                replace_bounded_file(
                    transaction_fd,
                    "import-restored.tsv",
                    "\n".join(restored_lines) + "\n",
                )
                raise SystemExit(0)
            finally:
                for parent_fd, temporary, _target_name in prepared.values():
                    if temporary is None:
                        continue
                    try:
                        os.unlink(temporary, dir_fd=parent_fd)
                    except FileNotFoundError:
                        pass
        finally:
            for parent_fd, temporary, _target_name in commit_prepared.values():
                if temporary is None:
                    continue
                try:
                    os.unlink(temporary, dir_fd=parent_fd)
                except FileNotFoundError:
                    pass
            os.close(lock_fd)
    finally:
        for descriptor in parent_handles.values():
            os.close(descriptor)
        os.close(before_fd)
        os.close(work_fd)
finally:
    if transaction_fd is not None:
        os.close(transaction_fd)
    tree.close()
PY
}

snapshot_import_transaction() {
  local requested=0
  [[ -z "$IMPORT_BUNDLE" ]] || requested=1

  run_import_transaction_helper snapshot "$requested"
  if [[ "$requested" == "1" ]]; then
    IMPORT_CANONICAL_ACCOUNT_STORE_PATH="$ACCOUNT_STORE_PATH"
    IMPORT_CANONICAL_AUTH_PATH="$AUTH_PATH"
    IMPORT_BUNDLE_STAGED="$SYSTEMD_TRANSACTION_DIR/import-bundle.csbundle"
    ACCOUNT_STORE_PATH="$SYSTEMD_TRANSACTION_DIR/import-work/accounts.json"
    AUTH_PATH="$SYSTEMD_TRANSACTION_DIR/import-work/auth.json"
  else
    # shellcheck disable=SC2034 # Consumed by the activation module after sourcing.
    IMPORT_BUNDLE_STAGED=""
  fi
}

restore_canonical_import_paths() {
  if [[ -n "${IMPORT_CANONICAL_ACCOUNT_STORE_PATH:-}" ]]; then
    ACCOUNT_STORE_PATH="$IMPORT_CANONICAL_ACCOUNT_STORE_PATH"
  fi
  if [[ -n "${IMPORT_CANONICAL_AUTH_PATH:-}" ]]; then
    AUTH_PATH="$IMPORT_CANONICAL_AUTH_PATH"
  fi
}

operate_import_transaction() {
  local operation="$1"
  run_import_transaction_helper "$operation" 0
}

record_import_owned_generation() {
  local operation="commit"
  local status=0
  [[ "${import_status:-1}" == "0" ]] || operation="abort"
  operate_import_transaction "$operation" || status=$?
  restore_canonical_import_paths
  return "$status"
}

validate_import_transaction_for_recovery() {
  operate_import_transaction validate
}

restore_import_transaction() {
  local status=0
  operate_import_transaction restore || status=$?
  restore_canonical_import_paths
  return "$status"
}
