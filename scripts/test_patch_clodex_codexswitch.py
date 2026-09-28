#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PATCHER = ROOT / "scripts" / "patch-clodex-codexswitch.py"
SPEC = importlib.util.spec_from_file_location("clodex_patcher", PATCHER)
assert SPEC and SPEC.loader
PATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCH)


class ClodexCodexSwitchPatcherTests(unittest.TestCase):
    def fixture(self, root: pathlib.Path, version: str = PATCH.PINNED_VERSION) -> pathlib.Path:
        package = root / "package"
        dist = package / "dist"
        dist.mkdir(parents=True)
        (package / "package.json").write_text(
            json.dumps({"name": "@bman654/clodex", "version": version})
        )
        prefix = b"#!/usr/bin/env node\nsynthetic-prefix\n"
        suffix = b"synthetic-suffix\n"
        cli = (
            prefix
            + PATCH.ORIGINAL
            + b"\nsynthetic-middle-a\n"
            + PATCH.PASSTHROUGH_TRANSPORT_ORIGINAL
            + b"\nsynthetic-middle-b\n"
            + PATCH.PASSTHROUGH_OPTIONS_ORIGINAL
            + suffix
        )
        # The production hash is intentionally frozen. Tests use the exact
        # production preimage by overriding only the imported module constants.
        PATCH.EXPECTED_ORIGINAL_SHA256 = hashlib.sha256(cli).hexdigest()
        PATCH.EXPECTED_PATCHED_SHA256 = hashlib.sha256(
            prefix
            + PATCH.PATCHED
            + b"\nsynthetic-middle-a\n"
            + PATCH.PASSTHROUGH_TRANSPORT_PATCHED
            + b"\nsynthetic-middle-b\n"
            + PATCH.PASSTHROUGH_OPTIONS_PATCHED
            + suffix
        ).hexdigest()
        PATCH.EXPECTED_LEGACY_PATCHED_SHA256 = hashlib.sha256(
            prefix
            + PATCH.PATCHED
            + b"\nsynthetic-middle-a\n"
            + PATCH.PASSTHROUGH_TRANSPORT_ORIGINAL
            + b"\nsynthetic-middle-b\n"
            + PATCH.PASSTHROUGH_OPTIONS_ORIGINAL
            + suffix
        ).hexdigest()
        (dist / "cli.js").write_bytes(cli)
        (dist / "cli.js").chmod(0o755)
        return package

    def test_apply_is_exact_idempotent_and_restorable(self):
        with tempfile.TemporaryDirectory() as raw:
            package = self.fixture(pathlib.Path(raw))
            cli = package / "dist/cli.js"
            self.assertEqual(PATCH.apply_patch(cli), "patched")
            self.assertEqual(hashlib.sha256(cli.read_bytes()).hexdigest(), PATCH.EXPECTED_PATCHED_SHA256)
            self.assertEqual(cli.read_bytes().count(PATCH.MARKER), 1)
            self.assertEqual(
                cli.read_bytes().count(PATCH.CCS_PASSTHROUGH_MARKER),
                2,
            )
            self.assertEqual(PATCH.apply_patch(cli), "already-patched")
            self.assertEqual(PATCH.check_patch(cli), "ready")
            self.assertEqual(PATCH.restore_patch(cli), "restored")
            self.assertEqual(hashlib.sha256(cli.read_bytes()).hexdigest(), PATCH.EXPECTED_ORIGINAL_SHA256)

    def test_legacy_managed_oauth_postimage_upgrades_to_ccs_passthrough(self):
        with tempfile.TemporaryDirectory() as raw:
            package = self.fixture(pathlib.Path(raw))
            cli = package / "dist/cli.js"
            legacy = cli.read_bytes().replace(PATCH.ORIGINAL, PATCH.PATCHED)
            self.assertEqual(
                hashlib.sha256(legacy).hexdigest(),
                PATCH.EXPECTED_LEGACY_PATCHED_SHA256,
            )
            cli.write_bytes(legacy)

            self.assertEqual(PATCH.apply_patch(cli), "upgraded")
            self.assertEqual(PATCH.check_patch(cli), "ready")
            self.assertEqual(
                hashlib.sha256(cli.read_bytes()).hexdigest(),
                PATCH.EXPECTED_PATCHED_SHA256,
            )

    def test_marker_with_mutated_postimage_refuses(self):
        with tempfile.TemporaryDirectory() as raw:
            package = self.fixture(pathlib.Path(raw))
            cli = package / "dist/cli.js"
            PATCH.apply_patch(cli)
            cli.write_bytes(cli.read_bytes() + b"drift")
            with self.assertRaises(PATCH.PatchError):
                PATCH.check_patch(cli)
            with self.assertRaises(PATCH.PatchError):
                PATCH.apply_patch(cli)

    def test_unknown_preimage_and_wrong_version_refuse(self):
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            package = self.fixture(root)
            cli = package / "dist/cli.js"
            cli.write_bytes(b"unknown")
            with self.assertRaises(PATCH.PatchError):
                PATCH.apply_patch(cli)

            (package / "package.json").write_text(
                json.dumps({"name": "@bman654/clodex", "version": "9.9.9"})
            )
            with self.assertRaises(PATCH.PatchError):
                PATCH.verify_package_root(package)

    def test_checked_in_production_hashes_match_pinned_npm_preimage_when_available(self):
        package = pathlib.Path("/tmp/clodex-inspect/package")
        if not package.exists():
            self.skipTest("pinned npm inspection fixture is absent")
        cli = PATCH.verify_package_root(package)
        data = cli.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), "61f6113b06507533ebe7714ff5ba66df6252332ca1b4f2fe0bd6922ccb4398c9")
        self.assertEqual(data.count(PATCH.ORIGINAL), 1)
        self.assertEqual(data.count(PATCH.PASSTHROUGH_TRANSPORT_ORIGINAL), 1)
        self.assertEqual(data.count(PATCH.PASSTHROUGH_OPTIONS_ORIGINAL), 1)
        patched = (
            data.replace(PATCH.ORIGINAL, PATCH.PATCHED)
            .replace(
                PATCH.PASSTHROUGH_TRANSPORT_ORIGINAL,
                PATCH.PASSTHROUGH_TRANSPORT_PATCHED,
            )
            .replace(
                PATCH.PASSTHROUGH_OPTIONS_ORIGINAL,
                PATCH.PASSTHROUGH_OPTIONS_PATCHED,
            )
        )
        self.assertEqual(
            hashlib.sha256(patched).hexdigest(),
            "d5c13c2321edd14aec557e79d31a75a1f9efc4b80d43de4f5223403e2b2bf81f",
        )


if __name__ == "__main__":
    unittest.main()
