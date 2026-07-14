#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 "usage: $0 <macos-app-artifact-directory>"
  exit 64
}

[[ $# -eq 1 ]] || usage
[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || {
  print -u2 "this installer is only for macOS"
  exit 1
}

download_dir="${1:a}"
repo_root="${0:A:h:h}"
trusted_repository="brendondelgado/CodexSwitch"
trusted_workflow="brendondelgado/CodexSwitch/.github/workflows/build-macos-app.yml"
install_path="/Applications/CodexSwitch.app"

[[ -d "$download_dir" && ! -L "$download_dir" ]] || {
  print -u2 "artifact must be a regular directory, not a symlink: $download_dir"
  exit 1
}

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codexswitch-macos-app-install.XXXXXX")"
work_dir="${work_dir:A}"
artifact_dir="$work_dir/artifact"
snapshot_report="$work_dir/snapshot-report.json"
manifest_values="$work_dir/manifest-values"
extract_dir="$work_dir/extracted"
install_workdir=""
staged_path=""
failed_path=""
had_previous=0
swapped=0
activated=0
preserve_install_workdir=0
was_running=0
quit_completed=0
previous_relaunched=0

atomic_swap_paths() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import ctypes
import os
import sys

AT_FDCWD = -2
RENAME_SWAP = 0x00000002
libc = ctypes.CDLL(None, use_errno=True)
renameatx_np = libc.renameatx_np
renameatx_np.argtypes = [
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_uint,
]
renameatx_np.restype = ctypes.c_int

left = os.fsencode(sys.argv[1])
right = os.fsencode(sys.argv[2])
if renameatx_np(AT_FDCWD, left, AT_FDCWD, right, RENAME_SWAP) != 0:
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), f"{sys.argv[1]} <-> {sys.argv[2]}")
PY
}

rollback_activation() {
  [[ "$swapped" == "1" ]] || return 0
  if [[ "$had_previous" == "1" ]]; then
    if ! atomic_swap_paths "$install_path" "$staged_path"; then
      preserve_install_workdir=1
      print -u2 "Critical: automatic rollback failed; recovery bundle is $staged_path"
      return 1
    fi
    /usr/bin/open "$install_path" >/dev/null 2>&1 || true
    previous_relaunched=1
  else
    if ! /bin/mv "$install_path" "$failed_path"; then
      preserve_install_workdir=1
      print -u2 "Critical: failed first-install rollback; recovery is required at $install_path"
      return 1
    fi
  fi
  swapped=0
}

