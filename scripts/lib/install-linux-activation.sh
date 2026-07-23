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

public_codex_release_identity() {
  python3 - \
    "$CURRENT_LINK/release-manifest.tsv" \
    "$CURRENT_LINK/patched-codex/codex" \
    "$CURRENT_LINK/patched-codex/codex-code-mode-host" \
    "$STATE_FILE_MAX_BYTES" <<'PY'
import hashlib
import os
import stat
import sys

manifest_path, codex_path, helper_path, limit_text = sys.argv[1:]
limit = int(limit_text)


def identity(metadata):
    return ":".join(
        str(value)
        for value in (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            metadata.st_uid,
            metadata.st_mode,
        )
    )


def open_owned_regular(path, *, executable=False):
    before = os.lstat(path)
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or (executable and not before.st_mode & 0o111)
    ):
        raise SystemExit(1)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    opened = os.fstat(descriptor)
    if identity(opened) != identity(before):
        os.close(descriptor)
        raise SystemExit(1)
    return descriptor, opened


manifest_descriptor, manifest_metadata = open_owned_regular(manifest_path)
try:
    if manifest_metadata.st_size > limit:
        raise SystemExit(1)
    digest = hashlib.sha256()
    remaining = limit + 1
    while remaining:
        chunk = os.read(manifest_descriptor, min(1024 * 1024, remaining))
        if not chunk:
            break
        digest.update(chunk)
        remaining -= len(chunk)
    if remaining == 0 or identity(os.fstat(manifest_descriptor)) != identity(manifest_metadata):
        raise SystemExit(1)
finally:
    os.close(manifest_descriptor)

runtime_identities = []
for path in (codex_path, helper_path):
    descriptor, metadata = open_owned_regular(path, executable=True)
    try:
        runtime_identities.append(identity(metadata))
    finally:
        os.close(descriptor)

print("\t".join((digest.hexdigest(), *runtime_identities)))
PY
}

public_codex_launcher_contents() {
  local quoted_current=""
  local quoted_lock=""
  local quoted_public_launcher=""
  local quoted_manifest_sha256=""
  local quoted_codex_identity=""
  local quoted_helper_identity=""
  local release_identity="${1:-}"
  local manifest_sha256=""
  local codex_identity=""
  local helper_identity=""

  if [[ -z "$release_identity" ]]; then
    release_identity="$(public_codex_release_identity)" || return 1
  fi
  IFS=$'\t' read -r manifest_sha256 codex_identity helper_identity <<< "$release_identity"
  [[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ && -n "$codex_identity" && -n "$helper_identity" ]] || return 1
  printf -v quoted_current '%q' "$CURRENT_LINK"
  printf -v quoted_lock '%q' "$RUNTIME_START_INSTALL_GUARD"
  printf -v quoted_public_launcher '%q' "$BIN_DIR/codex"
  printf -v quoted_manifest_sha256 '%q' "$manifest_sha256"
  printf -v quoted_codex_identity '%q' "$codex_identity"
  printf -v quoted_helper_identity '%q' "$helper_identity"
  cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
CODEXSWITCH_LAUNCHER_FORMAT=codexswitch-current-launcher-v1
CURRENT_ROOT=$quoted_current
RUNTIME_INSTALL_LOCK=$quoted_lock
PUBLIC_LAUNCHER=$quoted_public_launcher
EXPECTED_MANIFEST_SHA256=$quoted_manifest_sha256
EXPECTED_CODEX_IDENTITY=$quoted_codex_identity
EXPECTED_HELPER_IDENTITY=$quoted_helper_identity
INSTALL_ROOT="\${CURRENT_ROOT%/current}"
PATCHED_CODEX="\$CURRENT_ROOT/patched-codex/codex"
PATCHED_HELPER="\$CURRENT_ROOT/patched-codex/codex-code-mode-host"

exec 9>>"\$RUNTIME_INSTALL_LOCK"
/usr/bin/flock --shared 9

ACTIVE_LAUNCHER_GENERATION="\$(/usr/bin/python3 - "\$PUBLIC_LAUNCHER" <<'PY'
import os
import re
import stat
import sys

path = sys.argv[1]
try:
    before = os.lstat(path)
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_size > 65536
    ):
        raise SystemExit(1)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino, opened.st_size) != (
            before.st_dev,
            before.st_ino,
            before.st_size,
        ):
            raise SystemExit(1)
        data = os.read(descriptor, 65537)
        if len(data) > 65536 or os.read(descriptor, 1):
            raise SystemExit(1)
    finally:
        os.close(descriptor)
    matches = re.findall(
        rb"^EXPECTED_MANIFEST_SHA256=([0-9a-f]{64})$",
        data,
        re.MULTILINE,
    )
    if len(matches) != 1:
        raise SystemExit(1)
    print(matches[0].decode("ascii"))
