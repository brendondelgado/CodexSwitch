#!/usr/bin/env python3
"""Explicit, metadata-only recovery of a dead legacy app-server PID record."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import struct
import time


class Refused(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def identity(metadata):
    return (metadata.st_dev, metadata.st_ino, metadata.st_uid, metadata.st_gid,
            metadata.st_mode, metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)


def secure_path(path, uid):
    for part in [path, *path.parents]:
        value = part.lstat()
        require(not stat.S_ISLNK(value.st_mode), f"linked path: {part}")
        require(value.st_uid in (0, uid), f"foreign owner: {part}")
        require(not value.st_mode & 0o002 or (stat.S_ISDIR(value.st_mode)
                and value.st_uid == 0 and value.st_mode & stat.S_ISVTX),
                f"world-writable path: {part}")


def read_bounded(path, limit=32768):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode), f"not regular: {path}")
        data = bytearray()
        while True:
            chunk = os.read(fd, limit + 1 - len(data))
            if not chunk:
                break
            data.extend(chunk)
            require(len(data) <= limit, f"read limit: {path}")
        require(identity(before) == identity(os.fstat(fd)), f"changed while reading: {path}")
        return bytes(data), identity(before)
    finally:
        os.close(fd)


def command_arguments(data):
    require(bool(data) and data.endswith(b"\0"), "empty or incomplete process arguments")
    args = data[:-1].split(b"\0")
    require(bool(args[0]), "process executable argument is empty")
    return args


@contextlib.contextmanager
def held_locks(paths, uid):
    descriptors = []
    try:
        for path, mode in paths:
            secure_path(path, uid)
            fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
            descriptors.append((path, fd))
            value = os.fstat(fd)
            require(stat.S_ISREG(value.st_mode) and value.st_uid == uid
                    and not value.st_mode & 0o022, f"unsafe lock: {path}")
            fcntl.flock(fd, mode | fcntl.LOCK_NB)
            require(identity(value) == identity(path.lstat()), f"replaced lock: {path}")
        yield lambda: all(identity(os.fstat(fd)) == identity(path.lstat())
                          for path, fd in descriptors)
    finally:
        for _, fd in reversed(descriptors):
            os.close(fd)


class LiveProbe:
    def __init__(self, home, pid, release, proc_root=Path("/proc")):
        self.home, self.pid, self.uid = home, pid, os.geteuid()
        self.proc_root = proc_root
        self.root = home / ".local/share/codexswitch"
        self.release = self.root / "releases" / ("0.1.0-" + release)
        self.route = self.root / "current/patched-codex/codex"
        self.runtime = self.release / "patched-codex/codex"
        self.control = home / ".codex/app-server-control/app-server-control.sock"

    def absent(self, pid):
        return not os.path.lexists(self.proc_root / str(pid))

    def observe(self):
        secure_path(self.runtime, self.uid)
        require(self.root.joinpath("current").resolve(strict=True) == self.release,
                "current release changed")
        expected = self.runtime.stat()
        proc = self.proc_root / str(self.pid)
        require(proc.stat().st_uid == self.uid, "runtime owner changed")
        executable = proc.joinpath("exe").stat()
        require((executable.st_dev, executable.st_ino) == (expected.st_dev, expected.st_ino)
                and proc.joinpath("exe").resolve(strict=True) == self.runtime,
                "runtime executable changed")
        process_stat, _ = read_bounded(proc / "stat")
        start_ticks = process_stat.rsplit(b")", 1)[1].split()[19]
        command, _ = read_bounded(proc / "cmdline")
        args = command_arguments(command)
        allowed = []
        for executable_path in (self.route, self.runtime):
            for configuration in ([], [b"-c", b"features.code_mode_host=true"]):
                for remote in ([], [b"--remote-control"]):
                    allowed.append([os.fsencode(executable_path), *configuration,
                                    b"app-server", *remote, b"--listen", b"unix://"])
        require(args in allowed, "unexpected runtime arguments")
        environment, _ = read_bounded(proc / "environ", 65536)
        values = {}
        for item in environment.split(b"\0"):
            key, _, value = item.partition(b"=")
            if key in (b"HOME", b"CODEX_HOME"):
                require(key not in values, "duplicate runtime home")
                values[key] = value
        observed_home = Path(os.fsdecode(values.get(b"CODEX_HOME", values.get(b"HOME", b"") + b"/.codex")))
        require(observed_home.is_absolute() and observed_home.resolve(strict=True) == self.home / ".codex",
                "runtime has a different Codex home")
        secure_path(self.control, self.uid)
        control = self.control.lstat()
        require(stat.S_ISSOCK(control.st_mode) and control.st_uid == self.uid,
                "control socket ownership changed")
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(2)
            client.connect(str(self.control))
            peer_pid, peer_uid, _ = struct.unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            require((peer_pid, peer_uid) == (self.pid, self.uid), "socket peer is not the expected runtime")
        candidates = []
        started = time.monotonic()
        for index, entry in enumerate(self.proc_root.iterdir()):
            require(index < 32768 and time.monotonic() - started < 5, "process scan exceeded bound")
            if not entry.name.isdigit():
                continue
            try:
                if entry.stat().st_uid != self.uid:
                    continue
                exe = (entry / "exe").stat()
                if (exe.st_dev, exe.st_ino) != (expected.st_dev, expected.st_ino):
                    continue
                argv, _ = read_bounded(entry / "cmdline")
            except FileNotFoundError:
                continue
            except PermissionError:
                # Same-UID privileged helpers can hide exe while exposing argv.
                # Only a complete, non-app-server command line proves irrelevance.
                argv, _ = read_bounded(entry / "cmdline")
                require(b"app-server" not in command_arguments(argv),
                        "app-server executable cannot be inspected")
                continue
            parts = command_arguments(argv)
            if b"app-server" in parts:
                subcommand = parts.index(b"app-server")
                if parts[subcommand + 1:subcommand + 2] in ([b"proxy"], [b"daemon"]):
                    continue
                candidates.append(int(entry.name))
        require(candidates == [self.pid], "multiple or missing current-runtime app servers")
        final_stat, _ = read_bounded(proc / "stat")
        require(final_stat.rsplit(b")", 1)[1].split()[19] == start_ticks
                and proc.stat().st_uid == self.uid
                and identity(proc.joinpath("exe").stat()) == identity(expected)
                and read_bounded(proc / "cmdline")[0] == command
                and identity(self.control.lstat()) == identity(control)
                and self.root.joinpath("current").resolve(strict=True) == self.release,
                "runtime identity changed during observation")
        return (start_ticks, identity(expected), identity(control), command)


def repair(home, probe, expected_stale_pid, apply=False, before_commit=lambda: None, expected_sha256=None):
    uid = os.geteuid()
    root = home / ".local/share/codexswitch"
    codex = home / ".codex"
    record = codex / "app-server-daemon/app-server.pid"
    locks = [(root / "runtime-start-install.lock", fcntl.LOCK_SH),
             (codex / "app-server-daemon/app-server.pid.lock", fcntl.LOCK_EX),
             (codex / "app-server-control/app-server-startup.lock", fcntl.LOCK_EX),
             (home / ".codexswitch/accounts.runtime-activation.lock", fcntl.LOCK_EX)]
    with held_locks(locks, uid) as locks_current:
        observed = probe.observe()
        if not record.exists() and not record.is_symlink():
            return {"status": "already-clear", "livePid": probe.pid}
        secure_path(record, uid)
        data, original = read_bounded(record, 4096)
        parsed = json.loads(data)
        stale_pid = parsed.get("pid")
        require(type(stale_pid) is int and stale_pid == expected_stale_pid and stale_pid > 0
                and stale_pid != probe.pid, "record does not name the approved stale owner")
        require(probe.absent(stale_pid), "recorded PID still exists; refusing PID reuse or a live conflict")
        result = {"status": "repairable", "stalePid": stale_pid, "livePid": probe.pid,
                  "recordSha256": hashlib.sha256(data).hexdigest()}
        if not apply:
            return result
        require(expected_sha256 == result["recordSha256"], "PID record differs from approved digest")
        backup_root = home / ".codexswitch/backups/runtime-ownership"
        for directory in (home / ".codexswitch", home / ".codexswitch/backups", backup_root):
            directory.mkdir(mode=0o700, exist_ok=True)
            secure_path(directory, uid)
            require(directory.stat().st_uid == uid and not directory.stat().st_mode & 0o077,
                    f"backup directory is not private: {directory}")
        backup = backup_root / (f"legacy-pid-{stale_pid}-{time.time_ns()}.json")
        before_commit()
        require(locks_current() and probe.observe() == observed and probe.absent(stale_pid),
                "ownership changed before repair")
        require(read_bounded(record, 4096) == (data, original), "PID record changed before repair")
        # Rename retains the original record verbatim and leaves no forged owner record.
        require(not backup.exists(), "backup destination already exists")
        os.rename(record, backup)
        os.chmod(backup, 0o600)
        for directory in (record.parent, backup_root):
            fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        require(locks_current() and probe.observe() == observed and probe.absent(stale_pid),
                "ownership changed after quarantine; inspect retained backup")
        require(not os.path.lexists(record), "PID record reappeared after repair")
        result.update(status="repaired", backup=str(backup))
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-pid", required=True, type=int)
    parser.add_argument("--expected-release", required=True)
    parser.add_argument("--expected-host", required=True)
    parser.add_argument("--expected-stale-pid", required=True, type=int)
    parser.add_argument("--expected-record-sha256")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    require(socket.gethostname() == args.expected_host, "unexpected host")
    require(args.expected_pid > 0 and len(args.expected_release) == 40
            and all(c in "0123456789abcdef" for c in args.expected_release), "invalid expected identity")
    home = Path.home()
    print(json.dumps(repair(home, LiveProbe(home, args.expected_pid, args.expected_release),
                            args.expected_stale_pid, args.apply,
                            expected_sha256=args.expected_record_sha256)))


if __name__ == "__main__":
    try:
        main()
    except (Refused, OSError, ValueError) as error:
        print(json.dumps({"status": "refused", "error": str(error)}))
        raise SystemExit(1)