cleanup() {
  local status=$?
  if [[ "$activated" != "1" && "$swapped" == "1" ]]; then
    rollback_activation || true
  fi
  if [[ "$activated" != "1" && "$swapped" != "1" && "$quit_completed" == "1" \
    && "$had_previous" == "1" && "$was_running" == "1" \
    && "$previous_relaunched" != "1" ]]; then
    /usr/bin/open "$install_path" >/dev/null 2>&1 || true
  fi
  if [[ -n "$install_workdir" && "$preserve_install_workdir" != "1" ]]; then
    /bin/chmod -R u+w "$install_workdir" 2>/dev/null || true
    /bin/rm -rf -- "$install_workdir"
  fi
  /bin/chmod -R u+w "$work_dir" 2>/dev/null || true
  /bin/rm -rf -- "$work_dir"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

/usr/bin/python3 - "$download_dir" "$artifact_dir" > "$snapshot_report" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
expected = {
    "CodexSwitch.app.zip": 536_870_912,
    "manifest.json": 65_536,
}

source_stat = os.lstat(source)
if not stat.S_ISDIR(source_stat.st_mode) or stat.S_ISLNK(source_stat.st_mode):
    raise SystemExit("artifact source is not a regular directory")
actual = os.listdir(source)
if len(actual) != len(expected) or set(actual) != set(expected):
    raise SystemExit("app artifact directory must contain exactly CodexSwitch.app.zip and manifest.json")

os.mkdir(destination, 0o700)
report = {"members": {}}
for name, maximum in expected.items():
    source_path = source / name
    before = os.lstat(source_path)
    if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
        raise SystemExit(f"artifact member is linked or special: {name}")
    if before.st_size <= 0 or before.st_size > maximum:
        raise SystemExit(f"artifact member is outside its size bound: {name}")

    source_fd = os.open(source_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    destination_path = destination / name
    destination_fd = os.open(
        destination_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
    )
    digest = hashlib.sha256()
    copied = 0
    try:
        opened = os.fstat(source_fd)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise SystemExit(f"artifact member changed while opening: {name}")
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            copied += len(chunk)
            if copied > maximum:
                raise SystemExit(f"artifact member exceeded its size bound while copying: {name}")
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                view = view[written:]
        os.fsync(destination_fd)
        after = os.fstat(source_fd)
        stable = (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
        ) == (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
        )
        if not stable or copied != before.st_size:
            raise SystemExit(f"artifact member changed while copying: {name}")
    finally:
        os.close(source_fd)
        os.close(destination_fd)

    os.chmod(destination_path, 0o400)
    report["members"][name] = {"bytes": copied, "sha256": digest.hexdigest()}

os.chmod(destination, 0o500)
print(json.dumps(report, sort_keys=True, separators=(",", ":")))
PY

verify_frozen_snapshot() {
  local observed_report="$work_dir/observed-snapshot-report.json"
  /usr/bin/python3 - "$artifact_dir" > "$observed_report" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

directory = pathlib.Path(sys.argv[1])
expected = {"CodexSwitch.app.zip": 536_870_912, "manifest.json": 65_536}
actual = os.listdir(directory)
if len(actual) != len(expected) or set(actual) != set(expected):
    raise SystemExit("private app artifact snapshot has unexpected members")
report = {"members": {}}
for name, maximum in expected.items():
    path = directory / name
    metadata = os.lstat(path)
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(f"private snapshot member is linked or special: {name}")
    if metadata.st_size <= 0 or metadata.st_size > maximum:
        raise SystemExit(f"private snapshot member is outside its size bound: {name}")
    digest = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        os.close(descriptor)
    report["members"][name] = {
        "bytes": metadata.st_size,
        "sha256": digest.hexdigest(),
    }
print(json.dumps(report, sort_keys=True, separators=(",", ":")))
PY
  /usr/bin/cmp -s "$snapshot_report" "$observed_report" || {
    print -u2 "private app artifact snapshot changed after trust verification"
    exit 1
  }
}

/usr/bin/python3 - \
  "$artifact_dir/manifest.json" \
  "$artifact_dir/CodexSwitch.app.zip" > "$manifest_values" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
archive_path = pathlib.Path(sys.argv[2])

def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate manifest key: {key}")
        result[key] = value
    return result

try:
    manifest = json.loads(manifest_path.read_bytes(), object_pairs_hook=strict_object)
except (OSError, UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid app artifact manifest: {error}")

expected_keys = {
    "format",
    "codexSwitchGitSha",
    "appVersion",
    "buildEpoch",
    "bundleIdentifier",
    "bundleName",
    "architecture",
    "signing",
    "archive",
    "bundleFiles",
}
if type(manifest) is not dict or set(manifest) != expected_keys:
    raise SystemExit("app artifact manifest has an unexpected schema")
if manifest["format"] != "codexswitch-macos-app-artifact-v1":
    raise SystemExit("app artifact manifest has an unknown format")
source_sha = manifest["codexSwitchGitSha"]
if type(source_sha) is not str or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
    raise SystemExit("app artifact manifest has an invalid source SHA")
app_version = manifest["appVersion"]
if type(app_version) is not str or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", app_version):
    raise SystemExit("app artifact manifest has an invalid app version")
build_epoch = manifest["buildEpoch"]
if type(build_epoch) is not int or build_epoch <= 0:
    raise SystemExit("app artifact manifest has an invalid build epoch")
for key, expected in {
    "bundleIdentifier": "com.codexswitch",
    "bundleName": "CodexSwitch.app",
    "architecture": "arm64",
    "signing": "adhoc",
}.items():
    if manifest[key] != expected:
        raise SystemExit(f"app artifact manifest has an invalid {key}")

archive = manifest["archive"]
if type(archive) is not dict or set(archive) != {"name", "bytes", "sha256"}:
    raise SystemExit("app archive manifest entry has an unexpected schema")
if archive["name"] != "CodexSwitch.app.zip":
    raise SystemExit("app archive manifest entry has an unexpected name")
if type(archive["bytes"]) is not int or not 0 < archive["bytes"] <= 536_870_912:
    raise SystemExit("app archive manifest entry has an invalid size")
if type(archive["sha256"]) is not str or not re.fullmatch(r"[0-9a-f]{64}", archive["sha256"]):
    raise SystemExit("app archive manifest entry has an invalid SHA-256")
archive_digest = hashlib.sha256()
archive_length = 0
with archive_path.open("rb") as handle:
    while chunk := handle.read(1024 * 1024):
        archive_length += len(chunk)
        archive_digest.update(chunk)
if archive_length != archive["bytes"] or archive_digest.hexdigest() != archive["sha256"]:
    raise SystemExit("app archive identity does not match its manifest")

bundle_files = manifest["bundleFiles"]
expected_paths = [
    ("Contents/MacOS/CodexSwitch", 268_435_456),
    ("Contents/Resources/patch-asar.py", 4_194_304),
]
if type(bundle_files) is not list or len(bundle_files) != len(expected_paths):
    raise SystemExit("app bundle file manifest has an unexpected schema")
for entry, (expected_path, maximum) in zip(bundle_files, expected_paths):
    if type(entry) is not dict or set(entry) != {"path", "bytes", "sha256"}:
        raise SystemExit("app bundle file manifest entry has an unexpected schema")
    if entry["path"] != expected_path:
        raise SystemExit("app bundle file manifest entry has an unexpected path")
    if type(entry["bytes"]) is not int or not 0 < entry["bytes"] <= maximum:
        raise SystemExit(f"app bundle file manifest entry has an invalid size: {expected_path}")
    if type(entry["sha256"]) is not str or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
        raise SystemExit(f"app bundle file manifest entry has an invalid SHA-256: {expected_path}")

print(source_sha)
print(app_version)
print(build_epoch)
print(bundle_files[0]["bytes"])
print(bundle_files[0]["sha256"])
print(bundle_files[1]["bytes"])
print(bundle_files[1]["sha256"])
PY

manifest_lines=()
while IFS= read -r line; do
  manifest_lines+=("$line")
done < "$manifest_values"
[[ ${#manifest_lines[@]} -eq 7 ]] || {
  print -u2 "app manifest verifier returned an invalid result"
  exit 1
}
source_sha="${manifest_lines[1]}"
app_version="${manifest_lines[2]}"
build_epoch="${manifest_lines[3]}"
expected_executable_bytes="${manifest_lines[4]}"
expected_executable_sha256="${manifest_lines[5]}"
expected_patcher_bytes="${manifest_lines[6]}"
expected_patcher_sha256="${manifest_lines[7]}"

[[ "$(/usr/bin/git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] || {
  print -u2 "installer is not running from the canonical CodexSwitch repository"
  exit 1
}
[[ "$(/usr/bin/git -C "$repo_root" branch --show-current)" == "main" ]] || {
  print -u2 "app activation requires the local main branch"
  exit 1
}
[[ "$(/usr/bin/git -C "$repo_root" rev-parse HEAD)" == "$source_sha" ]] || {
  print -u2 "app artifact commit does not match the reviewed local checkout"
  exit 1
}
[[ -z "$(/usr/bin/git -C "$repo_root" status --porcelain --untracked-files=normal)" ]] || {
  print -u2 "app activation requires a clean local checkout"
  exit 1
}

gh_binary="$(command -v gh)" || {
  print -u2 "GitHub CLI is required to verify app artifact attestations"
  exit 1
}
for name in CodexSwitch.app.zip manifest.json; do
  "$gh_binary" attestation verify "$artifact_dir/$name" \
    --repo "$trusted_repository" \
    --signer-workflow "$trusted_workflow" \
    --signer-digest "$source_sha" \
    --source-ref refs/heads/main \
    --source-digest "$source_sha" \
    --deny-self-hosted-runners >/dev/null
done
verify_frozen_snapshot

/usr/bin/python3 - "$artifact_dir/CodexSwitch.app.zip" <<'PY'
import pathlib
import stat
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(archive) as handle:
    entries = handle.infolist()
    if not entries or len(entries) > 4096:
        raise SystemExit("app archive has an invalid entry count")
    seen = set()
    total = 0
    for entry in entries:
        name = entry.filename
        if not name or "\\" in name or name.startswith("/"):
            raise SystemExit(f"unsafe app archive path: {name!r}")
        raw_name = name[:-1] if name.endswith("/") else name
        raw_parts = raw_name.split("/")
        if "\x00" in name or any(part in ("", ".", "..") for part in raw_parts):
            raise SystemExit(f"unsafe app archive component: {name}")
        path = pathlib.PurePosixPath(raw_name)
        if not path.parts or path.parts[0] != "CodexSwitch.app":
            raise SystemExit(f"unexpected app archive root: {name}")
        normalized = path.as_posix()
        if normalized in seen:
            raise SystemExit(f"duplicate app archive path: {normalized}")
        seen.add(normalized)
        if entry.flag_bits & 0x1:
            raise SystemExit(f"encrypted app archive entry: {name}")
        mode = (entry.external_attr >> 16) & 0xFFFF
        kind = stat.S_IFMT(mode)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise SystemExit(f"linked or special app archive entry: {name}")
        if entry.file_size > 536_870_912:
            raise SystemExit(f"oversized app archive entry: {name}")
        total += entry.file_size
        if total > 1_073_741_824:
            raise SystemExit("app archive expands beyond 1 GiB")
    required = {
        "CodexSwitch.app/Contents/Info.plist",
        "CodexSwitch.app/Contents/MacOS/CodexSwitch",
        "CodexSwitch.app/Contents/Resources/patch-asar.py",
    }
    if not required.issubset(seen):
        raise SystemExit("app archive is missing a required bundle member")
PY

/bin/mkdir -m 0700 "$extract_dir"
/usr/bin/ditto \
  -x -k \
  --norsrc --noextattr --noqtn --noacl --nopersistRootless \
  "$artifact_dir/CodexSwitch.app.zip" "$extract_dir"
top_level="$work_dir/extracted-top-level"
/usr/bin/find "$extract_dir" -mindepth 1 -maxdepth 1 -exec /usr/bin/basename {} \; \
  | LC_ALL=C /usr/bin/sort > "$top_level"
printf '%s\n' CodexSwitch.app | /usr/bin/diff -u - "$top_level"

file_bytes() {
  /usr/bin/stat -f '%z' "$1"
}
file_sha256() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}
verify_bundle() {
  local bundle="$1"
  local executable="$bundle/Contents/MacOS/CodexSwitch"
  local patcher="$bundle/Contents/Resources/patch-asar.py"
  local linked special signature

  [[ -d "$bundle" && ! -L "$bundle" ]] || {
    print -u2 "app bundle is missing or linked: $bundle"
    return 1
  }
  linked="$(/usr/bin/find "$bundle" -type l -print -quit)"
  [[ -z "$linked" ]] || {
    print -u2 "app bundle contains a symlink: $linked"
    return 1
  }
  special="$(/usr/bin/find "$bundle" -mindepth 1 ! -type f ! -type d -print -quit)"
  [[ -z "$special" ]] || {
    print -u2 "app bundle contains a special file: $special"
    return 1
  }
  [[ -f "$executable" && ! -L "$executable" && -x "$executable" && -s "$executable" ]] || {
    print -u2 "app executable is missing, linked, or not executable"
    return 1
  }
  [[ -f "$patcher" && ! -L "$patcher" && -s "$patcher" ]] || {
    print -u2 "bundled patch-asar.py is missing or linked"
    return 1
  }
  [[ -f "$repo_root/scripts/patch-asar.py" && ! -L "$repo_root/scripts/patch-asar.py" ]] || {
    print -u2 "reviewed source patch-asar.py is missing or linked"
    return 1
  }
  [[ "$(file_bytes "$executable")" == "$expected_executable_bytes" ]] || {
    print -u2 "app executable length does not match the manifest"
    return 1
  }
  [[ "$(file_sha256 "$executable")" == "$expected_executable_sha256" ]] || {
    print -u2 "app executable hash does not match the manifest"
    return 1
  }
  [[ "$(file_bytes "$patcher")" == "$expected_patcher_bytes" ]] || {
    print -u2 "bundled patch-asar.py length does not match the manifest"
    return 1
  }
  [[ "$(file_sha256 "$patcher")" == "$expected_patcher_sha256" ]] || {
    print -u2 "bundled patch-asar.py hash does not match the manifest"
    return 1
  }

  [[ "$(plist_value "$bundle" CFBundleSourceRevision)" == "$source_sha" ]] || {
    print -u2 "app plist has the wrong source revision"
    return 1
  }
  [[ "$(plist_value "$bundle" CFBundleVersion)" == "$build_epoch" ]] || {
    print -u2 "app plist has the wrong build number"
    return 1
  }
  [[ "$(plist_value "$bundle" CFBundleShortVersionString)" == "$app_version" ]] || {
    print -u2 "app plist has the wrong version"
    return 1
  }
  [[ "$(plist_value "$bundle" CFBundleIdentifier)" == "com.codexswitch" ]] || {
    print -u2 "app plist has the wrong bundle identifier"
    return 1
  }
  [[ "$(plist_value "$bundle" CFBundleExecutable)" == "CodexSwitch" ]] || {
    print -u2 "app plist has the wrong executable name"
    return 1
  }

  [[ "$(/usr/bin/lipo -archs "$executable")" == "arm64" ]] || {
    print -u2 "app executable is not thin arm64"
    return 1
  }
  /usr/bin/file -b "$executable" | /usr/bin/grep -Fq "Mach-O 64-bit executable arm64" || {
    print -u2 "app executable has the wrong Mach-O shape"
    return 1
  }
  /usr/bin/codesign --verify --deep --strict --verbose=4 "$bundle" || return 1
  signature="$(/usr/bin/codesign --display --verbose=4 "$bundle" 2>&1)"
  /usr/bin/grep -Fxq "Signature=adhoc" <<< "$signature" || {
    print -u2 "app bundle is not explicitly ad-hoc signed"
    return 1
  }
  /usr/bin/cmp -s "$repo_root/scripts/patch-asar.py" "$patcher" || {
    print -u2 "bundled patch-asar.py differs from the reviewed source"
    return 1
  }
  if /usr/bin/strings "$executable" \
    | /usr/bin/grep -E 'LINUX_DEVBOX_ACTIVE_PUSH|pendingLinuxDevboxActive|pushLinuxDevboxActiveAccount' >/dev/null; then
    print -u2 "app executable still contains removed VPS active-push code"
    return 1
  fi
}

validated_bundle="$extract_dir/CodexSwitch.app"
verify_bundle "$validated_bundle"
verify_frozen_snapshot

[[ ! -L "$install_path" ]] || {
  print -u2 "refusing to replace symlinked install path $install_path"
  exit 1
}
[[ ! -e "$install_path" || -d "$install_path" ]] || {
  print -u2 "refusing to replace non-directory install path $install_path"
  exit 1
}
if [[ -e "$install_path" ]]; then
  had_previous=1
fi

install_workdir="$(/usr/bin/mktemp -d /Applications/.codexswitch-app-install.XXXXXX)" || {
  print -u2 "cannot create a staging directory in /Applications; installed app was not changed"
  exit 1
}
install_workdir="${install_workdir:A}"
staged_path="$install_workdir/CodexSwitch.app"
failed_path="$install_workdir/CodexSwitch.failed.app"
/usr/bin/ditto \
  --norsrc --noextattr --noqtn --noacl --nopersistRootless \
  "$validated_bundle" "$staged_path"
verify_bundle "$staged_path"
verify_frozen_snapshot

if /usr/bin/pgrep -f "$install_path/Contents/MacOS/CodexSwitch" >/dev/null 2>&1; then
  was_running=1
fi
/bin/launchctl bootout "gui/$(/usr/bin/id -u)/com.codexswitch.watchdog" >/dev/null 2>&1 || true
/usr/bin/osascript -e 'tell application "CodexSwitch" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! /usr/bin/pgrep -f "$install_path/Contents/MacOS/CodexSwitch" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.25
done
if /usr/bin/pgrep -f "$install_path/Contents/MacOS/CodexSwitch" >/dev/null 2>&1; then
  print -u2 "CodexSwitch is still running; refusing to replace its installed bundle"
  exit 1
fi
quit_completed=1

swap_error=0
trap '' INT TERM HUP
if [[ "$had_previous" == "1" ]]; then
  atomic_swap_paths "$staged_path" "$install_path" || swap_error=$?
else
  /bin/mv "$staged_path" "$install_path" || swap_error=$?
fi
if [[ "$swap_error" == "0" ]]; then
  swapped=1
fi
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
if [[ "$swap_error" != "0" ]]; then
  print -u2 "failed to activate staged app; installed app was not changed"
  exit 1
fi

if ! verify_bundle "$install_path"; then
  rollback_activation || exit 1
  print -u2 "installed verification failed; previous app was restored"
  exit 1
fi
if ! /usr/bin/open "$install_path"; then
  rollback_activation || exit 1
  print -u2 "replacement app did not launch; previous app was restored"
  exit 1
fi
for _ in {1..20}; do
  if /usr/bin/pgrep -f "$install_path/Contents/MacOS/CodexSwitch" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.25
done
if ! /usr/bin/pgrep -f "$install_path/Contents/MacOS/CodexSwitch" >/dev/null 2>&1; then
  rollback_activation || exit 1
  print -u2 "replacement app exited during launch; previous app was restored"
  exit 1
fi

activated=1
trap - EXIT INT TERM HUP
/bin/chmod -R u+w "$install_workdir" "$work_dir" 2>/dev/null || true
/bin/rm -rf -- "$install_workdir" "$work_dir"
print "Installed and relaunched the attested CodexSwitch app artifact."
