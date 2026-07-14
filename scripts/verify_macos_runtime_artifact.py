#!/usr/bin/env python3
"""Create and verify a private, byte-pinned macOS runtime artifact snapshot."""

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


ARTIFACT_FORMAT = "codexswitch-macos-runtime-artifact-v1"
EXECUTABLE_NAMES = ("codex", "codex-code-mode-host", "codexswitch-cli")
EXPECTED_NAMES = frozenset((*EXECUTABLE_NAMES, "manifest.json"))
MANIFEST_MAX_BYTES = 64 * 1024
EXECUTABLE_MAX_BYTES = 2 * 1024 * 1024 * 1024
COPY_BUFFER_BYTES = 1024 * 1024


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


def _directory_names(descriptor: int) -> set[str]:
    names = os.listdir(descriptor)
    if len(names) != len(EXPECTED_NAMES) or set(names) != EXPECTED_NAMES:
        fail("artifact must contain exactly three executables and manifest.json")
    return set(names)


def _open_regular_at(directory_fd: int, name: str, max_bytes: int) -> tuple[int, os.stat_result]:
    metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size <= 0
        or metadata.st_size > max_bytes
    ):
        fail(f"artifact member is linked, special, empty, or oversized: {name}")
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=directory_fd,
    )
    opened = os.fstat(descriptor)
    if (
        opened.st_dev != metadata.st_dev
        or opened.st_ino != metadata.st_ino
        or opened.st_size != metadata.st_size
        or not stat.S_ISREG(opened.st_mode)
    ):
        os.close(descriptor)
        fail(f"artifact member changed identity while opened: {name}")
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
    if manifest["targetTriple"] != "aarch64-apple-darwin" or manifest["architecture"] != "arm64":
        fail("artifact target is not native Apple Silicon")
    if not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        fail("artifact CodexSwitch commit is invalid")
    if not isinstance(upstream_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", upstream_sha):
        fail("artifact upstream commit is invalid")
    if not isinstance(patch_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", patch_sha):
        fail("artifact source patch digest is invalid")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        fail("artifact upstream version is invalid")
    if type(build_epoch) is not int or build_epoch <= 0:
        fail("artifact build epoch is invalid")
    expected_build = rf"codexswitch-cli [^\s]+ \(git {source_sha}, built {build_epoch}\)"
    if not isinstance(build_version, str) or not re.fullmatch(expected_build, build_version):
        fail("artifact control-plane provenance is invalid")

    files = manifest["files"]
    if type(files) is not list or [
        item.get("name") for item in files if type(item) is dict
    ] != list(EXECUTABLE_NAMES):
        fail("artifact executable manifest is incomplete or reordered")
    for item in files:
        if type(item) is not dict or set(item) != {"name", "bytes", "sha256"}:
            fail("artifact executable identity has an unexpected schema")
        if type(item["bytes"]) is not int or not 0 < item["bytes"] <= EXECUTABLE_MAX_BYTES:
            fail(f"artifact byte length is invalid: {item['name']}")
        if not isinstance(item["sha256"], str) or not re.fullmatch(
            r"[0-9a-f]{64}", item["sha256"]
        ):
            fail(f"artifact SHA-256 is invalid: {item['name']}")
    return manifest


def verify(directory: Path) -> dict[str, str]:
    directory_fd = _open_directory(directory)
    try:
        _directory_names(directory_fd)
        manifest_fd, manifest_metadata = _open_regular_at(
            directory_fd, "manifest.json", MANIFEST_MAX_BYTES
        )
        try:
            raw_manifest = _read_descriptor(
                manifest_fd, MANIFEST_MAX_BYTES, "manifest.json"
            )
        finally:
            os.close(manifest_fd)
        if manifest_metadata.st_mode & 0o222:
            fail("frozen artifact manifest is writable")
        manifest = _validate_manifest(raw_manifest)

        for item in manifest["files"]:
            name = item["name"]
            descriptor, metadata = _open_regular_at(
                directory_fd, name, EXECUTABLE_MAX_BYTES
            )
            try:
                observed_bytes, observed_sha = _sha256_descriptor(
                    descriptor, EXECUTABLE_MAX_BYTES, name
                )
            finally:
                os.close(descriptor)
            if metadata.st_mode & 0o222 or not metadata.st_mode & stat.S_IXUSR:
                fail(f"frozen artifact executable mode is invalid: {name}")
            if observed_bytes != item["bytes"] or observed_sha != item["sha256"]:
                fail(f"artifact identity mismatch: {name}")

        return {
            "sourceSha": manifest["codexSwitchGitSha"],
            "upstreamVersion": manifest["upstreamCodexVersion"],
            "buildVersion": manifest["codexSwitchBuildVersion"],
            "manifestSha256": hashlib.sha256(raw_manifest).hexdigest(),
        }
    finally:
        os.close(directory_fd)


def snapshot(source: Path, destination: Path) -> dict[str, str]:
    source_fd = _open_directory(source)
    try:
        _directory_names(source_fd)
        if destination.exists() or destination.is_symlink():
            fail(f"snapshot destination already exists: {destination}")
        destination.mkdir(mode=0o700)
        destination_fd = _open_directory(destination)
        try:
            for name in ("manifest.json", *EXECUTABLE_NAMES):
                max_bytes = MANIFEST_MAX_BYTES if name == "manifest.json" else EXECUTABLE_MAX_BYTES
                input_fd, before = _open_regular_at(source_fd, name, max_bytes)
                output_mode = 0o400 if name == "manifest.json" else 0o500
                output_fd = os.open(
                    name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                    output_mode,
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
                    os.fchmod(output_fd, output_mode)
                    os.fsync(output_fd)
                finally:
                    os.close(output_fd)
                    os.close(input_fd)
            os.fsync(destination_fd)
        finally:
            os.close(destination_fd)
        os.chmod(destination, 0o500)
    finally:
        os.close(source_fd)
    return verify(destination)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--source", type=Path, required=True)
    snapshot_parser.add_argument("--destination", type=Path, required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--directory", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    if arguments.command == "snapshot":
        report = snapshot(arguments.source, arguments.destination)
    else:
        report = verify(arguments.directory)
    json.dump(report, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
