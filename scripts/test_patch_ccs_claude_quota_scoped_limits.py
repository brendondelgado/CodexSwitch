#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "patch-ccs-claude-quota-scoped-limits.py"
SPEC = importlib.util.spec_from_file_location("patch_ccs_scoped_quota", SCRIPT)
assert SPEC and SPEC.loader
PATCHER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCHER)


SYNTHETIC_NORMALIZER = """\
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.buildClaudeQuotaWindows = void 0;
const percentage_1 = {
    clampPercent(value) {
        return Math.max(0, Math.min(100, value));
    },
};
function asString(value) {
    return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}
function asBoolean(value) {
    return typeof value === 'boolean' ? value : undefined;
}
function asNumber(value) {
    if (typeof value === 'number' && isFinite(value))
        return value;
    if (typeof value === 'string') {
        const parsed = Number(value);
        return isFinite(parsed) ? parsed : null;
    }
    return null;
}
function normalizeTimestamp(value) {
    if (value === null || value === undefined)
        return null;
    const date = new Date(value);
    return isNaN(date.getTime()) ? null : date.toISOString();
}
function toObject(value) {
    if (typeof value !== 'object' || value === null || Array.isArray(value))
        return null;
    return value;
}
function getClaudeWindowLabel(rateLimitType) {
    if (rateLimitType === 'five_hour')
        return 'Session limit';
    if (rateLimitType === 'seven_day')
        return 'Weekly limit';
    return rateLimitType || 'Unknown limit';
}
function normalizeRestriction(raw, fallbackKey, unit) {
    const rateLimitType = asString(raw['rateLimitType'] ?? raw['rate_limit_type']) || fallbackKey;
    if (!rateLimitType)
        return null;
    const utilizationRaw = asNumber(raw['utilization']);
    if (utilizationRaw === null)
        return null;
    const usedPercent = percentage_1.clampPercent(
        unit === 'ratio' ? utilizationRaw * 100 : utilizationRaw
    );
    return {
        rateLimitType,
        label: getClaudeWindowLabel(rateLimitType),
        status: asString(raw['status']) || 'unknown',
        utilization: usedPercent / 100,
        usedPercent,
        remainingPercent: percentage_1.clampPercent(100 - usedPercent),
        resetAt: normalizeTimestamp(raw['resets_at'] ?? raw['reset_at']),
    };
}
function isClaudeOAuthUsageWindowCandidate(key, raw) {
    if (key === 'extra_usage')
        return false;
    if (asNumber(raw['utilization']) === null)
        return false;
    const resetAt = raw['resets_at'] ?? raw['reset_at'] ?? null;
    return resetAt !== null && resetAt !== undefined;
}
function buildClaudeQuotaWindows(payload) {
    const rawRestrictions = payload['restrictions'];
    const windows = [];
    if (Array.isArray(rawRestrictions)) {
        for (const item of rawRestrictions) {
            const raw = toObject(item);
            if (!raw)
                continue;
            const window = normalizeRestriction(raw, undefined, 'ratio');
            if (window)
                windows.push(window);
        }
    }
    else if (toObject(rawRestrictions)) {
        for (const [key, value] of Object.entries(rawRestrictions)) {
            const raw = toObject(value);
            if (!raw)
                continue;
            const window = normalizeRestriction(raw, key, 'ratio');
            if (window)
                windows.push(window);
        }
    }
    else if (toObject(payload)) {
        for (const [key, value] of Object.entries(payload)) {
            const raw = toObject(value);
            if (!raw || !isClaudeOAuthUsageWindowCandidate(key, raw))
                continue;
            const window = normalizeRestriction(raw, key, 'percent');
            if (window)
                windows.push(window);
        }
    }
    const seen = new Set();
    const unique = [];
    for (const window of windows) {
        const key = `${window.rateLimitType}:${window.resetAt ?? ''}:${window.status}`;
        if (seen.has(key))
            continue;
        seen.add(key);
        unique.push(window);
    }
    return unique.sort((a, b) => a.rateLimitType.localeCompare(b.rateLimitType));
}
exports.buildClaudeQuotaWindows = buildClaudeQuotaWindows;
"""


