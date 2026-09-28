#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "clodex-credential-helper.py"
MANAGED_ACCOUNT = (
    "oauth:provider:openai-oauth::credential::v1:"
    "0123456789abcdef0123456789abcdef"
)


class ClodexCredentialHelperTests(unittest.TestCase):
    def make_tools(self, root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
        age_keygen = root / "age-keygen"
        age_keygen.write_text(
            """#!/usr/bin/env python3
import pathlib
import sys
if sys.argv[1] == "-o":
    pathlib.Path(sys.argv[2]).write_text("AGE-SECRET-KEY-TEST\\n")
elif sys.argv[1] == "-y":
    print("age1synthetic")
else:
    raise SystemExit(2)
"""
        )
        age_keygen.chmod(0o755)
        age = root / "age"
        age.write_text(
            """#!/usr/bin/env python3
import pathlib
import sys
if "--encrypt" in sys.argv:
    output = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])
    output.write_bytes(b"AGE-SYNTHETIC:" + sys.stdin.buffer.read()[::-1])
elif "--decrypt" in sys.argv:
    value = sys.stdin.buffer.read()
    if not value.startswith(b"AGE-SYNTHETIC:"):
        raise SystemExit(1)
    sys.stdout.buffer.write(value[len(b"AGE-SYNTHETIC:"):][::-1])
else:
    raise SystemExit(2)
"""
        )
        age.chmod(0o755)
        return age, age_keygen

    def env(self, root: pathlib.Path) -> dict:
        tools = root / "tools"
        tools.mkdir()
        age, age_keygen = self.make_tools(tools)
        return {
            **os.environ,
            "CLODEX_CREDENTIAL_HELPER_TESTING": "1",
            "CLODEX_CREDENTIAL_STORE_ROOT": str(root / "store"),
            "CLODEX_AGE_BIN": str(age),
            "CLODEX_AGE_KEYGEN_BIN": str(age_keygen),
            "CLODEX_CODEXSWITCH_HOME": str(root / "home"),
        }

    def jwt(self, label: str, expires_in: int = 3600) -> str:
        def encoded(value: dict) -> str:
            raw = json.dumps(value, separators=(",", ":")).encode()
            return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

        return f"{encoded({'alg': 'none'})}.{encoded({'exp': int(time.time()) + expires_in, 'label': label})}.synthetic"

    def write_codexswitch_state(
        self,
        root: pathlib.Path,
        *,
        label: str = "first",
        activation_state: str = "confirmed",
        auth_access: str | None = None,
        auth_account_id: str | None = None,
    ) -> dict:
        home = root / "home"
        codexswitch = home / ".codexswitch"
        codex = home / ".codex"
        home.mkdir(mode=0o700)
        codexswitch.mkdir(mode=0o700)
        codex.mkdir(mode=0o700)
        access = self.jwt(label)
        account = {
            "id": f"synthetic-{label}",
            "email": f"{label}@example.invalid",
            "accessToken": access,
            "refreshToken": f"refresh-{label}",
            "idToken": f"id-{label}",
            "accountId": f"account-{label}",
            "isActive": True,
        }
        accounts_raw = json.dumps([account], indent=2).encode()
        accounts = codexswitch / "accounts.json"
        accounts.write_bytes(accounts_raw)
        accounts.chmod(0o600)
        lock = codexswitch / "accounts.json.lock"
        lock.write_bytes(b"")
        lock.chmod(0o600)
        activation = codexswitch / "accounts.activation.json"
        activation.write_text(
            json.dumps(
                {
                    "version": 3,
                    "state": activation_state,
                    "kind": "rotation",
                    "targetAccountId": account["accountId"],
                    "storeGeneration": hashlib.sha256(accounts_raw).hexdigest(),
                }
            )
        )
        activation.chmod(0o600)
        auth = codex / "auth.json"
        auth.write_text(
            json.dumps(
                {
                    "auth_mode": "chatgpt",
                    "tokens": {
                        "access_token": auth_access or access,
                        "refresh_token": account["refreshToken"],
                        "id_token": account["idToken"],
                        "account_id": auth_account_id or account["accountId"],
                    },
                }
            )
        )
        auth.chmod(0o600)
        return account

    def invoke(
        self, env: dict, operation: str, account: str, value: bytes = b""
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(HELPER), operation, "clodex", account],
            input=value,
            capture_output=True,
            env=env,
        )

    def test_exact_roundtrip_encrypts_at_rest_and_delete_is_idempotent(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            env = self.env(root)
            value = b'{"access":"synthetic-token","refresh":"synthetic-refresh"}'

            saved = self.invoke(env, "set", "oauth:test", value)
            self.assertEqual(saved.returncode, 0, saved.stderr)
            loaded = self.invoke(env, "get", "oauth:test")
            self.assertEqual(loaded.returncode, 0, loaded.stderr)
            self.assertEqual(loaded.stdout, value)

            objects = list((root / "store" / "objects").glob("*.age"))
            self.assertEqual(len(objects), 1)
            self.assertNotIn(value, objects[0].read_bytes())
            self.assertEqual(objects[0].stat().st_mode & 0o777, 0o600)
            self.assertEqual((root / "store" / "identity.txt").stat().st_mode & 0o777, 0o600)

            removed = self.invoke(env, "delete", "oauth:test")
            self.assertEqual(removed.returncode, 0, removed.stderr)
            missing = self.invoke(env, "get", "oauth:test")
            self.assertEqual(missing.returncode, 2)

    def test_competing_writers_leave_one_complete_value(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            env = self.env(root)
            values = [f"synthetic-{index}".encode() for index in range(8)]
            writers = [
                subprocess.Popen(
                    [str(HELPER), "set", "clodex", "oauth:shared"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=env,
                )
                for _ in values
            ]
            for writer, value in zip(writers, values):
                assert writer.stdin is not None
                writer.stdin.write(value)
                writer.stdin.close()
            for writer in writers:
                writer.wait(timeout=10)
                self.assertEqual(writer.returncode, 0)
                assert writer.stdout is not None
                assert writer.stderr is not None
                writer.stdout.close()
                writer.stderr.close()

            loaded = self.invoke(env, "get", "oauth:shared")
            self.assertEqual(loaded.returncode, 0, loaded.stderr)
            self.assertIn(loaded.stdout, values)

    def test_rejects_foreign_service_and_broad_directory_mode(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            env = self.env(root)
            foreign = subprocess.run(
                [str(HELPER), "set", "other", "account"],
                input=b"synthetic",
                capture_output=True,
                env=env,
            )
            self.assertEqual(foreign.returncode, 1)

            store = root / "store"
            store.chmod(0o755)
            refused = self.invoke(env, "set", "oauth:test", b"synthetic")
            self.assertEqual(refused.returncode, 1)

    def test_managed_account_reads_current_committed_codexswitch_tokens_without_copy(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            env = self.env(root)
            first = self.write_codexswitch_state(root, label="first")

            loaded = self.invoke(env, "get", MANAGED_ACCOUNT)
            self.assertEqual(loaded.returncode, 0, loaded.stderr)
            credential = json.loads(loaded.stdout)
            self.assertEqual(credential["access"], first["accessToken"])
            self.assertEqual(credential["refresh"], first["refreshToken"])
            self.assertEqual(credential["accountId"], first["accountId"])
            self.assertEqual(
                credential["providerData"],
                {"credentialOwner": "codexswitch", "bridgeVersion": 1},
            )
            self.assertGreater(credential["expires"], int(time.time() * 1000))
            self.assertFalse((root / "store").exists())

            second_root = root / "second-state"
            second_root.mkdir()
            second = self.write_codexswitch_state(second_root, label="second")
            source = second_root / "home"
            target = root / "home"
            for relative in (
                ".codexswitch/accounts.json",
                ".codexswitch/accounts.activation.json",
                ".codex/auth.json",
            ):
                os.replace(source / relative, target / relative)

            reloaded = self.invoke(env, "get", MANAGED_ACCOUNT)
            self.assertEqual(reloaded.returncode, 0, reloaded.stderr)
            current = json.loads(reloaded.stdout)
            self.assertEqual(current["access"], second["accessToken"])
            self.assertNotEqual(current["access"], first["accessToken"])

    def test_managed_account_refuses_mutation_and_ambiguous_state(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            env = self.env(root)
            account = self.write_codexswitch_state(root, activation_state="prepared")
            for operation in ("set", "delete"):
                result = self.invoke(env, operation, MANAGED_ACCOUNT, b"replacement")
                self.assertEqual(result.returncode, 1)
            prepared = self.invoke(env, "get", MANAGED_ACCOUNT)
            self.assertEqual(prepared.returncode, 1)

            activation = root / "home/.codexswitch/accounts.activation.json"
            record = json.loads(activation.read_text())
            record["state"] = "confirmed"
            activation.write_text(json.dumps(record))
            activation.chmod(0o600)
            auth = root / "home/.codex/auth.json"
            auth_data = json.loads(auth.read_text())
            auth_data["tokens"]["account_id"] = "different-account"
            auth.write_text(json.dumps(auth_data))
            auth.chmod(0o600)
            mismatch = self.invoke(env, "get", MANAGED_ACCOUNT)
            self.assertEqual(mismatch.returncode, 1)
            self.assertNotIn(account["accessToken"].encode(), mismatch.stdout)

    def test_managed_account_accepts_newer_codex_runtime_token_generation(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            env = self.env(root)
            runtime_access = self.jwt("runtime-refreshed")
            account = self.write_codexswitch_state(
                root,
                auth_access=runtime_access,
            )
            auth = root / "home/.codex/auth.json"
            auth_data = json.loads(auth.read_text())
            auth_data["tokens"]["refresh_token"] = "runtime-refresh"
            auth_data["tokens"]["id_token"] = "runtime-id"
            auth.write_text(json.dumps(auth_data))
            auth.chmod(0o600)

            loaded = self.invoke(env, "get", MANAGED_ACCOUNT)
            self.assertEqual(loaded.returncode, 0, loaded.stderr)
            credential = json.loads(loaded.stdout)
            self.assertEqual(credential["access"], runtime_access)
            self.assertEqual(credential["refresh"], "runtime-refresh")
            self.assertEqual(credential["accountId"], account["accountId"])

    def test_managed_account_refuses_symlinked_state_path(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            env = self.env(root)
            self.write_codexswitch_state(root)
            accounts = root / "home/.codexswitch/accounts.json"
            replacement = root / "home/.codexswitch/accounts.real"
            accounts.rename(replacement)
            accounts.symlink_to(replacement)

            refused = self.invoke(env, "get", MANAGED_ACCOUNT)
            self.assertEqual(refused.returncode, 1)
            self.assertEqual(refused.stdout, b"")


if __name__ == "__main__":
    unittest.main()
