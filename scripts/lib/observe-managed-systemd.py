#!/usr/bin/env python3
import os
import selectors
import shlex
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

unit = sys.argv[1]
fragment = Path(sys.argv[2])
timeout_seconds = int(sys.argv[3])
output_limit = int(sys.argv[4])
expected_argv = sys.argv[5:]

def result(state: str, reason: str) -> None:
    print(f"{state}\t{reason}")
    raise SystemExit(0)

if not fragment.is_absolute() or Path(os.path.realpath(fragment)) != fragment:
    result("unknown", "fragment-canonical-drift")
if not expected_argv or not os.path.isabs(expected_argv[0]):
    result("unknown", "expected-execstart-invalid")
try:
    metadata = fragment.lstat()
except FileNotFoundError:
    fragment_absent = True
except OSError as error:
    result("unknown", f"fragment-inspection:{error.__class__.__name__}")
else:
    fragment_absent = False
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        result("unknown", "fragment-not-regular")

systemctl = shutil.which("systemctl")
if systemctl is None:
    result("unknown", "systemctl-missing")
command = [
    systemctl, "--user", "show", unit,
    "--property=LoadState", "--property=ActiveState",
    "--property=FragmentPath", "--property=ExecStart", "--property=MainPID",
]
try:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
except OSError as error:
    result("unknown", f"systemctl-spawn:{error.__class__.__name__}")
selector = selectors.DefaultSelector()
if process.stdout is None or process.stderr is None:
    process.kill()
    process.wait()
    result("unknown", "systemctl-pipe-unavailable")
selector.register(process.stdout, selectors.EVENT_READ)
selector.register(process.stderr, selectors.EVENT_READ)
captured = {process.stdout: bytearray(), process.stderr: bytearray()}
deadline = time.monotonic() + timeout_seconds
while selector.get_map():
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        process.kill()
        process.wait()
        result("unknown", "systemctl-timeout")
    events = selector.select(remaining)
    if not events:
        process.kill()
        process.wait()
        result("unknown", "systemctl-timeout")
    for key, _mask in events:
        chunk = os.read(key.fileobj.fileno(), 4096)
        if not chunk:
            selector.unregister(key.fileobj)
            continue
        captured[key.fileobj].extend(chunk)
        if sum(len(value) for value in captured.values()) > output_limit:
            process.kill()
            process.wait()
            result("unknown", "systemctl-output-limit")
status = process.wait()
if status != 0:
    result("unknown", f"systemctl-exit-{status}")
if captured[process.stderr]:
    result("unknown", "systemctl-stderr")
try:
    output = bytes(captured[process.stdout]).decode("utf-8")
except UnicodeDecodeError:
    result("unknown", "systemctl-non-utf8")
properties = {}
for line in output.splitlines():
    if "=" not in line:
        result("unknown", "systemctl-malformed")
    key, value = line.split("=", 1)
    if key in properties:
        result("unknown", f"systemctl-duplicate-{key}")
    properties[key] = value
expected_keys = {"LoadState", "ActiveState", "FragmentPath", "ExecStart", "MainPID"}
if set(properties) != expected_keys:
    result("unknown", "systemctl-incomplete")
main_pid = properties["MainPID"]
if not main_pid.isascii() or not main_pid.isdecimal():
    result("unknown", "main-pid-malformed")
if fragment_absent:
    if properties["LoadState"] != "not-found":
        result("unknown", f"missing-fragment-load-state-{properties['LoadState']}")
    if properties["ActiveState"] != "inactive":
        result("unknown", f"missing-fragment-active-state-{properties['ActiveState']}")
    if properties["FragmentPath"]:
        result("unknown", "missing-fragment-provenance-present")
    if properties["ExecStart"]:
        result("unknown", "missing-fragment-execstart-present")
    if main_pid != "0":
        result("unknown", "missing-fragment-main-pid")
    result("inactive", "exact-not-found")
if properties["LoadState"] != "loaded":
    result("unknown", f"load-state-{properties['LoadState']}")
if properties["FragmentPath"] != str(fragment):
    result("unknown", "fragment-provenance-drift")
exec_start = properties["ExecStart"]
if "argv[]=" not in exec_start:
    result("unknown", "execstart-malformed")
path_fields = [
    field.strip().removeprefix("{").strip()
    for field in exec_start.split(" ; ")
    if field.strip().removeprefix("{").strip().startswith("path=")
]
if path_fields != [f"path={expected_argv[0]}"]:
    result("unknown", "execstart-path-drift")
argv_text = exec_start.split("argv[]=", 1)[1].split(" ; ", 1)[0].strip()
try:
    argv = shlex.split(argv_text)
except ValueError:
    result("unknown", "execstart-argv-malformed")
if argv != expected_argv:
    result("unknown", "execstart-argv-drift")
active_state = properties["ActiveState"]
if active_state in {"active", "activating", "reloading", "deactivating"}:
    result("active", f"active-state-{active_state}")
if active_state == "inactive":
    if main_pid != "0":
        result("unknown", "inactive-main-pid")
    result("inactive", "exact-inactive")
result("unknown", f"active-state-{active_state}")
