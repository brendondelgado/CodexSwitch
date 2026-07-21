#!/usr/bin/env python3
"""Validate and freeze a CodexSwitch Linux runtime artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any, NoReturn


ARTIFACT_FORMAT = "codexswitch-linux-runtime-artifact-v1"
EXECUTABLE_NAMES = ("codex", "codex-code-mode-host", "codexswitch-cli")
EXPECTED_NAMES = frozenset((*EXECUTABLE_NAMES, "manifest.json"))
MANIFEST_MAX_BYTES = 64 * 1024
RELEASE_MAX_BYTES = 2 * 1024 * 1024 * 1024
COPY_BUFFER_BYTES = 1024 * 1024
QUARANTINE_FILE_MODE = 0o400
STAGED_EXECUTABLE_MODE = 0o500
FROZEN_DIRECTORY_MODE = 0o500


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def _open_directory(path: Path) -> int:
    if not path.is_absolute() or path != Path(os.path.realpath(path)):
        fail(f"artifact directory must be an absolute canonical path: {path}")
    try:
        metadata = os.lstat(path)
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
    except OSError as error:
        fail(f"failed to open artifact directory {path}: {error}")
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_dev != opened.st_dev
        or metadata.st_ino != opened.st_ino
    ):
        os.close(descriptor)
        fail(f"artifact directory is linked, special, or changed while opened: {path}")
    return descriptor


def _directory_names(descriptor: int) -> None:
    names = os.listdir(descriptor)
    if len(names) != len(EXPECTED_NAMES) or set(names) != EXPECTED_NAMES:
        fail("artifact must contain exactly three executables and manifest.json")


def _open_regular_at(
    directory_fd: int, name: str, max_bytes: int
) -> tuple[int, os.stat_result]:
    try:
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=directory_fd,
        )
    except OSError as error:
        fail(f"failed to open artifact member {name}: {error}")
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size <= 0
        or metadata.st_size > max_bytes
        or opened.st_dev != metadata.st_dev
        or opened.st_ino != metadata.st_ino
        or opened.st_size != metadata.st_size
        or not stat.S_ISREG(opened.st_mode)
    ):
        os.close(descriptor)
        fail(f"artifact member is linked, special, empty, oversized, or changed: {name}")
    return descriptor, opened


def _read_descriptor(descriptor: int, max_bytes: int, name: str) -> bytes:
    chunks: list[bytes] = []
    observed = 0
    while True:
        chunk = os.read(descriptor, min(COPY_BUFFER_BYTES, max_bytes + 1 - observed))
        if not chunk:
            break
        chunks.append(chunk)
        observed += len(chunk)
        if observed > max_bytes:
            fail(f"artifact member exceeded its size limit: {name}")
    return b"".join(chunks)


def _sha256_descriptor(descriptor: int, max_bytes: int, name: str) -> tuple[int, str]:
    digest = hashlib.sha256()
    observed = 0
    while True:
        chunk = os.read(descriptor, COPY_BUFFER_BYTES)
        if not chunk:
            break
        observed += len(chunk)
        if observed > max_bytes:
            fail(f"artifact member exceeded its size limit: {name}")
        digest.update(chunk)
    return observed, digest.hexdigest()


def _validate_manifest(raw_manifest: bytes) -> dict[str, Any]:
    try:
        manifest = json.loads(raw_manifest)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"artifact manifest is malformed: {error}")
    expected_keys = {
        "format",
        "codexSwitchGitSha",
        "codexSwitchBuildVersion",
        "upstreamCodexVersion",
        "upstreamCodexGitSha",
        "sourcePatchSha256",
        "targetTriple",
        "architecture",
        "buildEpoch",
        "files",
    }
    if type(manifest) is not dict or set(manifest) != expected_keys:
        fail("artifact manifest has an unexpected schema")

    source_sha = manifest["codexSwitchGitSha"]
    upstream_sha = manifest["upstreamCodexGitSha"]
    patch_sha = manifest["sourcePatchSha256"]
    version = manifest["upstreamCodexVersion"]
    build_epoch = manifest["buildEpoch"]
    build_version = manifest["codexSwitchBuildVersion"]
    if manifest["format"] != ARTIFACT_FORMAT:
        fail("artifact manifest format is unsupported")
    if (
        manifest["targetTriple"] != "x86_64-unknown-linux-gnu"
        or manifest["architecture"] != "x86_64"
    ):
        fail("artifact target is not native Linux x86_64")
    if not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        fail("artifact CodexSwitch commit is invalid")
    if not isinstance(upstream_sha, str) or not re.fullmatch(
        r"[0-9a-f]{40}", upstream_sha
    ):
        fail("artifact upstream peeled commit is invalid")
    if not isinstance(patch_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", patch_sha):
        fail("artifact source patch digest is invalid")
    if not isinstance(version, str) or not re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+", version
    ):
        fail("artifact upstream version is invalid")
    if type(build_epoch) is not int or build_epoch <= 0:
        fail("artifact build epoch is invalid")
    expected_build = rf"codexswitch-cli [^\s]+ \(git {source_sha}, built {build_epoch}\)"
    if (
        not isinstance(build_version, str)
        or len(build_version) > 512
        or not re.fullmatch(expected_build, build_version)
    ):
        fail("artifact control-plane provenance is invalid")

    files = manifest["files"]
    if type(files) is not list or [
        item.get("name") for item in files if type(item) is dict
    ] != list(EXECUTABLE_NAMES):
        fail("artifact executable manifest is incomplete or reordered")
    payload_bytes = 0
    for item in files:
        if type(item) is not dict or set(item) != {"name", "bytes", "sha256"}:
            fail("artifact executable identity has an unexpected schema")
        if type(item["bytes"]) is not int or not 0 < item["bytes"] <= RELEASE_MAX_BYTES:
            fail(f"artifact byte length is invalid: {item['name']}")
        if not isinstance(item["sha256"], str) or not re.fullmatch(
            r"[0-9a-f]{64}", item["sha256"]
        ):
            fail(f"artifact SHA-256 is invalid: {item['name']}")
        payload_bytes += item["bytes"]
    if payload_bytes + len(raw_manifest) > RELEASE_MAX_BYTES:
        fail("complete artifact exceeds the 2 GiB release limit")
    return manifest


def _mode_for(name: str, mode_contract: str) -> int | None:
    if mode_contract == "source":
        return None
    if mode_contract == "quarantine" or name == "manifest.json":
        return QUARANTINE_FILE_MODE
    return STAGED_EXECUTABLE_MODE


def inspect(directory: Path, mode_contract: str) -> dict[str, Any]:
    directory_fd = _open_directory(directory)
    try:
        _directory_names(directory_fd)
        if mode_contract != "source":
            observed_directory_mode = stat.S_IMODE(os.fstat(directory_fd).st_mode)
            if observed_directory_mode != FROZEN_DIRECTORY_MODE:
                fail("frozen artifact directory mode is invalid")

        manifest_fd, manifest_metadata = _open_regular_at(
            directory_fd, "manifest.json", MANIFEST_MAX_BYTES
        )
        try:
            raw_manifest = _read_descriptor(
                manifest_fd, MANIFEST_MAX_BYTES, "manifest.json"
            )
        finally:
            os.close(manifest_fd)
        expected_mode = _mode_for("manifest.json", mode_contract)
        if expected_mode is not None and stat.S_IMODE(manifest_metadata.st_mode) != expected_mode:
            fail("frozen artifact manifest mode is invalid")
        manifest = _validate_manifest(raw_manifest)

        observed_total = len(raw_manifest)
        for item in manifest["files"]:
            name = item["name"]
            descriptor, metadata = _open_regular_at(
                directory_fd, name, RELEASE_MAX_BYTES
            )
            try:
                observed_bytes, observed_sha = _sha256_descriptor(
                    descriptor, RELEASE_MAX_BYTES, name
                )
            finally:
                os.close(descriptor)
            expected_mode = _mode_for(name, mode_contract)
            if expected_mode is not None and stat.S_IMODE(metadata.st_mode) != expected_mode:
                fail(f"frozen artifact executable mode is invalid: {name}")
            if observed_bytes != item["bytes"] or observed_sha != item["sha256"]:
                fail(f"artifact identity mismatch: {name}")
            observed_total += observed_bytes
        if observed_total > RELEASE_MAX_BYTES:
            fail("complete artifact exceeds the 2 GiB release limit")

        return {
            "artifactBytes": observed_total,
            "buildEpoch": manifest["buildEpoch"],
            "buildVersion": manifest["codexSwitchBuildVersion"],
            "manifestSha256": hashlib.sha256(raw_manifest).hexdigest(),
            "sourcePatchSha256": manifest["sourcePatchSha256"],
            "sourceSha": manifest["codexSwitchGitSha"],
            "upstreamSha": manifest["upstreamCodexGitSha"],
            "upstreamVersion": manifest["upstreamCodexVersion"],
        }
    finally:
        os.close(directory_fd)


def _create_destination(path: Path) -> int:
    if not path.is_absolute() or path.parent != Path(os.path.realpath(path.parent)):
        fail(f"artifact destination parent must be absolute and canonical: {path.parent}")
    if path.exists() or path.is_symlink():
        fail(f"artifact destination already exists: {path}")
    path.mkdir(mode=0o700)
    return _open_directory(path)


def _copy_snapshot(source: Path, destination: Path) -> None:
    source_fd = _open_directory(source)
    try:
        _directory_names(source_fd)
        destination_fd = _create_destination(destination)
        try:
            for name in ("manifest.json", *EXECUTABLE_NAMES):
                max_bytes = MANIFEST_MAX_BYTES if name == "manifest.json" else RELEASE_MAX_BYTES
                input_fd, before = _open_regular_at(source_fd, name, max_bytes)
                output_fd = os.open(
                    name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    QUARANTINE_FILE_MODE,
                    dir_fd=destination_fd,
                )
                try:
                    copied = 0
                    while True:
                        chunk = os.read(input_fd, COPY_BUFFER_BYTES)
                        if not chunk:
                            break
                        copied += len(chunk)
                        if copied > max_bytes:
                            fail(f"artifact member exceeded its size limit while copied: {name}")
                        view = memoryview(chunk)
                        while view:
                            written = os.write(output_fd, view)
                            if written <= 0:
                                fail(f"artifact snapshot write stopped early: {name}")
                            view = view[written:]
                    after = os.fstat(input_fd)
                    if (
                        copied != before.st_size
                        or after.st_dev != before.st_dev
                        or after.st_ino != before.st_ino
                        or after.st_size != before.st_size
                        or after.st_mtime_ns != before.st_mtime_ns
                        or after.st_ctime_ns != before.st_ctime_ns
                    ):
                        fail(f"artifact member changed while copied: {name}")
                    os.fchmod(output_fd, QUARANTINE_FILE_MODE)
                    os.fsync(output_fd)
                finally:
                    os.close(output_fd)
                    os.close(input_fd)
            os.fsync(destination_fd)
        finally:
            os.close(destination_fd)
        os.chmod(destination, FROZEN_DIRECTORY_MODE)
    finally:
        os.close(source_fd)


def snapshot(source: Path, destination: Path) -> dict[str, Any]:
    source_report = inspect(source, "source")
    _copy_snapshot(source, destination)
    destination_report = inspect(destination, "quarantine")
    if destination_report != source_report:
        fail("artifact snapshot changed content or provenance")
    return destination_report


def promote(source: Path, destination: Path) -> dict[str, Any]:
    source_report = inspect(source, "quarantine")
    _copy_snapshot(source, destination)
    copied_report = inspect(destination, "quarantine")
    if copied_report != source_report:
        fail("artifact promotion changed content or provenance")
    directory_fd = _open_directory(destination)
    try:
        for name in EXECUTABLE_NAMES:
            descriptor, _metadata = _open_regular_at(
                directory_fd, name, RELEASE_MAX_BYTES
            )
            try:
                os.fchmod(descriptor, STAGED_EXECUTABLE_MODE)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return inspect(destination, "staged")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--source", type=Path, required=True)
    snapshot_parser.add_argument("--destination", type=Path, required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--directory", type=Path, required=True)
    verify_parser.add_argument(
        "--mode", choices=("source", "quarantine", "staged"), required=True
    )
    promote_parser = subparsers.add_parser("promote")
    promote_parser.add_argument("--source", type=Path, required=True)
    promote_parser.add_argument("--destination", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    if arguments.command == "snapshot":
        report = snapshot(arguments.source, arguments.destination)
    elif arguments.command == "promote":
        report = promote(arguments.source, arguments.destination)
    else:
        report = inspect(arguments.directory, arguments.mode)
    json.dump(report, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
