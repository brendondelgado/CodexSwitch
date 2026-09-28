#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIGURATOR = ROOT / "scripts" / "configure-clodex-codexswitch.mjs"


class ConfigureClodexCodexSwitchTests(unittest.TestCase):
    def fixture(self, root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, dict]:
        package = root / "package"
        dist = package / "dist"
        dist.mkdir(parents=True)
        (package / "package.json").write_text(
            json.dumps(
                {
                    "name": "@bman654/clodex",
                    "version": "2.1.3",
                    "type": "module",
                }
            )
        )
        cli = b"synthetic-patched-clodex"
        (dist / "cli.js").write_bytes(cli)
        (dist / "chunk-OVO6OUZG.js").write_text(
            """
import fs from 'node:fs';
const path = `${process.env.CLODEX_HOME}/providers.json`;
const configPath = `${process.env.CLODEX_HOME}/config.json`;
export function loadRegistryStrict() {
  if (!fs.existsSync(path)) return {schemaVersion: 1, providers: []};
  return JSON.parse(fs.readFileSync(path, 'utf8'));
}
export function saveRegistry(registry) {
  fs.mkdirSync(process.env.CLODEX_HOME, {recursive: true, mode: 0o700});
  fs.writeFileSync(path, JSON.stringify(registry, null, 2) + '\\n', {mode: 0o600});
}
export function loadPreferences() {
  if (!fs.existsSync(configPath)) return {};
  return JSON.parse(fs.readFileSync(configPath, 'utf8'));
}
export function savePreferences(preferences) {
  const current = loadPreferences();
  fs.mkdirSync(process.env.CLODEX_HOME, {recursive: true, mode: 0o700});
  fs.writeFileSync(configPath, JSON.stringify({...current, ...preferences}, null, 2) + '\\n', {mode: 0o600});
}
export async function withRegistryWriteLock(operation) { return operation(); }
"""
        )
        helper = root / "helper"
        helper.write_text(
            """#!/usr/bin/env python3
import json, os, sys, time
with open(os.environ["HELPER_LOG"], "a") as stream:
    stream.write(sys.argv[1] + "\\n")
if sys.argv[1] != "get":
    raise SystemExit(1)
print(json.dumps({
    "type": "oauth",
    "access": "synthetic-access",
    "refresh": "synthetic-refresh",
    "expires": int(time.time() * 1000) + 3600000,
    "accountId": "synthetic-account",
    "providerData": {"credentialOwner": "codexswitch", "bridgeVersion": 1}
}))
"""
        )
        helper.chmod(0o700)
        clodex_home = root / "clodex-home"
        env = {
            **os.environ,
            "CLODEX_CODEXSWITCH_TESTING": "1",
            "CLODEX_CODEXSWITCH_TEST_CLI_SHA256": hashlib.sha256(cli).hexdigest(),
            "CLODEX_HOME": str(clodex_home),
            "HELPER_LOG": str(root / "helper.log"),
        }
        return package, helper, env

    def run_action(
        self,
        action: str,
        package: pathlib.Path,
        helper: pathlib.Path,
        env: dict,
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                "node",
                str(CONFIGURATOR),
                action,
                "--package-root",
                str(package),
                "--helper",
                str(helper),
            ],
            capture_output=True,
            text=True,
            env=env,
        )

    def test_configure_check_and_remove_are_metadata_only(self):
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            package, helper, env = self.fixture(root)
            configured = self.run_action("--configure", package, helper, env)
            self.assertEqual(configured.returncode, 0, configured.stderr)
            registry_path = pathlib.Path(env["CLODEX_HOME"]) / "providers.json"
            registry = json.loads(registry_path.read_text())
            self.assertEqual(len(registry["providers"]), 1)
            provider = registry["providers"][0]
            self.assertEqual(provider["id"], "openai-oauth")
            self.assertEqual(provider["authType"], "oauth")
            self.assertIn("oauth:provider:openai-oauth::credential::v1:", provider["authRef"])
            self.assertNotIn("synthetic-access", registry_path.read_text())
            self.assertNotIn("synthetic-refresh", registry_path.read_text())

            provider["modelsCache"] = {
                "fetchedAt": "synthetic",
                "models": [
                    {"id": "gpt-synthetic", "name": "GPT Synthetic"},
                    {"id": "gpt-synthetic-2", "name": "GPT Synthetic 2"},
                ],
            }
            registry_path.write_text(json.dumps(registry))
            reconfigured = self.run_action("--configure", package, helper, env)
            self.assertEqual(reconfigured.returncode, 0, reconfigured.stderr)

            checked = self.run_action("--check", package, helper, env)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertIn("ready provider=openai-oauth", checked.stdout)
            self.assertIn("favorites=2", checked.stdout)
            self.assertIn("aliases=2", checked.stdout)
            config = json.loads(
                (pathlib.Path(env["CLODEX_HOME"]) / "config.json").read_text()
            )
            self.assertEqual(
                config["favoriteModels"],
                [
                    {"providerId": "openai-oauth", "modelId": "gpt-synthetic"},
                    {"providerId": "openai-oauth", "modelId": "gpt-synthetic-2"},
                ],
            )
            self.assertEqual(
                config["modelAliases"],
                [
                    {
                        "name": "cs-gpt-synthetic",
                        "providerId": "openai-oauth",
                        "modelId": "gpt-synthetic",
                    },
                    {
                        "name": "cs-gpt-synthetic-2",
                        "providerId": "openai-oauth",
                        "modelId": "gpt-synthetic-2",
                    },
                ],
            )
            self.assertEqual(
                (root / "helper.log").read_text().splitlines(),
                ["get", "get", "get"],
            )

            removed = self.run_action("--unconfigure", package, helper, env)
            self.assertEqual(removed.returncode, 0, removed.stderr)
            self.assertEqual(json.loads(registry_path.read_text())["providers"], [])
            self.assertEqual(
                json.loads(
                    (pathlib.Path(env["CLODEX_HOME"]) / "config.json").read_text()
                )["favoriteModels"],
                [],
            )
            self.assertEqual(
                json.loads(
                    (pathlib.Path(env["CLODEX_HOME"]) / "config.json").read_text()
                )["modelAliases"],
                [],
            )
            self.assertEqual(
                (root / "helper.log").read_text().splitlines(),
                ["get", "get", "get"],
            )

    def test_existing_foreign_provider_and_postimage_drift_refuse(self):
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            package, helper, env = self.fixture(root)
            clodex_home = pathlib.Path(env["CLODEX_HOME"])
            clodex_home.mkdir(mode=0o700)
            (clodex_home / "providers.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "providers": [
                            {
                                "id": "openai-oauth",
                                "templateId": "openai",
                                "name": "foreign",
                                "enabled": True,
                                "authRef": "keyring:foreign",
                                "authType": "oauth",
                                "api": {},
                                "addedAt": "synthetic",
                            }
                        ],
                    }
                )
            )
            refused = self.run_action("--configure", package, helper, env)
            self.assertEqual(refused.returncode, 78)
            self.assertIn("refusing to replace", refused.stderr)

            (package / "dist/cli.js").write_bytes(b"drift")
            drift = self.run_action("--check", package, helper, env)
            self.assertEqual(drift.returncode, 78)
            self.assertIn("postimage is not exact", drift.stderr)

    def test_production_postimage_hash_tracks_ccs_passthrough_patch(self):
        text = CONFIGURATOR.read_text()
        self.assertIn(
            "d5c13c2321edd14aec557e79d31a75a1f9efc4b80d43de4f5223403e2b2bf81f",
            text,
        )
        self.assertNotIn(
            "867537210c5f9295ad2e8cbe99dde5f1430f7cb854cd530b734763ebac3dafb1",
            text,
        )


if __name__ == "__main__":
    unittest.main()
