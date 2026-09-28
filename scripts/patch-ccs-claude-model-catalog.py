#!/usr/bin/env python3
"""Add Claude Opus 5 to the pinned CCS selector and local model cache."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import sys
import tempfile
from typing import Any


PINNED_CCS_VERSION = "8.8.1"
MODEL_ID = "claude-opus-5"
PATCH_MARKER = "CODEXSWITCH_CLAUDE_OPUS_5_CATALOG_V1"
PACKAGE_ANCHOR = """        models: [
            {
                id: 'claude-sonnet-5',
"""
PACKAGE_INSERT = """        models: [
            // CODEXSWITCH_CLAUDE_OPUS_5_CATALOG_V1
            {
                id: 'claude-opus-5',
                name: 'Claude Opus 5',
                description: 'Latest Opus model',
                nativeImageInput: true,
                thinking: {
                    type: 'levels',
                    levels: ['low', 'medium', 'high', 'xhigh', 'max'],
                    maxLevel: 'max',
                    dynamicAllowed: true,
                },
                extendedContext: true,
            },
            {
                id: 'claude-sonnet-5',
"""
MODEL_CACHE_ENTRY: dict[str, Any] = {
    "id": MODEL_ID,
    "object": "model",
    "created": 1784851200,
    "owned_by": "anthropic",
    "type": "claude",
    "display_name": "Claude Opus 5",
    "description": "Latest Opus model",
    "context_length": 1_000_000,
    "max_completion_tokens": 128_000,
    "thinking": {
        "min": 1024,
        "max": 128_000,
        "zero_allowed": True,
        "levels": ["low", "medium", "high", "xhigh", "max"],
    },
}


class PatchRefused(RuntimeError):
    """The installed CCS subject does not match the pinned patch contract."""


def fsync_directory(path: pathlib.Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write(path: pathlib.Path, data: bytes) -> None:
    stat = path.stat()
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.codexswitch-",
        dir=path.parent,
    )
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, stat.st_mode)
        if os.geteuid() == 0:
            os.chown(temporary, stat.st_uid, stat.st_gid)
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def ensure_backup(path: pathlib.Path) -> pathlib.Path:
    backup = path.with_name(f"{path.name}.codexswitch-pre-opus5")
    if backup.exists():
        return backup
    shutil.copy2(path, backup)
    if os.geteuid() == 0:
        stat = path.stat()
        os.chown(backup, stat.st_uid, stat.st_gid)
    with backup.open("rb") as handle:
        os.fsync(handle.fileno())
    fsync_directory(path.parent)
    return backup


def patch_package(package_root: pathlib.Path, *, check: bool) -> bool:
    package_json = package_root / "package.json"
    catalog = package_root / "dist" / "cliproxy" / "model-catalog.js"
    if not package_json.is_file() or not catalog.is_file():
        raise PatchRefused(f"CCS package subject is incomplete: {package_root}")

    version = json.loads(package_json.read_text()).get("version")
    if version != PINNED_CCS_VERSION:
        raise PatchRefused(
            f"CCS version {version!r} is not pinned version {PINNED_CCS_VERSION!r}"
        )

    text = catalog.read_text()
    model_occurrences = text.count(f"id: '{MODEL_ID}'")
    marker_occurrences = text.count(PATCH_MARKER)
    if model_occurrences == 1 and marker_occurrences == 1:
        return False
    if model_occurrences or marker_occurrences:
        raise PatchRefused("CCS Opus 5 package postimage is partial or ambiguous")
    if text.count(PACKAGE_ANCHOR) != 1:
        raise PatchRefused("CCS Claude catalog insertion anchor is not exact")
    if check:
        raise PatchRefused("CCS package does not contain the Opus 5 postimage")

    ensure_backup(catalog)
    atomic_write(catalog, text.replace(PACKAGE_ANCHOR, PACKAGE_INSERT).encode())
    installed = catalog.read_text()
    if installed.count(f"id: '{MODEL_ID}'") != 1 or installed.count(PATCH_MARKER) != 1:
        raise PatchRefused("CCS package postimage verification failed")
    return True


def patch_cache(cache_path: pathlib.Path, *, check: bool) -> bool:
    if not cache_path.is_file():
        raise PatchRefused(f"CCS model cache is missing: {cache_path}")
    payload = json.loads(cache_path.read_text())
    providers = payload.get("providers")
    if not isinstance(providers, dict) or not isinstance(providers.get("claude"), list):
        raise PatchRefused("CCS model cache Claude provider shape is unknown")

    models = providers["claude"]
    existing = [
        model for model in models if isinstance(model, dict) and model.get("id") == MODEL_ID
    ]
    if len(existing) == 1:
        if existing[0] != MODEL_CACHE_ENTRY:
            raise PatchRefused("CCS Opus 5 cache entry disagrees with the frozen postimage")
        return False
    if existing:
        raise PatchRefused("CCS Opus 5 cache entry is duplicated")
    if check:
        raise PatchRefused("CCS model cache does not contain the Opus 5 postimage")

    ensure_backup(cache_path)
    models.insert(0, MODEL_CACHE_ENTRY)
    encoded = (json.dumps(payload, separators=(",", ":")) + "\n").encode()
    atomic_write(cache_path, encoded)
    installed = json.loads(cache_path.read_text())
    installed_models = installed["providers"]["claude"]
    if sum(model.get("id") == MODEL_ID for model in installed_models) != 1:
        raise PatchRefused("CCS model cache postimage verification failed")
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install or verify the pinned Claude Opus 5 CCS catalog patch."
    )
    parser.add_argument(
        "--package-root",
        type=pathlib.Path,
        default=pathlib.Path("/usr/lib/node_modules/@kaitranntt/ccs"),
    )
    parser.add_argument(
        "--cache",
        type=pathlib.Path,
        default=pathlib.Path("~/.ccs/model-catalog-cache.json").expanduser(),
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the exact postimage without writing",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        package_changed = patch_package(args.package_root, check=args.check)
        cache_changed = patch_cache(args.cache, check=args.check)
    except (OSError, ValueError, json.JSONDecodeError, PatchRefused) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 1

    state = "verified" if args.check else "installed"
    changed = "changed" if package_changed or cache_changed else "already exact"
    print(f"Claude Opus 5 CCS catalog {state}: {changed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
