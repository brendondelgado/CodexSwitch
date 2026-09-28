#!/usr/bin/env python3
"""Restore Anthropic scoped model limits in the pinned CCS quota checker."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import sys
import tempfile


PINNED_CCS_VERSION = "8.8.1"
PATCH_MARKER = "CODEXSWITCH_CLAUDE_SCOPED_QUOTA_LIMITS_V1"
TARGET_RELATIVE_PATH = pathlib.Path(
    "dist/cliproxy/quota/quota-fetcher-claude-normalizer.js"
)
BACKUP_SUFFIX = ".codexswitch-pre-scoped-quota"
TARGET_ANCHOR = """function buildClaudeQuotaWindows(payload) {
    const rawRestrictions = payload['restrictions'];
    const windows = [];
    if (Array.isArray(rawRestrictions)) {
"""
PATCH_INSERT = """// CODEXSWITCH_CLAUDE_SCOPED_QUOTA_LIMITS_V1
function slugifyClaudeScopedLimit(value) {
    return value
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '_')
        .replace(/^_+|_+$/g, '');
}
function buildClaudeScopedQuotaWindows(rawLimits) {
    if (!Array.isArray(rawLimits))
        return [];
    const windows = [];
    for (const value of rawLimits) {
        const raw = toObject(value);
        if (!raw)
            continue;
        const usedRaw = asNumber(raw['percent']);
        if (usedRaw === null)
            continue;
        const group = asString(raw['group']);
        const kind = asString(raw['kind']);
        const scope = toObject(raw['scope']);
        const model = scope ? toObject(scope['model']) : null;
        const modelName = model ? asString(model['display_name'] ?? model['displayName']) : null;
        const modelId = model ? asString(model['id']) : null;
        let rateLimitType;
        let label;
        if (modelName) {
            const stableModelId = modelId || slugifyClaudeScopedLimit(modelName);
            if (!stableModelId)
                continue;
            rateLimitType = `model:${stableModelId}`;
            label = `Weekly usage (${modelName})`;
        }
        else if (group === 'session') {
            rateLimitType = 'five_hour';
            label = 'Session limit';
        }
        else if (group === 'weekly') {
            rateLimitType = 'seven_day';
            label = 'Weekly limit';
        }
        else if (kind) {
            rateLimitType = kind;
            label = getClaudeWindowLabel(kind);
        }
        else {
            continue;
        }
        const usedPercent = (0, percentage_1.clampPercent)(usedRaw);
        windows.push({
            rateLimitType,
            label,
            status: asString(raw['status']) || 'unknown',
            utilization: usedPercent / 100,
            usedPercent,
            remainingPercent: (0, percentage_1.clampPercent)(100 - usedPercent),
            resetAt: normalizeTimestamp(raw['resets_at'] ?? raw['resetsAt'] ?? raw['reset_at'] ?? raw['resetAt']),
            surpassedThreshold: asBoolean(raw['surpassedThreshold'] ?? raw['surpassed_threshold']),
            severity: asString(raw['severity']) || undefined,
        });
    }
    return windows;
}
function buildClaudeQuotaWindows(payload) {
    const rawRestrictions = payload['restrictions'];
    const windows = [];
    const scopedWindows = buildClaudeScopedQuotaWindows(payload['limits']);
    if (scopedWindows.length > 0) {
        windows.push(...scopedWindows);
    }
    else if (Array.isArray(rawRestrictions)) {
"""


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


def subject_paths(package_root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    package_json = package_root / "package.json"
    target = package_root / TARGET_RELATIVE_PATH
    if not package_json.is_file() or not target.is_file():
        raise PatchRefused(f"CCS package subject is incomplete: {package_root}")
    version = json.loads(package_json.read_text()).get("version")
    if version != PINNED_CCS_VERSION:
        raise PatchRefused(
            f"CCS version {version!r} is not pinned version {PINNED_CCS_VERSION!r}"
        )
    return package_json, target


def is_exact_postimage(text: str) -> bool:
    return (
        text.count(PATCH_MARKER) == 1
        and text.count(PATCH_INSERT) == 1
        and text.count(TARGET_ANCHOR) == 0
    )


def validate_preimage(text: str) -> None:
    if PATCH_MARKER in text or PATCH_INSERT in text:
        raise PatchRefused("CCS scoped quota postimage is partial or ambiguous")
    if text.count(TARGET_ANCHOR) != 1:
        raise PatchRefused("CCS scoped quota insertion anchor is not exact")


def ensure_backup(target: pathlib.Path, preimage: bytes) -> pathlib.Path:
    backup = target.with_name(f"{target.name}{BACKUP_SUFFIX}")
    if backup.exists():
        backup_text = backup.read_text()
        validate_preimage(backup_text)
        return backup
    shutil.copy2(target, backup)
    if os.geteuid() == 0:
        stat = target.stat()
        os.chown(backup, stat.st_uid, stat.st_gid)
    with backup.open("rb") as handle:
        os.fsync(handle.fileno())
    fsync_directory(target.parent)
    if backup.read_bytes() != preimage:
        raise PatchRefused("CCS scoped quota backup verification failed")
    return backup


def patch_package(package_root: pathlib.Path, *, check: bool) -> bool:
    _, target = subject_paths(package_root)
    text = target.read_text()
    if is_exact_postimage(text):
        return False
    if PATCH_MARKER in text or PATCH_INSERT in text:
        raise PatchRefused("CCS scoped quota postimage is partial or ambiguous")
    validate_preimage(text)
    if check:
        raise PatchRefused("CCS scoped quota postimage is not installed")

    preimage = target.read_bytes()
    ensure_backup(target, preimage)
    atomic_write(target, text.replace(TARGET_ANCHOR, PATCH_INSERT).encode())
    if not is_exact_postimage(target.read_text()):
        raise PatchRefused("CCS scoped quota postimage verification failed")
    return True


def restore_package(package_root: pathlib.Path) -> bool:
    _, target = subject_paths(package_root)
    current = target.read_text()
    backup = target.with_name(f"{target.name}{BACKUP_SUFFIX}")
    if not backup.is_file():
        raise PatchRefused(f"CCS scoped quota backup is missing: {backup}")
    backup_text = backup.read_text()
    validate_preimage(backup_text)
    if PATCH_MARKER not in current:
        if current == backup_text:
            return False
        raise PatchRefused("CCS target is neither the patch postimage nor its backup")
    if not is_exact_postimage(current):
        raise PatchRefused("CCS scoped quota postimage drifted; refusing rollback")
    atomic_write(target, backup.read_bytes())
    if target.read_text() != backup_text:
        raise PatchRefused("CCS scoped quota rollback verification failed")
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install, verify, or restore the pinned CCS scoped quota patch."
    )
    parser.add_argument(
        "--package-root",
        type=pathlib.Path,
        default=pathlib.Path("/usr/lib/node_modules/@kaitranntt/ccs"),
    )
    action = parser.add_mutually_exclusive_group()
    action.add_argument(
        "--check",
        action="store_true",
        help="verify the exact postimage without writing",
    )
    action.add_argument(
        "--restore",
        action="store_true",
        help="restore the exact pre-patch backup",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.restore:
            changed = restore_package(args.package_root)
            action = "restored"
        else:
            changed = patch_package(args.package_root, check=args.check)
            action = "verified" if args.check else "installed"
    except (OSError, ValueError, json.JSONDecodeError, PatchRefused) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 1

    detail = "changed" if changed else "already exact"
    print(f"Claude scoped quota CCS patch {action}: {detail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
