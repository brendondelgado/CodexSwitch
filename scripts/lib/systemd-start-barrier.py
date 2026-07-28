#!/usr/bin/env python3
"""Own and recover transaction-scoped systemd start barriers."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any


FORMAT = "codexswitch-systemd-start-barriers-v2"
LOCK_FORMAT = "codexswitch-activation-lock-v1"
MANIFEST_NAME = "manifest.json"
NEXT_MANIFEST_NAME = "manifest.next"
BARRIER_NAME = "00-codexswitch-activation-guard.conf"
UNIT_PATTERN = re.compile(
    r"[A-Za-z0-9_.@-]+\.(?:service|socket|path|timer)"
)
TOKEN_PATTERN = re.compile(r"[0-9a-f]{32}")
START_PATTERN = re.compile(r"(?:UNKNOWN|[0-9]+)")


def fail(message: str) -> None:
    raise SystemExit(message)


def lexists(path: Path) -> bool:
    return os.path.lexists(path)


def fsync_directory(path: Path) -> None:
    descriptor = os.open(
        path, os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    )
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def require_canonical_absolute(path: Path, label: str) -> None:
    if not path.is_absolute() or Path(os.path.realpath(path)) != path:
        fail(f"{label} is not canonical: {path}")


def ensure_directory(path: Path) -> tuple[bool, os.stat_result]:
    created = False
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        path.mkdir(mode=0o700)
        created = True
        metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        fail(f"systemd start barrier parent is linked or special: {path}")
    if Path(os.path.realpath(path)) != path:
        fail(f"systemd start barrier parent is not canonical: {path}")
    return created, metadata


def read_regular(path: Path, limit: int) -> tuple[tuple[int, int, int, int], bytes]:
    before = path.lstat()
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        fail(f"systemd start barrier file is linked or special: {path}")
    if before.st_size <= 0 or before.st_size > limit:
        fail(f"systemd start barrier file exceeds its read bound: {path}")
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        opened = os.fstat(descriptor)
        identity = (
            opened.st_dev,
            opened.st_ino,
            opened.st_mode,
            opened.st_size,
        )
        expected = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_size,
        )
        if identity != expected:
            fail(f"systemd start barrier file changed identity: {path}")
        data = os.read(descriptor, limit + 1)
        if len(data) > limit or os.read(descriptor, 1):
            fail(f"systemd start barrier file exceeds its read bound: {path}")
    finally:
        os.close(descriptor)
    return identity, data


def parse_units(text: str) -> list[str]:
    units = [value for value in text.splitlines() if value]
    if (
        not units
        or len(units) != len(set(units))
        or any(UNIT_PATTERN.fullmatch(unit) is None for unit in units)
    ):
        fail("systemd start barrier unit list is invalid")
    return units


def parse_modes(text: str, units: list[str]) -> dict[str, str]:
    modes: dict[str, str] = {}
    for line in text.splitlines():
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            fail("systemd start barrier mode record is malformed")
        unit, kind = fields
        if unit in modes or kind not in {"condition", "mask"}:
            fail("systemd start barrier mode record is invalid")
        modes[unit] = kind
    if set(modes) != set(units):
        fail("systemd start barrier mode set is incomplete")
    return modes


def validate_owner(pid: str, start: str, token: str) -> None:
    if not pid.isdecimal() or int(pid) <= 0:
        fail("systemd start barrier owner PID is invalid")
    if START_PATTERN.fullmatch(start) is None:
        fail("systemd start barrier owner start identity is invalid")
    if TOKEN_PATTERN.fullmatch(token) is None:
        fail("systemd start barrier owner token is invalid")


def owner_directory(root: Path, token: str) -> Path:
    return root / f".codexswitch-activation-guard-{token}"


def public_path(root: Path, unit: str, kind: str) -> Path:
    if kind == "mask":
        return root / unit
    return root / f"{unit}.d" / BARRIER_NAME


def condition_content(
    lock_path: Path, pid: str, start: str, token: str, unit: str
) -> bytes:
    if any(
        character.isspace() or character in {'%', '\\', '"'}
        for character in str(lock_path)
    ):
        fail("activation lock path cannot be represented safely in a systemd condition")
    return (
        "# codexswitch-activation-start-barrier-v2\n"
        f"# owner_pid={pid}\n"
        f"# owner_start={start}\n"
        f"# owner_token={token}\n"
        f"# unit={unit}\n"
        "[Unit]\n"
        f"ConditionPathExists=!{lock_path}\n"
    ).encode("utf-8")


def anchor_identifier(unit: str, kind: str) -> str:
    return f"{kind}-{unit}"


def create_anchor(
    anchors_dir: Path,
    root: Path,
    lock_path: Path,
    pid: str,
    start: str,
    token: str,
    unit: str,
    kind: str,
) -> dict[str, Any]:
    identifier = anchor_identifier(unit, kind)
    anchor = anchors_dir / identifier
    if lexists(anchor):
        fail(f"systemd start barrier anchor already exists: {anchor}")
    if kind == "mask":
        anchor.symlink_to("/dev/null")
    else:
        descriptor = os.open(
            anchor,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | os.O_CLOEXEC
            | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(condition_content(lock_path, pid, start, token, unit))
            handle.flush()
            os.fsync(handle.fileno())
    metadata = anchor.lstat()
    if kind == "mask":
        if not stat.S_ISLNK(metadata.st_mode) or os.readlink(anchor) != "/dev/null":
            fail(f"systemd start barrier mask anchor is invalid: {anchor}")
    elif not stat.S_ISREG(metadata.st_mode):
        fail(f"systemd start barrier condition anchor is invalid: {anchor}")
    fsync_directory(anchors_dir)
    return {
        "id": identifier,
        "unit": unit,
        "kind": kind,
        "anchor": str(anchor),
        "public": str(public_path(root, unit, kind)),
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
    }


def directory_record(path: Path, metadata: os.stat_result) -> dict[str, Any]:
    return {
        "path": str(path),
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
    }


def write_manifest(owner_dir: Path, manifest: dict[str, Any], initial: bool) -> None:
    payload = (
        json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    destination = owner_dir / MANIFEST_NAME
    temporary = owner_dir / NEXT_MANIFEST_NAME
    target = destination if initial else temporary
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | os.O_CLOEXEC
        | os.O_NOFOLLOW
    )
    descriptor = os.open(target, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            target.unlink()
        except FileNotFoundError:
            pass
        raise
    if not initial:
        os.replace(temporary, destination)
    fsync_directory(owner_dir)


def manifest_template(
    root: Path,
    lock_path: Path,
    pid: str,
    start: str,
    token: str,
    units: list[str],
) -> dict[str, Any]:
    return {
        "format": FORMAT,
        "root": str(root),
        "activationLock": str(lock_path),
        "owner": {"pid": pid, "start": start, "token": token},
        "units": units,
        "phase": "publishing",
        "anchors": [],
        "active": [],
        "createdDirectories": [],
    }


def load_manifest(
    root: Path,
    lock_path: Path,
    pid: str,
    start: str,
    token: str,
    units: list[str],
    limit: int,
) -> tuple[Path, dict[str, Any]]:
    owner_dir = owner_directory(root, token)
    metadata = owner_dir.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        fail(f"systemd start barrier owner directory is unsafe: {owner_dir}")
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        fail(f"systemd start barrier owner directory mode changed: {owner_dir}")
    _identity, data = read_regular(owner_dir / MANIFEST_NAME, limit)
    try:
        manifest = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("systemd start barrier owner manifest is malformed")
    if not isinstance(manifest, dict):
        fail("systemd start barrier owner manifest is malformed")
    expected_top_level = {
        "format",
        "root",
        "activationLock",
        "owner",
        "units",
        "phase",
        "anchors",
        "active",
        "createdDirectories",
    }
    if set(manifest) != expected_top_level or manifest["format"] != FORMAT:
        fail("systemd start barrier owner manifest has an unsupported schema")
    if (
        manifest["root"] != str(root)
        or manifest["activationLock"] != str(lock_path)
        or manifest["owner"]
        != {"pid": pid, "start": start, "token": token}
        or manifest["units"] != units
        or manifest["phase"] not in {"publishing", "transitioning", "held"}
    ):
        fail("systemd start barrier owner manifest changed ownership")
    validate_manifest_records(owner_dir, root, lock_path, manifest)
    return owner_dir, manifest


def validate_manifest_records(
    owner_dir: Path,
    root: Path,
    lock_path: Path,
    manifest: dict[str, Any],
) -> None:
    owner = manifest["owner"]
    anchors = manifest["anchors"]
    active = manifest["active"]
    directories = manifest["createdDirectories"]
    if (
        not isinstance(anchors, list)
        or not isinstance(active, list)
        or not isinstance(directories, list)
    ):
        fail("systemd start barrier owner manifest records are malformed")
    by_identifier: dict[str, dict[str, Any]] = {}
    expected_anchor_dir = owner_dir / "anchors"
    for record in anchors:
        if not isinstance(record, dict) or set(record) != {
            "id",
            "unit",
            "kind",
            "anchor",
            "public",
            "device",
            "inode",
        }:
            fail("systemd start barrier anchor record is malformed")
        unit = record["unit"]
        kind = record["kind"]
        identifier = record["id"]
        if (
            unit not in manifest["units"]
            or kind not in {"condition", "mask"}
            or identifier != anchor_identifier(unit, kind)
            or identifier in by_identifier
            or record["anchor"] != str(expected_anchor_dir / identifier)
            or record["public"] != str(public_path(root, unit, kind))
            or not isinstance(record["device"], int)
            or not isinstance(record["inode"], int)
        ):
            fail("systemd start barrier anchor record changed identity")
        by_identifier[identifier] = record
        verify_anchor(
            Path(record["anchor"]),
            record,
            lock_path,
            owner["pid"],
            owner["start"],
            owner["token"],
        )
    if len(active) != len(manifest["units"]) or len(active) != len(set(active)):
        fail("systemd start barrier active set is invalid")
    if any(identifier not in by_identifier for identifier in active):
        fail("systemd start barrier active set names an unknown anchor")
    active_units = [by_identifier[identifier]["unit"] for identifier in active]
    if set(active_units) != set(manifest["units"]):
        fail("systemd start barrier active set is incomplete")
    seen_directories: set[str] = set()
    for record in directories:
        if not isinstance(record, dict) or set(record) != {
            "path",
            "device",
            "inode",
        }:
            fail("systemd start barrier directory record is malformed")
        path = Path(record["path"])
        if (
            str(path) in seen_directories
            or path.parent != root
            or not path.name.endswith(".d")
            or not isinstance(record["device"], int)
            or not isinstance(record["inode"], int)
        ):
            fail("systemd start barrier directory record is invalid")
        seen_directories.add(str(path))
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            fail(f"systemd start barrier directory is missing: {path}")
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISDIR(metadata.st_mode)
            or (metadata.st_dev, metadata.st_ino)
            != (record["device"], record["inode"])
        ):
            fail(f"systemd start barrier directory identity changed: {path}")
    validate_owner_directory_entries(owner_dir, by_identifier)


def validate_owner_directory_entries(
    owner_dir: Path, anchors: dict[str, dict[str, Any]]
) -> None:
    expected_owner_entries = {"anchors", MANIFEST_NAME}
    actual_owner_entries = {entry.name for entry in owner_dir.iterdir()}
    if NEXT_MANIFEST_NAME in actual_owner_entries:
        fail("systemd start barrier owner directory contains an incomplete manifest")
    if actual_owner_entries != expected_owner_entries:
        fail("systemd start barrier owner directory contains foreign artifacts")
    anchors_dir = owner_dir / "anchors"
    metadata = anchors_dir.lstat()
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        fail("systemd start barrier anchor directory is unsafe")
    if {entry.name for entry in anchors_dir.iterdir()} != set(anchors):
        fail("systemd start barrier anchor directory contains foreign artifacts")


def verify_anchor(
    path: Path,
    record: dict[str, Any],
    lock_path: Path,
    pid: str,
    start: str,
    token: str,
) -> None:
    metadata = path.lstat()
    if (metadata.st_dev, metadata.st_ino) != (
        record["device"],
        record["inode"],
    ):
        fail(f"systemd start barrier anchor identity changed: {path}")
    if record["kind"] == "mask":
        if not stat.S_ISLNK(metadata.st_mode) or os.readlink(path) != "/dev/null":
            fail(f"systemd start barrier mask anchor changed: {path}")
    else:
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"systemd start barrier condition anchor changed: {path}")
        if path.read_bytes() != condition_content(
            lock_path, pid, start, token, record["unit"]
        ):
            fail(f"systemd start barrier condition anchor changed: {path}")


def validate_public_state(
    root: Path,
    manifest: dict[str, Any],
    require_held: bool,
) -> None:
    anchors = {record["id"]: record for record in manifest["anchors"]}
    active = set(manifest["active"])
    known_paths = {record["public"]: record for record in anchors.values()}
    for unit in manifest["units"]:
        for kind in ("condition", "mask"):
            path = public_path(root, unit, kind)
            if lexists(path) and str(path) not in known_paths:
                fail(f"foreign systemd start barrier artifact is present: {path}")
    for identifier, record in anchors.items():
        path = Path(record["public"])
        present = lexists(path)
        if present:
            metadata = path.lstat()
            if (metadata.st_dev, metadata.st_ino) != (
                record["device"],
                record["inode"],
            ):
                fail(f"systemd start barrier public identity changed: {path}")
            if record["kind"] == "mask":
                if not stat.S_ISLNK(metadata.st_mode) or os.readlink(path) != "/dev/null":
                    fail(f"systemd start barrier public mask changed: {path}")
            elif not stat.S_ISREG(metadata.st_mode):
                fail(f"systemd start barrier public condition changed: {path}")
        if manifest["phase"] == "held" or require_held:
            if identifier in active and not present:
                fail(f"owned systemd start barrier is missing: {path}")
            if identifier not in active and present:
                fail(f"retired systemd start barrier remains published: {path}")


def publish_anchor(record: dict[str, Any]) -> None:
    anchor = Path(record["anchor"])
    destination = Path(record["public"])
    if lexists(destination):
        fail(f"systemd start barrier path already exists: {destination}")
    os.link(anchor, destination, follow_symlinks=False)
    metadata = destination.lstat()
    if (metadata.st_dev, metadata.st_ino) != (
        record["device"],
        record["inode"],
    ):
        fail(f"systemd start barrier publication changed identity: {destination}")
    fsync_directory(destination.parent)


def install(args: argparse.Namespace) -> None:
    root = Path(args.root)
    lock_path = Path(args.activation_lock)
    units = parse_units(args.units)
    modes = parse_modes(args.modes, units)
    validate_owner(args.owner_pid, args.owner_start, args.owner_token)
    require_canonical_absolute(root, "systemd start barrier root")
    require_canonical_absolute(lock_path, "activation lock path")
    for path in (root.parent.parent, root.parent, root):
        ensure_directory(path)
    owner_dir = owner_directory(root, args.owner_token)
    if lexists(owner_dir):
        fail(f"systemd start barrier owner directory already exists: {owner_dir}")
    owner_dir.mkdir(mode=0o700)
    anchors_dir = owner_dir / "anchors"
    anchors_dir.mkdir(mode=0o700)
    fsync_directory(owner_dir)
    manifest = manifest_template(
        root,
        lock_path,
        args.owner_pid,
        args.owner_start,
        args.owner_token,
        units,
    )
    try:
        for unit in units:
            kind = modes[unit]
            destination = public_path(root, unit, kind)
            if lexists(destination):
                fail(f"systemd start barrier path already exists: {destination}")
            if kind == "condition":
                created, metadata = ensure_directory(destination.parent)
                if created:
                    manifest["createdDirectories"].append(
                        directory_record(destination.parent, metadata)
                    )
            manifest["anchors"].append(
                create_anchor(
                    anchors_dir,
                    root,
                    lock_path,
                    args.owner_pid,
                    args.owner_start,
                    args.owner_token,
                    unit,
                    kind,
                )
            )
        manifest["active"] = [
            anchor_identifier(unit, modes[unit]) for unit in units
        ]
        write_manifest(owner_dir, manifest, initial=True)
        for identifier in manifest["active"]:
            record = next(
                value
                for value in manifest["anchors"]
                if value["id"] == identifier
            )
            publish_anchor(record)
        manifest["phase"] = "held"
        write_manifest(owner_dir, manifest, initial=False)
        validate_public_state(root, manifest, require_held=True)
    except BaseException:
        try:
            if (owner_dir / MANIFEST_NAME).is_file():
                remove_owned_set(
                    root,
                    lock_path,
                    args.owner_pid,
                    args.owner_start,
                    args.owner_token,
                    units,
                    args.read_limit,
                    require_lock=False,
                )
            elif owner_dir.is_dir() and not owner_dir.is_symlink():
                for entry in anchors_dir.iterdir():
                    entry.unlink()
                anchors_dir.rmdir()
                for name in (NEXT_MANIFEST_NAME, MANIFEST_NAME):
                    candidate = owner_dir / name
                    if lexists(candidate):
                        candidate.unlink()
                owner_dir.rmdir()
        except BaseException as cleanup_error:
            print(
                f"systemd start barrier partial-install cleanup failed: {cleanup_error}",
                file=sys.stderr,
            )
        raise
    print(owner_dir)


def transition(args: argparse.Namespace) -> None:
    root = Path(args.root)
    lock_path = Path(args.activation_lock)
    units = parse_units(args.units)
    modes = parse_modes(args.modes, units)
    validate_owner(args.owner_pid, args.owner_start, args.owner_token)
    owner_dir, manifest = load_manifest(
        root,
        lock_path,
        args.owner_pid,
        args.owner_start,
        args.owner_token,
        units,
        args.read_limit,
    )
    if manifest["phase"] != "held":
        fail("systemd start barrier transition requires a held owner manifest")
    validate_public_state(root, manifest, require_held=True)
    anchors_dir = owner_dir / "anchors"
    by_identifier = {record["id"]: record for record in manifest["anchors"]}
    desired: list[str] = []
    for unit in units:
        identifier = anchor_identifier(unit, modes[unit])
        desired.append(identifier)
        if identifier in by_identifier:
            continue
        destination = public_path(root, unit, modes[unit])
        if lexists(destination):
            fail(f"foreign systemd start barrier artifact is present: {destination}")
        if modes[unit] == "condition":
            created, metadata = ensure_directory(destination.parent)
            if created:
                manifest["createdDirectories"].append(
                    directory_record(destination.parent, metadata)
                )
        record = create_anchor(
            anchors_dir,
            root,
            lock_path,
            args.owner_pid,
            args.owner_start,
            args.owner_token,
            unit,
            modes[unit],
        )
        manifest["anchors"].append(record)
        by_identifier[identifier] = record
    if desired == manifest["active"]:
        return
    manifest["phase"] = "transitioning"
    manifest["active"] = desired
    write_manifest(owner_dir, manifest, initial=False)
    for identifier in desired:
        record = by_identifier[identifier]
        if not lexists(Path(record["public"])):
            publish_anchor(record)
    for identifier, record in by_identifier.items():
        if identifier in desired:
            continue
        path = Path(record["public"])
        if lexists(path):
            metadata = path.lstat()
            if (metadata.st_dev, metadata.st_ino) != (
                record["device"],
                record["inode"],
            ):
                fail(f"systemd start barrier public identity changed: {path}")
            path.unlink()
            fsync_directory(path.parent)
    manifest["phase"] = "held"
    write_manifest(owner_dir, manifest, initial=False)
    validate_public_state(root, manifest, require_held=True)


def status(args: argparse.Namespace) -> None:
    root = Path(args.root)
    lock_path = Path(args.activation_lock)
    units = parse_units(args.units)
    validate_owner(args.owner_pid, args.owner_start, args.owner_token)
    _owner_dir, manifest = load_manifest(
        root,
        lock_path,
        args.owner_pid,
        args.owner_start,
        args.owner_token,
        units,
        args.read_limit,
    )
    if manifest["phase"] != "held":
        fail("systemd start barrier set is not held")
    validate_public_state(root, manifest, require_held=True)
    by_identifier = {record["id"]: record for record in manifest["anchors"]}
    for identifier in manifest["active"]:
        record = by_identifier[identifier]
        print(f"{record['unit']}\t{record['kind']}\t{record['public']}")


def parse_lock(path: Path, limit: int) -> tuple[tuple[int, int, int, int], bytes, dict[str, str]] | None:
    if not lexists(path):
        return None
    identity, data = read_regular(path, limit)
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError:
        return None
    fields: dict[str, str] = {}
    for line in lines:
        parts = line.split("\t", 1)
        if len(parts) != 2 or parts[0] in fields:
            return None
        fields[parts[0]] = parts[1]
    if (
        set(fields) != {"format", "pid", "start", "token"}
        or fields["format"] != LOCK_FORMAT
        or not fields["pid"].isdecimal()
        or int(fields["pid"]) <= 0
        or START_PATTERN.fullmatch(fields["start"]) is None
        or TOKEN_PATTERN.fullmatch(fields["token"]) is None
    ):
        return None
    return identity, data, fields


def require_matching_lock(
    path: Path,
    limit: int,
    pid: str,
    start: str,
    token: str,
) -> None:
    record = parse_lock(path, limit)
    if record is None or record[2] != {
        "format": LOCK_FORMAT,
        "pid": pid,
        "start": start,
        "token": token,
    }:
        fail("activation lock no longer owns the systemd start barriers")


def remove_owned_set(
    root: Path,
    lock_path: Path,
    pid: str,
    start: str,
    token: str,
    units: list[str],
    limit: int,
    require_lock: bool,
) -> bool:
    owner_dir_path = owner_directory(root, token)
    if not lexists(owner_dir_path):
        return False
    if require_lock:
        require_matching_lock(lock_path, limit, pid, start, token)
    owner_dir, manifest = load_manifest(
        root, lock_path, pid, start, token, units, limit
    )
    validate_public_state(root, manifest, require_held=False)
    for record in manifest["anchors"]:
        path = Path(record["public"])
        if not lexists(path):
            continue
        metadata = path.lstat()
        if (metadata.st_dev, metadata.st_ino) != (
            record["device"],
            record["inode"],
        ):
            fail(f"systemd start barrier public identity changed: {path}")
        path.unlink()
        fsync_directory(path.parent)
    if require_lock:
        require_matching_lock(lock_path, limit, pid, start, token)
    anchors_dir = owner_dir / "anchors"
    for record in manifest["anchors"]:
        anchor = Path(record["anchor"])
        verify_anchor(anchor, record, lock_path, pid, start, token)
        anchor.unlink()
    fsync_directory(anchors_dir)
    anchors_dir.rmdir()
    next_manifest = owner_dir / NEXT_MANIFEST_NAME
    if lexists(next_manifest):
        metadata = next_manifest.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            fail("systemd start barrier next manifest is unsafe")
        next_manifest.unlink()
    (owner_dir / MANIFEST_NAME).unlink()
    fsync_directory(owner_dir)
    owner_dir.rmdir()
    fsync_directory(root)
    for record in reversed(manifest["createdDirectories"]):
        path = Path(record["path"])
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            continue
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISDIR(metadata.st_mode)
            or (metadata.st_dev, metadata.st_ino)
            != (record["device"], record["inode"])
        ):
            fail(f"systemd start barrier directory identity changed: {path}")
        try:
            path.rmdir()
        except OSError:
            continue
        fsync_directory(path.parent)
    return True


def remove(args: argparse.Namespace) -> None:
    root = Path(args.root)
    lock_path = Path(args.activation_lock)
    units = parse_units(args.units)
    validate_owner(args.owner_pid, args.owner_start, args.owner_token)
    removed = remove_owned_set(
        root,
        lock_path,
        args.owner_pid,
        args.owner_start,
        args.owner_token,
        units,
        args.read_limit,
        require_lock=True,
    )
    print("removed" if removed else "absent")


def owner_is_live(owner: dict[str, str], proc_root: Path) -> bool:
    pid = int(owner["pid"])
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    if owner["start"] == "UNKNOWN":
        return True
    try:
        value = (proc_root / str(pid) / "stat").read_text(encoding="utf-8")
    except (FileNotFoundError, PermissionError, OSError):
        return False
    fields = value[value.rfind(")") + 2 :].split()
    observed = fields[19] if len(fields) > 19 else "UNKNOWN"
    return observed == owner["start"]


def remove_legacy_v1(
    root: Path,
    lock_path: Path,
    owner: dict[str, str],
    units: list[str],
    limit: int,
) -> bool:
    barriers = [
        public_path(root, unit, "condition")
        for unit in units
    ]
    masks = [public_path(root, unit, "mask") for unit in units]
    if any(lexists(path) for path in masks):
        fail("unowned systemd start barrier mask is present")
    present = [lexists(path) for path in barriers]
    if not any(present):
        return False
    if not all(present):
        fail("legacy systemd start barrier set is incomplete")
    expected = (
        "# codexswitch-activation-start-barrier-v1\n"
        f"# owner_pid={owner['pid']}\n"
        f"# owner_start={owner['start']}\n"
        f"# owner_token={owner['token']}\n"
        "[Unit]\n"
        f"ConditionPathExists=!{lock_path}\n"
    ).encode("utf-8")
    identities: dict[Path, tuple[int, int, int, int]] = {}
    for path in barriers:
        identity, data = read_regular(path, limit)
        if data != expected:
            fail(f"legacy systemd start barrier ownership changed: {path}")
        identities[path] = identity
    for path in barriers:
        metadata = path.lstat()
        identity = (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mode,
            metadata.st_size,
        )
        if identity != identities[path]:
            fail(f"legacy systemd start barrier changed identity: {path}")
    for path in barriers:
        path.unlink()
        fsync_directory(path.parent)
        try:
            path.parent.rmdir()
        except OSError:
            pass
    fsync_directory(root)
    return True


def reconcile(args: argparse.Namespace) -> None:
    install_root = Path(args.install_root)
    lock_path = Path(args.activation_lock)
    root = Path(args.root)
    proc_root = Path(args.proc_root)
    units = parse_units(args.units)
    require_canonical_absolute(install_root, "activation mutex root")
    require_canonical_absolute(root, "systemd start barrier root")
    descriptor = os.open(
        install_root,
        os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        lock_record = parse_lock(lock_path, args.read_limit)
        if lock_record is None:
            print("unverified")
            return
        lock_identity, lock_data, owner = lock_record
        if owner_is_live(owner, proc_root):
            print("live")
            return
        v2_dir = owner_directory(root, owner["token"])
        if lexists(v2_dir):
            removed = remove_owned_set(
                root,
                lock_path,
                owner["pid"],
                owner["start"],
                owner["token"],
                units,
                args.read_limit,
                require_lock=True,
            )
        else:
            removed = remove_legacy_v1(
                root, lock_path, owner, units, args.read_limit
            )
        current = parse_lock(lock_path, args.read_limit)
        if (
            current is None
            or current[0] != lock_identity
            or current[1] != lock_data
        ):
            fail("stale activation owner changed during barrier removal")
        print("removed" if removed else "absent")
    finally:
        os.close(descriptor)


def add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", required=True)
    parser.add_argument("--activation-lock", required=True)
    parser.add_argument("--owner-pid", required=True)
    parser.add_argument("--owner-start", required=True)
    parser.add_argument("--owner-token", required=True)
    parser.add_argument("--units", required=True)
    parser.add_argument("--read-limit", required=True, type=int)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    install_parser = subparsers.add_parser("install")
    add_common_arguments(install_parser)
    install_parser.add_argument("--modes", required=True)
    install_parser.set_defaults(handler=install)

    transition_parser = subparsers.add_parser("transition")
    add_common_arguments(transition_parser)
    transition_parser.add_argument("--modes", required=True)
    transition_parser.set_defaults(handler=transition)

    status_parser = subparsers.add_parser("status")
    add_common_arguments(status_parser)
    status_parser.set_defaults(handler=status)

    remove_parser = subparsers.add_parser("remove")
    add_common_arguments(remove_parser)
    remove_parser.set_defaults(handler=remove)

    reconcile_parser = subparsers.add_parser("reconcile")
    reconcile_parser.add_argument("--install-root", required=True)
    reconcile_parser.add_argument("--activation-lock", required=True)
    reconcile_parser.add_argument("--root", required=True)
    reconcile_parser.add_argument("--proc-root", required=True)
    reconcile_parser.add_argument("--units", required=True)
    reconcile_parser.add_argument("--read-limit", required=True, type=int)
    reconcile_parser.set_defaults(handler=reconcile)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
