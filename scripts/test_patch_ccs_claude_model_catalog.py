#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "patch-ccs-claude-model-catalog.py"
SPEC = importlib.util.spec_from_file_location("patch_ccs_catalog", SCRIPT)
assert SPEC and SPEC.loader
PATCHER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCHER)


class CCSClaudeModelCatalogPatchTests(unittest.TestCase):
    def make_subject(self, root: pathlib.Path, version: str = "8.8.1"):
        package = root / "ccs"
        catalog = package / "dist" / "cliproxy" / "model-catalog.js"
        catalog.parent.mkdir(parents=True)
        (package / "package.json").write_text(json.dumps({"version": version}))
        catalog.write_text(
            """const catalog = {
    claude: {
        provider: 'claude',
        displayName: 'Claude (Anthropic)',
        defaultModel: 'claude-sonnet-5',
        models: [
            {
                id: 'claude-sonnet-5',
            },
        ],
    },
};
"""
        )
        cache = root / "model-catalog-cache.json"
        cache.write_text(
            json.dumps(
                {
                    "fetchedAt": "synthetic",
                    "providers": {
                        "claude": [
                            {
                                "id": "claude-opus-4-8",
                                "display_name": "Claude Opus 4.8",
                            }
                        ]
                    },
                }
            )
        )
        return package, catalog, cache

    def test_installs_exact_package_and_cache_postimages_idempotently(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            package, catalog, cache = self.make_subject(root)

            self.assertTrue(PATCHER.patch_package(package, check=False))
            self.assertTrue(PATCHER.patch_cache(cache, check=False))
            self.assertFalse(PATCHER.patch_package(package, check=False))
            self.assertFalse(PATCHER.patch_cache(cache, check=False))
            self.assertFalse(PATCHER.patch_package(package, check=True))
            self.assertFalse(PATCHER.patch_cache(cache, check=True))

            text = catalog.read_text()
            self.assertEqual(text.count("id: 'claude-opus-5'"), 1)
            self.assertEqual(text.count(PATCHER.PATCH_MARKER), 1)
            models = json.loads(cache.read_text())["providers"]["claude"]
            self.assertEqual(
                [model["id"] for model in models].count("claude-opus-5"),
                1,
            )
            self.assertTrue(
                pathlib.Path(f"{catalog}.codexswitch-pre-opus5").is_file()
            )
            self.assertTrue(pathlib.Path(f"{cache}.codexswitch-pre-opus5").is_file())

    def test_refuses_wrong_ccs_version_without_writes(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            package, catalog, _ = self.make_subject(root, version="8.8.2")
            before = catalog.read_bytes()

            with self.assertRaises(PATCHER.PatchRefused):
                PATCHER.patch_package(package, check=False)

            self.assertEqual(catalog.read_bytes(), before)
            self.assertFalse(
                pathlib.Path(f"{catalog}.codexswitch-pre-opus5").exists()
            )

    def test_refuses_anchor_drift_and_disagreeing_cache_entry(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            package, catalog, cache = self.make_subject(root)
            catalog.write_text(catalog.read_text().replace("models: [", "models : ["))
            payload = json.loads(cache.read_text())
            payload["providers"]["claude"].insert(
                0, {"id": "claude-opus-5", "display_name": "wrong"}
            )
            cache.write_text(json.dumps(payload))

            with self.assertRaises(PATCHER.PatchRefused):
                PATCHER.patch_package(package, check=False)
            with self.assertRaises(PATCHER.PatchRefused):
                PATCHER.patch_cache(cache, check=False)

    def test_atomic_rewrite_preserves_mode(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            package, catalog, cache = self.make_subject(root)
            os.chmod(catalog, 0o640)
            os.chmod(cache, 0o660)

            PATCHER.patch_package(package, check=False)
            PATCHER.patch_cache(cache, check=False)

            self.assertEqual(catalog.stat().st_mode & 0o777, 0o640)
            self.assertEqual(cache.stat().st_mode & 0o777, 0o660)


if __name__ == "__main__":
    unittest.main()