except OSError:
    raise SystemExit(1)
PY
)" || {
  echo "codex: active CodexSwitch launcher could not be verified" >&2
  exit 1
}
if [[ "\$ACTIVE_LAUNCHER_GENERATION" != "\$EXPECTED_MANIFEST_SHA256" ]]; then
  exec "\$PUBLIC_LAUNCHER" "\$@"
fi

CURRENT_TARGET="\$(readlink "\$CURRENT_ROOT")"
case "\$CURRENT_TARGET" in
  releases/*)
    RELEASE_ID="\${CURRENT_TARGET#releases/}"
    ;;
  "\$INSTALL_ROOT"/releases/*)
    RELEASE_ID="\${CURRENT_TARGET#"\$INSTALL_ROOT/releases/"}"
    ;;
  *)
    echo "codex: current CodexSwitch release pointer is invalid" >&2
    exit 1
    ;;
esac
if [[ -z "\$RELEASE_ID" || "\$RELEASE_ID" == */* || "\$RELEASE_ID" == *..* ]]; then
  echo "codex: current CodexSwitch release identity is invalid" >&2
  exit 1
fi
RELEASE_ROOT="\$INSTALL_ROOT/releases/\$RELEASE_ID"
RELEASE_MANIFEST="\$RELEASE_ROOT/release-manifest.tsv"
if [[ "\$(readlink -f "\$CURRENT_ROOT")" != "\$RELEASE_ROOT" ]] ||
   [[ ! -f "\$RELEASE_MANIFEST" || -L "\$RELEASE_MANIFEST" ]] ||
   ! grep -Fxq \$'format\tcodexswitch-release-v3' "\$RELEASE_MANIFEST" ||
   ! grep -Fxq \$'codex_marker_contract\tcodexswitch-hotswap-full-v3' "\$RELEASE_MANIFEST"; then
  echo "codex: current CodexSwitch release provenance is invalid" >&2
  exit 1
fi
if [[ ! -f "\$PATCHED_CODEX" || -L "\$PATCHED_CODEX" || ! -x "\$PATCHED_CODEX" ]] ||
   [[ ! -f "\$PATCHED_HELPER" || -L "\$PATCHED_HELPER" || ! -x "\$PATCHED_HELPER" ]]; then
  echo "codex: current CodexSwitch runtime is incomplete at \$CURRENT_ROOT" >&2
  exit 1
fi

/usr/bin/python3 - \
  "\$RELEASE_MANIFEST" \
  "\$PATCHED_CODEX" \
  "\$PATCHED_HELPER" \
  "\$EXPECTED_MANIFEST_SHA256" \
  "\$EXPECTED_CODEX_IDENTITY" \
  "\$EXPECTED_HELPER_IDENTITY" <<'PY'
import hashlib
import os
import stat
import sys

manifest_path, codex_path, helper_path, manifest_sha256, codex_identity, helper_identity = sys.argv[1:]


def identity(metadata):
    return ":".join(
        str(value)
        for value in (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            metadata.st_uid,
            metadata.st_mode,
        )
    )


def fail(message):
    raise SystemExit(f"codex: {message}")


def open_owned_regular(path, *, executable=False):
    try:
        before = os.lstat(path)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or (executable and not before.st_mode & 0o111)
        ):
            fail("current CodexSwitch release contains an invalid runtime file")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        opened = os.fstat(descriptor)
    except OSError:
        fail("current CodexSwitch release could not be verified")
    if identity(opened) != identity(before):
        os.close(descriptor)
        fail("current CodexSwitch release changed during verification")
    return descriptor, opened


