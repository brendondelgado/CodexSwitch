#!/usr/bin/env python3
"""Operator-only retirement of an unknown legacy sync. Never imports or activates."""

import argparse
import base64
import contextlib
import datetime
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import resource
import select
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

JOURNAL = "linux-devbox-credential-sync.json"
SESSION_SECONDS = 120
MIN_HOLD_SECONDS = 20
MAX_MESSAGE = 16384


class Refused(RuntimeError):
    pass


def require(value, reason):
    if not value:
        raise Refused(reason)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def hex64(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def canonical_id(value):
    try:
        return str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def decode(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON field")
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        raise Refused("invalid JSON") from None


def identity(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_mode,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def private_regular(info):
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
            and not info.st_mode & 0o077 and info.st_nlink == 1, "unsafe private file")


class Directory:
    """Pin a no-follow parent, and recheck that its absolute route still names it."""
    def __init__(self, path, private=True):
        self.path = Path(path)
        self.private = private
        require(self.path.is_absolute() and ".." not in self.path.parts, "unsafe directory path")
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for component in self.path.parts[1:]:
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
                info = os.fstat(fd)
                sticky_root = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
                require(info.st_uid in (0, os.geteuid()) and (not info.st_mode & 0o022 or sticky_root),
                        "unsafe directory owner or mode")
            info = os.fstat(fd)
            require(info.st_uid == os.geteuid() and (not private or not info.st_mode & 0o077), "parent is not private")
            self.fd = fd
            self.inode = (info.st_dev, info.st_ino)
        except BaseException:
            os.close(fd)
            raise

    def close(self):
        os.close(self.fd)

    def check(self):
        other = Directory(self.path, self.private)
        try:
            require(other.inode == self.inode, "directory route changed")
        finally:
            other.close()

    def read(self, name, limit=65536, missing=False):
        self.check()
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        except FileNotFoundError:
            if missing:
                return None
            raise Refused("required private file missing") from None
        try:
            before = os.fstat(fd)
            private_regular(before)
            require(before.st_size <= limit, "private file exceeds limit")
            data = bytearray()
            while len(data) <= limit:
                chunk = os.read(fd, min(65536, limit + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
            require(len(data) <= limit, "private file exceeds limit")
            require(identity(before) == identity(os.fstat(fd)) == identity(
                os.stat(name, dir_fd=self.fd, follow_symlinks=False)), "private file changed")
            return bytes(data), identity(before)
        finally:
            os.close(fd)


def read_private(path, limit=65536):
    directory = Directory(path.parent)
    try:
        return directory.read(path.name, limit)
    finally:
        directory.close()


class Locks:
    def __init__(self, paths):
        self.paths, self.held = paths, []

    def __enter__(self):
        try:
            for path, mode in self.paths:
                directory = Directory(path.parent, private=path.name != "runtime-start-install.lock")
                try:
                    fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory.fd)
                except BaseException:
                    directory.close()
                    raise
                self.held.append((directory, path.name, fd, identity(os.fstat(fd))))
                metadata = os.fstat(fd)
                require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.geteuid()
                        and not metadata.st_mode & 0o022 and metadata.st_nlink == 1, "unsafe existing lock")
                try:
                    fcntl.flock(fd, mode | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise Refused("required existing lock is busy") from None
            self.check()
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def check(self):
        for directory, name, fd, before in self.held:
            directory.check()
            require(identity(os.fstat(fd)) == before == identity(
                os.stat(name, dir_fd=directory.fd, follow_symlinks=False)), "held lock replaced or changed")

    def __exit__(self, *_):
        for directory, _, fd, _ in reversed(self.held):
            os.close(fd)
            directory.close()
        self.held.clear()


def importer_arguments(args, operation):
    stage = ("codexswitch-auto-sync-" + operation).encode()
    local_stage = ("codexswitch-linux-credential-sync-" + operation).encode()
    return any(stage in arg or local_stage in arg for arg in args) or (
        any(b"codexswitch-cli" in arg for arg in args)
        and any(re.search(rb"(?:^|[\s;])(?:update-bundle|import)(?:$|[\s;])", arg) for arg in args))


def proc_bytes(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        require(len(data) <= limit, "process field exceeds limit")
        return bytes(data)
    finally:
        os.close(fd)


def check_mac_process_output(commands, arguments, operation):
    for output, executable_column in ((commands, True), (arguments, False)):
        require(len(output) <= 8 * 1024 * 1024, "local process inventory exceeds limit")
        for line in output.splitlines():
            fields = line.split(None, 2)
            require(len(fields) == 3, "incomplete local process inventory")
            if int(fields[0]) != os.geteuid() or int(fields[1]) == os.getpid():
                continue
            if executable_column:
                require(Path(os.fsdecode(fields[2])).name != "CodexSwitch", "local CodexSwitch process remains")
            else:
                require(not importer_arguments([fields[2]], operation), "local import or staging process remains")


def process_snapshot(entry):
    data = proc_bytes(entry / "stat", 8192)
    pid, rest = data.split(b"(", 1)
    comm, rest = rest.rsplit(b")", 1)
    values = rest.split()
    require(pid.strip() == entry.name.encode() and len(values) >= 20
            and values[19].isdigit(), "invalid process identity")
    fields = {}
    for line in proc_bytes(entry / "status", 65536).splitlines():
        key, sep, value = line.partition(b":")
        if sep:
            require(key not in fields, "duplicate process status field")
            fields[key] = value.strip()
    uids = (fields.get(b"Uid") or b"").split()
    uid = str(os.geteuid()).encode()
    require(fields.get(b"Tgid") == entry.name.encode() and len(uids) == 4
            and all(value.isdigit() for value in uids) and uids[1] == uid
            and entry.stat().st_uid == os.geteuid(), "invalid process ownership")
    return (pid.strip(), values[19], comm, tuple(uids)), values[0]


def supplementary_executable(entry):
    try:
        metadata = (entry / "exe").stat()
    except PermissionError as error:
        require(error.errno in (errno.EACCES, errno.EPERM), "unexpected executable access failure")
        return None
    require(stat.S_ISREG(metadata.st_mode), "owned process executable is not regular")
    return identity(metadata)


def explained_launch(argv0, comm):
    # Titles and basenames explain launch shape, not trusted executable identity.
    if not comm or re.search(rb"[\x00-\x1f\x7f]", argv0):
        return False
    basename = argv0.rsplit(b"/", 1)[-1]
    return (bool(basename) and not re.search(rb"\s", basename) and basename[:15] == comm
            or argv0.startswith(comm + b": "))


def scan_importers(operation, remote=False, proc_root=Path("/proc")):
    started = time.monotonic()
    if not remote:
        outputs = []
        # On macOS comm is fixed-width when another column follows it, even with -ww.
        for column in ("comm", "args"):
            result = subprocess.run(["/bin/ps", "-ww", "-axo", "uid=,pid=," + column + "="],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=4, check=True)
            outputs.append(result.stdout)
        check_mac_process_output(*outputs, operation)
        return
    for index, entry in enumerate(proc_root.iterdir()):
        require(index < 32768, "remote process inventory exceeds limit")
        require(time.monotonic() - started < 4, "remote process inventory timed out")
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        try:
            if entry.stat().st_uid != os.geteuid():
                continue
            before, state = process_snapshot(entry)
            if state == b"Z":
                continue
            command = proc_bytes(entry / "cmdline", 1024 * 1024)
            require(process_snapshot(entry)[0] == before, "process identity changed during scan")
            require(command and command.endswith(b"\0") and command.split(b"\0", 1)[0],
                    "owned process arguments unavailable")
            args = command[:-1].split(b"\0")
            require(not importer_arguments(args, operation), "remote importer or staging shell remains")
            executable = supplementary_executable(entry)
            require(executable is not None or explained_launch(args[0], before[2]),
                    "owned process launch form is unexplained")
            require(supplementary_executable(entry) == executable
                    and proc_bytes(entry / "cmdline", 1024 * 1024) == command
                    and process_snapshot(entry)[0] == before,
                    "owned process identity, executable or arguments changed")
        except FileNotFoundError:
            require(not entry.exists(), "owned live process has uninspectable identity")
            continue
        except (OSError, IndexError, ValueError):
            raise Refused("cannot prove owned process absence") from None


def absent(path):
    try:
        path.lstat()
    except FileNotFoundError:
        return True
    return False


def remote_lock_paths(home):
    state = home / ".codexswitch"
    return [(home / ".local/share/codexswitch/runtime-start-install.lock", fcntl.LOCK_SH),
            (state / "accounts.runtime-activation.lock", fcntl.LOCK_EX),
            (state / "accounts.provider-io.lock", fcntl.LOCK_EX),
            (state / "pool-authority.json.lock", fcntl.LOCK_EX),
            (state / "accounts.json.lock", fcntl.LOCK_EX)]


def token_fingerprint(account):
    parts = [account.get(key) for key in ("idToken", "accessToken", "refreshToken", "accountId")]
    require(all(isinstance(p, str) and p for p in parts), "active credentials incomplete")
    return sha(b"".join(len(p.encode()).to_bytes(8, "big") + p.encode() for p in parts))


def current_evidence(home):
    paths = [home / ".codexswitch" / name for name in
             ("accounts.json", "pool-authority.json", "accounts.activation.json")]
    paths.append(home / ".codex/auth.json")
    snapshots = [read_private(path, 8 * 1024 * 1024) for path in paths]
    accounts, authority, activation, auth = [decode(item[0]) for item in snapshots]
    require(isinstance(accounts, list) and accounts and all(isinstance(a, dict) for a in accounts),
            "account store shape invalid")
    ids = [a.get("accountId") for a in accounts]
    require(all(isinstance(i, str) and i for i in ids) and len(set(ids)) == len(ids), "account identities invalid")
    active = [a for a in accounts if a.get("isActive") is True]
    require(len(active) == 1, "account store lacks one active account")
    active = active[0]
    require(isinstance(authority, dict) and authority.get("version") == 1
            and authority.get("phase") == "stable" and type(authority.get("epoch")) is int
            and authority["epoch"] > 0 and canonical_id(authority.get("requestId"))
            and authority.get("desiredProviderAccountId") == active["accountId"], "authority not stable on active account")
    require(all(r.get("phase") == "completed" for r in authority.get("rotationOperations", [])),
            "unfinished authority rotation")
    require(isinstance(auth, dict) and isinstance(auth.get("tokens"), dict), "auth token structure invalid")
    require(all(auth["tokens"].get(a) == active.get(b) for a, b in [
        ("id_token", "idToken"), ("access_token", "accessToken"),
        ("refresh_token", "refreshToken"), ("account_id", "accountId")]), "auth does not match active store")
    require(isinstance(activation, dict) and activation.get("version") == 3
            and activation.get("state") == "confirmed" and activation.get("kind") in ("rotation", "import")
            and activation.get("targetAccountId") == active["accountId"]
            and activation.get("authFingerprint") == token_fingerprint(active)
            and all(activation.get(k) is None for k in ("rollback", "baseStoreGeneration", "ownedStoreGeneration",
                                                       "baseAuthGeneration", "ownedAuthGeneration")),
            "activation is not a current confirmed barrier")
    require(snapshots == [read_private(path, 8 * 1024 * 1024) for path in paths], "remote generations changed during read")
    return dict(zip(("storeGeneration", "authorityGeneration", "activationGeneration", "authGeneration"),
                    (sha(s[0]) for s in snapshots)), authorityEpoch=authority["epoch"])


class RemoteGuard:
    def __init__(self, home, release, operation, target, scanner=scan_importers, expected_cli=None):
        self.home, self.release, self.operation, self.target = home, release, operation, target
        self.scanner = scanner
        self.nonce = str(uuid.uuid4())
        self.expected_cli = expected_cli

    def __enter__(self):
        require(canonical_id(self.operation) and hex64(self.target), "invalid remote binding")
        self.locks = Locks(remote_lock_paths(self.home)).__enter__()
        self.deadline = time.monotonic() + SESSION_SECONDS
        return self

    def alive(self):
        self.locks.check()
        require(self.deadline - time.monotonic() >= MIN_HOLD_SECONDS, "remote guard deadline too close")

    def observe(self):
        self.alive()
        root = self.home / ".local/share/codexswitch"
        require(self.release.parent == root / "releases" and self.release.is_absolute(), "invalid immutable release scope")
        require((root / "current").resolve(strict=True) == self.release, "current release changed")
        # Release directories may be 0755; only the credential/lock parents require 0700.
        for path in (self.release, self.release / "codexswitch-cli"):
            info = path.lstat()
            require(not stat.S_ISLNK(info.st_mode) and info.st_uid == os.geteuid()
                    and not info.st_mode & 0o022, "unsafe immutable release")
        require(stat.S_ISREG((self.release / "codexswitch-cli").lstat().st_mode), "missing release executable")
        release_dir = Directory(self.release, private=False)
        try:
            fd = os.open("codexswitch-cli", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=release_dir.fd)
            try:
                before = os.fstat(fd)
                require(before.st_size <= 128 * 1024 * 1024, "release executable exceeds limit")
                digest, count = hashlib.sha256(), 0
                while True:
                    chunk = os.read(fd, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
                    count += len(chunk)
                    require(count <= 128 * 1024 * 1024, "release executable exceeds limit")
                require(identity(before) == identity(os.fstat(fd)) == identity(
                    os.stat("codexswitch-cli", dir_fd=release_dir.fd, follow_symlinks=False)), "release executable changed")
                cli_hash = digest.hexdigest()
                require(self.expected_cli is None or cli_hash == self.expected_cli, "CLI does not match reviewed attestation")
            finally:
                os.close(fd)
            release_dir.check()
        finally:
            release_dir.close()
        self.scanner(self.operation, True)
        require(absent(Path("/tmp") / ("codexswitch-auto-sync-" + self.operation)), "remote stage remains")
        receipts = self.receipt_ledger()
        evidence = current_evidence(self.home)
        self.scanner(self.operation, True)
        require(absent(Path("/tmp") / ("codexswitch-auto-sync-" + self.operation)), "remote stage reappeared")
        require(evidence == current_evidence(self.home), "remote generations changed during process inspection")
        require(receipts == self.receipt_ledger(), "remote receipt ledger changed")
        self.alive()
        require((root / "current").resolve(strict=True) == self.release, "release route changed")
        return dict(evidence, version=1, operationId=self.operation, targetFingerprint=self.target,
                    leaseNonce=self.nonce, releaseFingerprint=sha(os.fsencode(self.release)),
                    cliGeneration=cli_hash,
                    receiptLedgerGeneration=sha(receipts[0] if receipts else b"missing"),
                    observedAt=time.time(), leaseSecondsRemaining=self.deadline - time.monotonic())

    def receipt_ledger(self):
        directory = Directory(self.home / ".codexswitch")
        try:
            snapshot = directory.read("accounts.json.credential-import-receipts.json", 8 * 1024 * 1024, missing=True)
            if snapshot is not None:
                ledger = decode(snapshot[0])
                require(isinstance(ledger, dict) and set(ledger) == {"version", "records"}
                        and ledger["version"] == 1 and isinstance(ledger["records"], list)
                        and len(ledger["records"]) <= 1024, "remote receipt ledger invalid")
                for record in ledger["records"]:
                    require(isinstance(record, dict) and record.get("state") == "completed"
                            and isinstance(record.get("receipt"), dict)
                            and canonical_id(record["receipt"].get("operationId")),
                            "pending or malformed durable receipt requires reconciliation")
                    require(record["receipt"]["operationId"] != self.operation,
                            "durable operation receipt exists; legacy supersession is forbidden")
            return snapshot
        finally:
            directory.close()

    def __exit__(self, *args):
        self.locks.__exit__(*args)


FIELDS = set("version operationID targetFingerprint credentialFingerprint expectedAccountIdentityFingerprint "
             "expectedCredentialSetFingerprint expectedActiveProviderAccountId expectedActiveTokenHashPrefix "
             "baselineAccountIdentityFingerprint baselineCredentialSetFingerprint baselineActiveProviderAccountId "
             "baselineActiveTokenHashPrefix baselineAuthMatchesActiveStoreToken localDirectory remoteDirectory "
             "createdAt phase reason".split())


class LocalGuard:
    def __init__(self, home, target, stage_root=None, scanner=scan_importers):
        self.home, self.target, self.scanner = home, target, scanner
        self.stage_root = Path(stage_root or tempfile.gettempdir()).resolve()
        self.path = home / ".codexswitch" / JOURNAL
        self.backup = Path(str(self.path) + ".legacy-unresolved-backup.json")

    def __enter__(self):
        self.stack = contextlib.ExitStack()
        try:
            self.locks = self.stack.enter_context(Locks([
                (self.home / ".codexswitch/codexswitch-app.lock", fcntl.LOCK_EX),
                (Path(str(self.path) + ".lock"), fcntl.LOCK_EX)]))
            self.directory = Directory(self.path.parent)
            self.stack.callback(self.directory.close)
            self.snapshot = self.directory.read(self.path.name)
            self.operation = decode(self.snapshot[0])
            op = self.operation
            require(isinstance(op, dict) and FIELDS <= set(op) <= FIELDS | {"importReceipt"}, "unknown or missing journal fields")
            require(op["version"] == 2 and op["phase"] == "unresolved" and op.get("importReceipt") is None
                    and canonical_id(op["operationID"]) and op["targetFingerprint"] == self.target,
                    "journal is not the reviewed unresolved target")
            for key in FIELDS:
                if "Fingerprint" in key:
                    require(hex64(op[key]), "invalid journal fingerprint")
            require(op["remoteDirectory"] == "/tmp/codexswitch-auto-sync-" + op["operationID"], "remote stage binding invalid")
            stage = Path(op["localDirectory"])
            require(stage.parent.resolve() == self.stage_root and stage.name ==
                    "codexswitch-linux-credential-sync-" + op["operationID"], "local stage binding invalid")
            self.local_stage = self.stage_root / stage.name
            self.check()
            return self
        except BaseException:
            self.stack.close()
            raise

    def check(self):
        self.locks.check()
        require(self.directory.read(self.path.name) == self.snapshot, "reviewed journal generation or identity changed")
        self.scanner(self.operation["operationID"], False)
        require(absent(self.local_stage), "local stage remains")

    def review(self):
        self.check()
        generation = sha(self.snapshot[0])
        operation = self.operation["operationID"]
        return {"operationId": operation, "journalGeneration": generation,
                "targetFingerprint": self.target, "confirmation": "supersede-unknown:" + operation + ":" + generation}

    def save_backup(self):
        name = self.backup.name
        existing = self.directory.read(name, missing=True)
        if existing is not None:
            require(existing[0] == self.snapshot[0], "backup slot belongs to another generation")
            return
        # O_EXCL never overwrites an old backup. An interrupted write blocks future apply.
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=self.directory.fd)
        try:
            data = memoryview(self.snapshot[0])
            while data:
                count = os.write(fd, data)
                require(count > 0, "backup write failed")
                data = data[count:]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.fsync(self.directory.fd)
        require(self.directory.read(name)[0] == self.snapshot[0], "backup readback failed")

    def apply(self, confirmation, remote):
        require(confirmation == self.review()["confirmation"], "exact operator confirmation required")
        before = remote.observe()
        validate_evidence(before, self.operation["operationID"], self.target)
        self.check()
        self.save_backup()
        after = remote.observe()
        validate_evidence(after, self.operation["operationID"], self.target)
        require(stable_evidence(before) == stable_evidence(after), "remote evidence changed after backup")
        self.check()
        require(self.directory.read(self.backup.name)[0] == self.snapshot[0], "backup changed")
        validate_evidence(after, self.operation["operationID"], self.target)
        remote.alive()
        self.locks.check()
        require(self.directory.read(self.path.name) == self.snapshot, "journal changed before retirement")
        os.unlink(self.path.name, dir_fd=self.directory.fd)
        os.fsync(self.directory.fd)
        require(self.directory.read(self.path.name, missing=True) is None, "retired journal reappeared")
        return {"disposition": "supersededUnknownOutcome", "operationId": self.operation["operationID"],
                "journalGeneration": sha(self.snapshot[0]), "backupPath": str(self.backup)}

    def __exit__(self, *_):
        self.stack.close()


def stable_evidence(value):
    return {k: v for k, v in value.items() if k not in ("observedAt", "leaseSecondsRemaining")}


def validate_evidence(value, operation, target):
    keys = {"storeGeneration", "authorityGeneration", "activationGeneration", "authGeneration",
            "authorityEpoch", "version", "operationId", "targetFingerprint", "leaseNonce",
            "releaseFingerprint", "cliGeneration", "receiptLedgerGeneration", "observedAt", "leaseSecondsRemaining"}
    require(isinstance(value, dict) and set(value) == keys, "unexpected guard evidence schema")
    require(value["version"] == 1 and value["operationId"] == operation and value["targetFingerprint"] == target
            and canonical_id(value["leaseNonce"]), "guard evidence binding invalid")
    require(all(hex64(value[k]) for k in keys if k.endswith(("Generation", "Fingerprint"))), "invalid generation evidence")
    require(type(value["authorityEpoch"]) is int and value["authorityEpoch"] > 0, "invalid authority epoch")
    require(-5 <= time.time() - value["observedAt"] <= 8 and value["leaseSecondsRemaining"] >= MIN_HOLD_SECONDS,
            "stale guard evidence or insufficient lease time")


def read_line(fd, timeout):
    deadline, data = time.monotonic() + timeout, bytearray()
    while len(data) <= MAX_MESSAGE:
        remaining = deadline - time.monotonic()
        require(remaining > 0 and select.select([fd], [], [], remaining)[0], "guard response timed out")
        part = os.read(fd, 1)
        require(part, "guard transport closed")
        if part == b"\n":
            return decode(bytes(data))
        data.extend(part)
    raise Refused("guard message exceeds limit")


def send_line(fd, value):
    data = memoryview(json.dumps(value, separators=(",", ":")).encode() + b"\n")
    require(len(data) <= MAX_MESSAGE, "guard message exceeds limit")
    while data:
        count = os.write(fd, data)
        require(count > 0, "guard pipe write failed")
        data = data[count:]


def serve_guard(guard, input_fd=0, output_fd=1, grace=MIN_HOLD_SECONDS):
    with guard:
        last = 0
        try:
            while True:
                request = read_line(input_fd, max(1, guard.deadline - time.monotonic()))
                require(isinstance(request, dict) and set(request) == {"command", "sequence"}
                        and type(request["sequence"]) is int and request["sequence"] == last + 1,
                        "invalid guard challenge")
                last += 1
                if request["command"] == "release":
                    return
                require(request["command"] == "observe", "unsupported guard challenge")
                evidence = guard.observe()
                send_line(output_fd, {"sequence": last, "evidence": evidence})
        except BaseException:
            # A lost reply must not turn a lease observation into an instantaneous unlock.
            time.sleep(max(0, min(grace, guard.deadline - time.monotonic())))
            raise


def remote_worker(config):
    require(sys.platform.startswith("linux"), "remote helper requires Linux")
    require(Path(pwd.getpwuid(os.geteuid()).pw_dir) == Path(config["home"]), "remote login home mismatch")
    require(hex64(config["cli"]), "reviewed CLI digest required")
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    serve_guard(RemoteGuard(Path(config["home"]), Path(config["release"]), config["operation"],
                           config["target"], expected_cli=config["cli"]))


class SSHGuard:
    def __init__(self, args, operation, target):
        self.args, self.operation, self.target = args, operation, target
        self.sequence = 0

    def __enter__(self):
        config = {"home": self.args.remote_home, "release": self.args.remote_release,
                  "operation": self.operation, "target": self.target, "cli": self.args.expected_cli_sha256}
        source = Path(__file__).read_bytes()
        require(len(source) <= 96 * 1024, "helper source exceeds bound")
        bootstrap = "import base64;exec(compile(base64.b64decode(" + repr(base64.b64encode(source).decode()) + "),'<legacy-guard>','exec'))"
        command = shlex.join(["python3", "-B", "-c", bootstrap, "--remote-worker",
                              base64.b64encode(json.dumps(config).encode()).decode()])
        args = ["/usr/bin/ssh", "-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oIdentitiesOnly=yes",
                "-oConnectTimeout=5", "-oServerAliveInterval=3", "-oServerAliveCountMax=2",
                "-p", str(self.args.port), "-i", os.path.expanduser(self.args.ssh_key),
                "-l", self.args.user, self.args.host, command]
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return self

    def alive(self):
        require(self.process.poll() is None, "authenticated SSH guard exited")

    def observe(self):
        self.alive()
        self.sequence += 1
        started = time.monotonic()
        send_line(self.process.stdin.fileno(), {"command": "observe", "sequence": self.sequence})
        reply = read_line(self.process.stdout.fileno(), 8)
        require(time.monotonic() - started <= 8 and isinstance(reply, dict)
                and set(reply) == {"sequence", "evidence"} and reply["sequence"] == self.sequence,
                "guard challenge response mismatch")
        self.alive()
        validate_evidence(reply["evidence"], self.operation, self.target)
        require(reply["evidence"]["releaseFingerprint"] == sha(os.fsencode(self.args.remote_release)), "release evidence mismatch")
        require(reply["evidence"]["cliGeneration"] == self.args.expected_cli_sha256, "CLI evidence mismatch")
        return reply["evidence"]

    def __exit__(self, *_):
        try:
            if self.process.poll() is None:
                send_line(self.process.stdin.fileno(), {"command": "release", "sequence": self.sequence + 1})
            self.process.stdin.close()
            self.process.wait(timeout=MIN_HOLD_SECONDS + 5)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()  # Only this tool's SSH transport, never a VPS service.
            self.process.wait()
        finally:
            self.process.stdout.close()


def main():
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if len(sys.argv) == 3 and sys.argv[1] == "--remote-worker":
        remote_worker(decode(base64.b64decode(sys.argv[2], validate=True)))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("review", "apply"))
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--ssh-key", required=True)
    parser.add_argument("--remote-home", required=True)
    parser.add_argument("--remote-release", required=True)
    parser.add_argument("--expected-cli-sha256", required=True)
    parser.add_argument("--local-home", default=str(Path.home()))
    parser.add_argument("--confirm")
    args = parser.parse_args()
    require(sys.platform == "darwin", "local operator workflow requires macOS")
    require(hex64(args.expected_cli_sha256), "reviewed CLI digest required")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,252}", args.host)
            and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]{0,63}", args.user)
            and 1 <= args.port <= 65535, "invalid SSH endpoint")
    target = sha(b"".join(v.encode() + b"\0" for v in
                         (args.user, args.host, str(args.port), os.path.expanduser(args.ssh_key))))
    with LocalGuard(Path(args.local_home), target) as local:
        if args.action == "apply":
            require(args.confirm == local.review()["confirmation"], "exact operator confirmation required")
        with SSHGuard(args, local.operation["operationID"], target) as remote:
            if args.action == "review":
                evidence = remote.observe()
                result = dict(local.review(), disposition="reviewOnly", evidence=evidence)
            else:
                result = local.apply(args.confirm, remote)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt):
        # Never echo exceptions from JSON, subprocesses, process argv or credential reads.
        print("Legacy supersession refused or interrupted; inspect the private journal and backup before retrying.", file=sys.stderr)
        sys.exit(1)