class CCSClaudeScopedQuotaPatchTests(unittest.TestCase):
    def make_subject(
        self, root: pathlib.Path, version: str = PATCHER.PINNED_CCS_VERSION
    ) -> tuple[pathlib.Path, pathlib.Path]:
        package = root / "ccs"
        target = package / PATCHER.TARGET_RELATIVE_PATH
        target.parent.mkdir(parents=True)
        (package / "package.json").write_text(json.dumps({"version": version}))
        target.write_text(SYNTHETIC_NORMALIZER)
        return package, target

    def run_normalizer(self, target: pathlib.Path, payload: dict) -> list[dict]:
        script = (
            "const m=require(process.argv[1]);"
            "const p=JSON.parse(process.argv[2]);"
            "process.stdout.write(JSON.stringify(m.buildClaudeQuotaWindows(p)));"
        )
        completed = subprocess.run(
            ["node", "-e", script, str(target), json.dumps(payload)],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(completed.stdout)

    def test_installs_exact_postimage_and_surfaces_fable_idempotently(self):
        payload = {
            "five_hour": {
                "utilization": 1,
                "resets_at": "2026-07-25T16:20:00Z",
            },
            "seven_day": {
                "utilization": 2,
                "resets_at": "2026-07-26T10:00:00Z",
            },
            "limits": [
                {
                    "kind": "session",
                    "group": "session",
                    "percent": 48,
                    "resets_at": "2026-07-25T16:20:00Z",
                    "scope": None,
                },
                {
                    "kind": "weekly_all",
                    "group": "weekly",
                    "percent": 93,
                    "resets_at": "2026-07-26T10:00:00Z",
                    "scope": None,
                },
                {
                    "kind": "weekly_scoped",
                    "group": "weekly",
                    "percent": 100,
                    "resets_at": "2026-07-26T10:00:00Z",
                    "scope": {
                        "model": {"id": None, "display_name": "Fable"},
                        "surface": None,
                    },
                },
            ],
        }
        with tempfile.TemporaryDirectory() as raw_temp:
            package, target = self.make_subject(pathlib.Path(raw_temp))

            self.assertTrue(PATCHER.patch_package(package, check=False))
            self.assertFalse(PATCHER.patch_package(package, check=False))
            self.assertFalse(PATCHER.patch_package(package, check=True))

            windows = self.run_normalizer(target, payload)
            by_type = {window["rateLimitType"]: window for window in windows}
            self.assertEqual(set(by_type), {"five_hour", "seven_day", "model:fable"})
            self.assertEqual(by_type["five_hour"]["remainingPercent"], 52)
            self.assertEqual(by_type["seven_day"]["remainingPercent"], 7)
            self.assertEqual(by_type["model:fable"]["remainingPercent"], 0)
            self.assertEqual(
                by_type["model:fable"]["label"], "Weekly usage (Fable)"
            )
            self.assertEqual(target.read_text().count(PATCHER.PATCH_MARKER), 1)

    def test_preserves_zero_percent_scoped_window_without_fake_reset(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            package, target = self.make_subject(pathlib.Path(raw_temp))
            PATCHER.patch_package(package, check=False)

            windows = self.run_normalizer(
                target,
                {
                    "limits": [
                        {
                            "kind": "weekly_scoped",
                            "group": "weekly",
                            "percent": 0,
                            "resets_at": None,
                            "scope": {
                                "model": {
                                    "id": None,
                                    "display_name": "Fable",
                                }
                            },
                        }
                    ]
                },
            )

            self.assertEqual(len(windows), 1)
            self.assertEqual(windows[0]["rateLimitType"], "model:fable")
            self.assertEqual(windows[0]["remainingPercent"], 100)
            self.assertIsNone(windows[0]["resetAt"])

    def test_legacy_top_level_fallback_remains_compatible(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            package, target = self.make_subject(pathlib.Path(raw_temp))
            PATCHER.patch_package(package, check=False)

            windows = self.run_normalizer(
                target,
                {
                    "five_hour": {
                        "utilization": 25,
                        "resets_at": "2026-07-25T16:20:00Z",
                    },
                    "seven_day": {
                        "utilization": 40,
                        "resets_at": "2026-07-26T10:00:00Z",
                    },
                },
            )

            by_type = {window["rateLimitType"]: window for window in windows}
            self.assertEqual(by_type["five_hour"]["remainingPercent"], 75)
            self.assertEqual(by_type["seven_day"]["remainingPercent"], 60)

    def test_refuses_wrong_version_anchor_drift_and_partial_marker(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            package, target = self.make_subject(root, version="8.8.2")
            before = target.read_bytes()
            with self.assertRaises(PATCHER.PatchRefused):
                PATCHER.patch_package(package, check=False)
            self.assertEqual(target.read_bytes(), before)

            (package / "package.json").write_text(
                json.dumps({"version": PATCHER.PINNED_CCS_VERSION})
            )
            target.write_text(SYNTHETIC_NORMALIZER.replace("const windows = [];", "const windows=[];"))
            with self.assertRaises(PATCHER.PatchRefused):
                PATCHER.patch_package(package, check=False)

            target.write_text(f"// {PATCHER.PATCH_MARKER}\n{SYNTHETIC_NORMALIZER}")
            with self.assertRaises(PATCHER.PatchRefused):
                PATCHER.patch_package(package, check=False)

    def test_rollback_is_exact_and_refuses_postimage_drift(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            package, target = self.make_subject(pathlib.Path(raw_temp))
            preimage = target.read_bytes()
            PATCHER.patch_package(package, check=False)
            self.assertTrue(PATCHER.restore_package(package))
            self.assertEqual(target.read_bytes(), preimage)
            self.assertFalse(PATCHER.restore_package(package))

            PATCHER.patch_package(package, check=False)
            target.write_text(target.read_text().replace("Weekly usage", "Weekly quota"))
            with self.assertRaises(PATCHER.PatchRefused):
                PATCHER.restore_package(package)

    def test_atomic_rewrite_preserves_mode(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            package, target = self.make_subject(pathlib.Path(raw_temp))
            os.chmod(target, 0o640)
            PATCHER.patch_package(package, check=False)
            self.assertEqual(target.stat().st_mode & 0o777, 0o640)


if __name__ == "__main__":
    unittest.main()