manifest_descriptor, manifest_metadata = open_owned_regular(manifest_path)
try:
    if manifest_metadata.st_size > 1024 * 1024:
        fail("current CodexSwitch release manifest exceeds its size bound")
    digest = hashlib.sha256()
    remaining = 1024 * 1024 + 1
    while remaining:
        chunk = os.read(manifest_descriptor, min(1024 * 1024, remaining))
        if not chunk:
            break
        digest.update(chunk)
        remaining -= len(chunk)
    if remaining == 0 or identity(os.fstat(manifest_descriptor)) != identity(manifest_metadata):
        fail("current CodexSwitch release manifest changed during verification")
    if digest.hexdigest() != manifest_sha256:
        fail("current CodexSwitch release manifest does not match the activated release")
finally:
    os.close(manifest_descriptor)

for path, expected in ((codex_path, codex_identity), (helper_path, helper_identity)):
    descriptor, metadata = open_owned_regular(path, executable=True)
    try:
        if identity(metadata) != expected:
            fail("current CodexSwitch runtime does not match the activated release")
    finally:
        os.close(descriptor)
PY

exec "\$PATCHED_CODEX" "\$@"
EOF
}

public_codex_launcher_metadata() {
  python3 - "$1" <<'PY'
import os
import stat
import sys
from pathlib import Path

metadata = Path(sys.argv[1]).lstat()
if (
    stat.S_ISLNK(metadata.st_mode)
    or not stat.S_ISREG(metadata.st_mode)
    or metadata.st_uid != os.geteuid()
):
    raise SystemExit(1)
print(f"{metadata.st_size}\t{stat.S_IMODE(metadata.st_mode):o}")
PY
}

public_codex_launcher_is_current() {
  local public_codex="$BIN_DIR/codex"
  local expected=""
  local metadata=""
  local mode=""
  local size=""

  [[ -f "$public_codex" && ! -L "$public_codex" && -O "$public_codex" && -x "$public_codex" ]] || return 1
  metadata="$(public_codex_launcher_metadata "$public_codex")" || return 1
  IFS=$'\t' read -r size mode <<< "$metadata"
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 65536 ]] || return 1
  [[ "$mode" == "555" ]] || return 1
  expected="$(public_codex_launcher_contents)" || return 1
  [[ "$(cat "$public_codex")" == "$expected" ]]
}

generated_public_codex_launcher_is_managed() {
  local public_codex="$BIN_DIR/codex"
  local expected=""
  local metadata=""
  local mode=""
  local size=""

  [[ -f "$public_codex" && ! -L "$public_codex" && -O "$public_codex" && -x "$public_codex" ]] || return 1
  metadata="$(public_codex_launcher_metadata "$public_codex")" || return 1
  IFS=$'\t' read -r size mode <<< "$metadata"
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 65536 ]] || return 1
  [[ "$mode" == "555" ]] || return 1
  expected="$(public_codex_launcher_contents)" || return 1
  python3 - "$public_codex" "$expected" <<'PY'
import re
import sys

path, expected = sys.argv[1:]
dynamic = {
    "EXPECTED_MANIFEST_SHA256": re.compile(r"[0-9a-f]{64}"),
    "EXPECTED_CODEX_IDENTITY": re.compile(r"[0-9]+(?::[0-9]+){6}"),
    "EXPECTED_HELPER_IDENTITY": re.compile(r"[0-9]+(?::[0-9]+){6}"),
}


def normalize(source):
    counts = {key: 0 for key in dynamic}
    normalized = []
    for line in source.splitlines():
        key, separator, value = line.partition("=")
        if key in dynamic:
            if separator != "=" or not dynamic[key].fullmatch(value):
                raise SystemExit(1)
            counts[key] += 1
            line = f"{key}=<activated-release>"
        normalized.append(line)
    if any(count != 1 for count in counts.values()):
        raise SystemExit(1)
    return normalized


with open(path, encoding="utf-8") as source:
    installed = source.read()
if installed.splitlines().count(
    "CODEXSWITCH_LAUNCHER_FORMAT=codexswitch-current-launcher-v1"
) != 1:
    raise SystemExit(1)
raise SystemExit(0 if normalize(installed) == normalize(expected) else 1)
PY
}

