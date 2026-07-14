#!/usr/bin/env python3
import fcntl
import json
import os
import stat
import subprocess
import sys
import time
from pathlib import Path

proc_root = Path(sys.argv[1])
codex_home = Path(sys.argv[2])
runtime = Path(sys.argv[3])
reservation = Path(sys.argv[4])
reservation_held = sys.argv[5] == "1"
timeout_seconds = int(sys.argv[6])
max_entries = int(sys.argv[7])
state_limit = int(sys.argv[8])
allow_missing_runtime = len(sys.argv) == 10 and sys.argv[9] == "1"
pid_path = codex_home / "app-server-daemon/app-server.pid"
socket_path = codex_home / "app-server-control/app-server-control.sock"

def result(state: str, reason: str) -> None:
    print(f"{state}\t{reason}")
    raise SystemExit(0)

def bounded_regular(path: Path):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        result("unknown", f"artifact-inspection:{path.name}:{error.__class__.__name__}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        result("unknown", f"artifact-not-regular:{path.name}")
    if metadata.st_size > state_limit:
        result("unknown", f"artifact-oversized:{path.name}")
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        result("unknown", f"artifact-open:{path.name}:{error.__class__.__name__}")
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
            result("unknown", f"artifact-identity-drift:{path.name}")
        try:
            data = os.read(descriptor, state_limit + 1)
            trailing = os.read(descriptor, 1)
        except OSError as error:
            result("unknown", f"artifact-read:{path.name}:{error.__class__.__name__}")
        if len(data) > state_limit or trailing:
            result("unknown", f"artifact-read-limit:{path.name}")
        return data
    finally:
        os.close(descriptor)

if not reservation_held:
    try:
        lock_metadata = reservation.lstat()
    except FileNotFoundError:
        pass
    except OSError as error:
        result("unknown", f"reservation-inspection:{error.__class__.__name__}")
    else:
        if stat.S_ISLNK(lock_metadata.st_mode) or not stat.S_ISREG(lock_metadata.st_mode):
            result("unknown", "reservation-not-regular")
        try:
            descriptor = os.open(reservation, os.O_RDWR | os.O_NOFOLLOW)
        except OSError as error:
            result("unknown", f"reservation-open:{error.__class__.__name__}")
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                result("active", "reservation-held")
            except OSError as error:
                result("unknown", f"reservation-probe:{error.__class__.__name__}")
            else:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)

try:
    runtime_lstat = runtime.lstat()
except FileNotFoundError as error:
    if not allow_missing_runtime:
        result("unknown", f"runtime-unavailable:{error.__class__.__name__}")
    runtime_metadata = None
except OSError as error:
    result("unknown", f"runtime-unavailable:{error.__class__.__name__}")
else:
    if stat.S_ISLNK(runtime_lstat.st_mode) or not stat.S_ISREG(runtime_lstat.st_mode):
        result("unknown", "runtime-not-regular")
    runtime_metadata = runtime_lstat
runtime_canonical = Path(os.path.realpath(runtime))

def process_start_ticks(pid: int):
    path = proc_root / str(pid) / "stat"
    data = bounded_regular(path)
    if data is None:
        return None
    try:
        text = data.decode("utf-8")
        fields = text[text.rfind(")") + 2:].split()
        return fields[19]
    except (UnicodeDecodeError, IndexError):
        result("unknown", f"process-start-malformed:{pid}")

def exact_process(pid: int):
    process_dir = proc_root / str(pid)
    try:
        owner = process_dir.stat().st_uid
    except FileNotFoundError:
        return "unrelated"
    except OSError as error:
        result("unknown", f"process-inspection:{pid}:{error.__class__.__name__}")
    if owner != os.geteuid():
        return "unrelated"
    start_before = process_start_ticks(pid)
    if start_before is None:
        return "unrelated"
    command_line = bounded_regular(process_dir / "cmdline")
    if command_line is None:
        result("unknown", f"process-argv-missing:{pid}")
    argv = [value for value in command_line.split(b"\0") if value]
    expected = [os.fsencode(runtime), b"app-server", b"--listen", b"unix://"]
    if runtime_metadata is None:
        if not argv or argv[0] != expected[0]:
            return "unrelated"
        if argv != expected:
            result("unknown", f"process-managed-path-argv-drift:{pid}")
        start_after = process_start_ticks(pid)
        if start_after is None or start_before != start_after:
            result("unknown", f"process-start-drift:{pid}")
        return "active"
    exe = process_dir / "exe"
    try:
        executable = exe.stat()
    except FileNotFoundError:
        return "unrelated"
    except OSError as error:
        result("unknown", f"process-exe:{pid}:{error.__class__.__name__}")
    if (executable.st_dev, executable.st_ino) != (runtime_metadata.st_dev, runtime_metadata.st_ino):
        if argv == expected:
            result("unknown", f"process-exact-managed-argv-replaced-inode:{pid}")
        return "unrelated"
    try:
        observed_canonical = Path(os.path.realpath(exe))
    except OSError as error:
        result("unknown", f"process-canonical:{pid}:{error.__class__.__name__}")
    if observed_canonical != runtime_canonical:
        result("unknown", f"process-canonical-drift:{pid}")
    if argv != expected:
        result("unknown", f"process-argv-drift:{pid}")
    start_after = process_start_ticks(pid)
    if start_after is None or start_before != start_after:
        result("unknown", f"process-start-drift:{pid}")
    return "active"

pid_bytes = bounded_regular(pid_path)
if pid_bytes is not None:
    try:
        record = json.loads(pid_bytes)
        pid = record["pid"]
        recorded_start = str(record["processStartTime"])
        if not isinstance(pid, int) or pid <= 0 or not recorded_start:
            raise ValueError
    except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        result("unknown", "pid-record-malformed")
    process_dir = proc_root / str(pid)
    if process_dir.exists():
        try:
            observed = subprocess.run(
                ["/bin/ps", "-p", str(pid), "-o", "lstart="],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, timeout=timeout_seconds, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            result("unknown", f"pid-start-probe:{error.__class__.__name__}")
        if (
            len(observed.stdout) + len(observed.stderr) > state_limit
            or observed.returncode != 0
            or observed.stderr
        ):
            result("unknown", "pid-start-probe-failed")
        try:
            observed_start = observed.stdout.decode("utf-8", errors="strict").strip()
        except UnicodeDecodeError:
            result("unknown", "pid-start-non-utf8")
        if observed_start != recorded_start:
            result("unknown", "pid-start-mismatch")
        identity = exact_process(pid)
        if identity == "active":
            result("active", "pid-record-active")
        result("unknown", "pid-record-live-unrelated")

started = time.monotonic()
try:
    entries = os.scandir(proc_root)
except OSError as error:
    result("unknown", f"proc-scan-open:{error.__class__.__name__}")
count = 0
with entries:
    for entry in entries:
        count += 1
        if count > max_entries or time.monotonic() - started > timeout_seconds:
            result("unknown", "proc-scan-bound")
        if not entry.name.isdigit():
            continue
        identity = exact_process(int(entry.name))
        if identity == "active":
            result("active", "exact-process-active")

try:
    socket_metadata = socket_path.lstat()
except FileNotFoundError:
    pass
except OSError as error:
    result("unknown", f"socket-inspection:{error.__class__.__name__}")
else:
    if stat.S_ISSOCK(socket_metadata.st_mode):
        result("unknown", "daemon-socket-present")
    result("unknown", "daemon-socket-malformed")
if runtime_metadata is None:
    result("inactive", "absent-runtime-and-artifacts-inactive")
result("inactive", "artifacts-and-processes-inactive")