legacy_public_codex_launcher_is_managed() {
  local public_codex="$BIN_DIR/codex"
  local metadata=""
  local mode=""
  local target=""
  local size=""

  if [[ -L "$public_codex" ]]; then
    target="$(readlink "$public_codex")"
    [[ "$target" == "$INSTALL_ROOT/patched-codex/codex" ||
       "$target" == "$CURRENT_LINK/patched-codex/codex" ||
       "$target" == "$CURRENT_LINK/codex" ]]
    return
  fi
  [[ -f "$public_codex" && -O "$public_codex" && -x "$public_codex" ]] || return 1
  metadata="$(public_codex_launcher_metadata "$public_codex")" || return 1
  IFS=$'\t' read -r size mode <<< "$metadata"
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 65536 ]] || return 1
  python3 - \
    "$public_codex" \
    "$INSTALL_ROOT/patched-codex/codex" \
    "$CURRENT_LINK/patched-codex/codex" <<'PY'
import sys

path, legacy_target, current_target = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    lines = [line.strip() for line in source]

assignments = {
    f"PATCHED_CODEX='{legacy_target}'",
    f'PATCHED_CODEX="{legacy_target}"',
    f"PATCHED_CODEX='{current_target}'",
    f'PATCHED_CODEX="{current_target}"',
}
raise SystemExit(
    0
    if lines[:1] == ["#!/usr/bin/env bash"]
    and sum(line in assignments for line in lines) == 1
    and lines.count('exec "$PATCHED_CODEX" "$@"') == 1
    and sum("run codexswitch-cli install-prepared-codex" in line for line in lines) == 1
    else 1
)
PY
}

validate_public_codex_launcher_pre_activation() {
  local public_codex="$BIN_DIR/codex"

  PUBLIC_CODEX_LAUNCHER_PREVALIDATED=0
  if [[ ! -e "$public_codex" && ! -L "$public_codex" ]]; then
    PUBLIC_CODEX_LAUNCHER_PREVALIDATED=1
    return
  fi
  if public_codex_launcher_is_current ||
     generated_public_codex_launcher_is_managed ||
     legacy_public_codex_launcher_is_managed; then
    PUBLIC_CODEX_LAUNCHER_PREVALIDATED=1
    return
  fi
  fail "public Codex launcher is not a recognized CodexSwitch route: $public_codex"
}

install_public_codex_launcher() {
  local public_codex="$BIN_DIR/codex"
  local temporary="$BIN_DIR/.codex.tmp.$$"
  local release_identity=""
  local verified_identity=""

  [[ "$PUBLIC_CODEX_LAUNCHER_PREVALIDATED" == "1" ]] ||
    fail "public Codex launcher publication lacks its pre-activation validation"
  public_codex_launcher_is_current && return
  [[ ! -e "$temporary" && ! -L "$temporary" ]] || fail "public Codex launcher staging path already exists: $temporary"
  release_identity="$(public_codex_release_identity)" ||
    fail "failed to snapshot the activated Codex runtime"
  if ! public_codex_launcher_contents "$release_identity" > "$temporary"; then
    rm -f -- "$temporary"
    fail "failed to generate the public Codex launcher"
  fi
  if ! (validate_release "$(canonicalize_path "$CURRENT_LINK")"); then
    rm -f -- "$temporary"
    fail "activated Codex runtime failed launcher publication validation"
  fi
  verified_identity="$(public_codex_release_identity)" || {
    rm -f -- "$temporary"
    fail "failed to verify the activated Codex runtime identity"
  }
  if [[ "$verified_identity" != "$release_identity" ]]; then
    rm -f -- "$temporary"
    fail "activated Codex runtime changed during launcher publication"
  fi
  chmod 0555 "$temporary"
  python3 - "$temporary" <<'PY' || fail "failed to persist the public Codex launcher"
import os
import sys

descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
  mv -Tf -- "$temporary" "$public_codex"
  fsync_directory "$BIN_DIR"
  public_codex_launcher_is_current || fail "public Codex launcher readback failed: $public_codex"
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
  validate_public_codex_launcher_pre_activation
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
  inject_fault after_commit_before_codex_launcher
  install_public_codex_launcher
  remove_activation_journal
  ACTIVATION_TRANSACTION_ACTIVE=0
  release_runtime_guards
  public_codex_launcher_is_current || fail "public Codex launcher does not follow the current release"
}
