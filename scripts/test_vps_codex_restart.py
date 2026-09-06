import argparse
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

SCRIPT = Path(__file__).with_name("vps-codex-restart.py")
SPEC = importlib.util.spec_from_file_location("vps_restart", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
DIGEST = "a" * 64
OLD = {"pid": 123, "processStart": "456"}
NEW = {"pid": 789, "processStart": "1011"}


class RestartValidationTests(unittest.TestCase):
    def test_only_exact_unix_server_modes_are_allowed(self):
        self.assertTrue(MODULE.allowed_argv([b"codex", b"app-server", b"--listen", b"unix://"]))
        self.assertTrue(MODULE.allowed_argv([b"codex", b"-c", b"features.code_mode_host=true",
                                            b"app-server", b"--remote-control", b"--listen", b"unix://"]))
        for suffix in [
            [b"app-server", b"proxy"], [b"app-server", b"daemon", b"start"],
            [b"app-server", b"--listen", b"ws://127.0.0.1:8390"],
            [b"app-server", b"--listen", b"unix:///other.sock"],
            [b"app-server", b"--listen", b"unix://", b"extra"],
            [b"exec", b"app-server", b"--listen", b"unix://"],
        ]:
            with self.subTest(suffix=suffix):
                self.assertFalse(MODULE.allowed_argv([b"codex", *suffix]))

    def test_invalid_config_never_exposes_its_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "config.toml").write_text('secret = "do-not-echo\n')
            with self.assertRaises(MODULE.Blocked) as error:
                MODULE.config_digest(root)
            self.assertNotIn("do-not-echo", str(error.exception))
            (root / "config.toml").write_text('model = "example"\n')
            digest = MODULE.config_digest(root)
            self.assertEqual(len(digest), 64)

    def test_symlink_config_is_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.toml"
            target.write_text('model = "example"\n')
            (root / "config.toml").symlink_to(target)
            with self.assertRaises(OSError):
                MODULE.config_digest(root)

    def test_current_executable_and_start_time_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = root / "123"
            process.mkdir()
            runtime = root / "runtime"
            runtime.write_text("fixture")
            (process / "exe").symlink_to(runtime)
            fields = ["S", *("0" for _ in range(18)), "456"]
            (process / "stat").write_text("123 (name with spaces) " + " ".join(fields))
            (process / "cmdline").write_bytes(b"codex\0app-server\0--listen\0unix://\0")
            self.assertEqual(MODULE.process_identity(123, runtime, root), OLD)
            other = root / "other"
            other.write_text("not the same executable")
            with self.assertRaises(MODULE.Blocked):
                MODULE.process_identity(123, other, root)


class RestartLifecycleTests(unittest.IsolatedAsyncioTestCase):
    def args(self, restart=True):
        return argparse.Namespace(restart=restart, pid=123, process_start="456", config_digest=DIGEST)

    async def exercise(self, *, restart=True, error_at=None, plan=None, replacement=None):
        ws = AsyncMock()
        peer_ws = AsyncMock()
        replacement_ws = AsyncMock()
        connections = AsyncMock(side_effect=[(ws, OLD), (peer_ws, OLD), (replacement_ws, replacement or NEW)])
        idle = AsyncMock()
        config_read = AsyncMock(return_value={})
        waiting = AsyncMock()
        startup = AsyncMock(return_value={"appServerVersion": "0.153.2"})
        if error_at == "active":
            idle.side_effect = MODULE.Blocked("active work")
        if error_at == "config":
            config_read.side_effect = MODULE.Blocked("invalid config")
        if error_at == "stop":
            waiting.side_effect = MODULE.Uncertain("not stopped")
        if error_at == "startup":
            startup.side_effect = RuntimeError("secret diagnostic")
        if error_at == "replacement":
            connections.side_effect = [(ws, OLD), (peer_ws, OLD), MODULE.Blocked("replacement unverified")]
        if error_at == "peer":
            connections.side_effect = [(ws, OLD), (peer_ws, NEW)]
        identity = NEW if error_at == "identity" else OLD
        with (
            patch.object(MODULE, "acquire_lock", side_effect=lambda *a, **k: os.open(os.devnull, os.O_RDONLY)) as lock,
            patch.object(MODULE, "config_digest", return_value=DIGEST),
            patch.object(MODULE, "connect_owner", connections),
            patch.object(MODULE, "require_idle", idle),
            patch.object(MODULE, "rpc", config_read),
            patch.object(MODULE, "process_identity", return_value=identity),
            patch.object(MODULE, "wait_for_exit", waiting),
            patch.object(MODULE, "start_native", startup),
            patch.object(MODULE.os, "pidfd_open", side_effect=lambda pid: os.open(os.devnull, os.O_RDONLY), create=True),
            patch.object(MODULE.signal, "pidfd_send_signal", create=True) as send,
        ):
            try:
                result = await MODULE.run(plan or self.args(restart))
            except (MODULE.Blocked, MODULE.Uncertain) as error:
                result = error
            return result, send.call_args_list, startup.await_count, waiting.await_count, lock.call_args_list

    async def test_check_is_observational_and_returns_a_bound_plan(self):
        result, sent, started, waited, locks = await self.exercise(restart=False)
        self.assertEqual(result, {"schemaVersion": 1, "status": "ready", **OLD, "configDigest": DIGEST})
        self.assertEqual((sent, started, waited), ([], 0, 0))
        self.assertEqual(len(locks), 1)
        self.assertFalse(locks[0].kwargs["exclusive"])
        self.assertNotIn("create", locks[0].kwargs)

    async def test_confirmed_restart_uses_only_sigint_and_verifies_new_owner(self):
        result, sent, started, waited, locks = await self.exercise()
        self.assertEqual(result["status"], "restarted")
        self.assertEqual(result["pid"], NEW["pid"])
        self.assertEqual([call.args[1] for call in sent], [signal.SIGINT])
        self.assertEqual((started, waited), (1, 1))
        self.assertTrue(locks[1].kwargs["exclusive"])

    async def test_active_or_changed_owner_never_receives_a_signal(self):
        for error_at in ["active", "config", "identity", "peer"]:
            with self.subTest(error_at=error_at):
                result, sent, started, _, _ = await self.exercise(error_at=error_at)
                self.assertIsInstance(result, MODULE.Blocked)
                self.assertEqual((sent, started), ([], 0))

    async def test_stale_confirmation_never_receives_a_signal(self):
        for field, value in [("pid", 555), ("process_start", "999"), ("config_digest", "b" * 64)]:
            with self.subTest(field=field):
                args = self.args()
                setattr(args, field, value)
                result, sent, started, _, _ = await self.exercise(plan=args)
                self.assertIsInstance(result, MODULE.Blocked)
                self.assertEqual((sent, started), ([], 0))

    async def test_stop_timeout_never_force_kills_or_starts_another_server(self):
        result, sent, started, _, _ = await self.exercise(error_at="stop")
        self.assertIsInstance(result, MODULE.Uncertain)
        self.assertEqual([call.args[1] for call in sent], [signal.SIGINT])
        self.assertEqual(started, 0)

    async def test_post_signal_failures_are_unknown_not_rejected_or_retried(self):
        for error_at in ["startup", "replacement"]:
            with self.subTest(error_at=error_at):
                result, sent, started, _, _ = await self.exercise(error_at=error_at)
                self.assertIsInstance(result, MODULE.Uncertain)
                self.assertNotIn("secret diagnostic", str(result))
                self.assertEqual((len(sent), started), (1, 1))

    async def test_old_owner_is_not_success(self):
        result, _, _, _, _ = await self.exercise(replacement=OLD)
        self.assertIsInstance(result, MODULE.Uncertain)

    async def test_idle_check_paginates_and_refuses_unknown_work(self):
        responses = [
            {"data": ["one"], "nextCursor": "next"}, {"thread": {"status": {"type": "idle"}}},
            {"data": ["two"], "nextCursor": None}, {"thread": {"status": {"type": "active"}}},
        ]
        request = AsyncMock(side_effect=responses)
        with patch.object(MODULE, "rpc", request):
            with self.assertRaises(MODULE.Blocked):
                await MODULE.require_idle(AsyncMock())
        self.assertEqual([call.args[2] for call in request.await_args_list],
                         ["thread/loaded/list", "thread/read", "thread/loaded/list", "thread/read"])

    async def test_idle_check_rejects_malformed_and_repeating_pages(self):
        for responses in [[{}], [{"data": [12]}], [{"data": [], "nextCursor": "x"}] * 2]:
            with self.subTest(responses=responses), patch.object(MODULE, "rpc", AsyncMock(side_effect=responses)):
                with self.assertRaises(MODULE.Blocked):
                    await MODULE.require_idle(AsyncMock())

    async def test_native_start_handles_fragmented_json_and_never_calls_restart(self):
        process = AsyncMock()
        process.returncode = 0
        process.stdout.read.side_effect = [b'{"status":"started",', b'"appServerVersion":"0.153.2"}', b'']
        process.wait.return_value = 0
        create = AsyncMock(return_value=process)
        with patch.object(MODULE.asyncio, "create_subprocess_exec", create):
            result = await MODULE.start_native(Path("/runtime/codex"), Path("/codex-home"))
        self.assertEqual(result["appServerVersion"], "0.153.2")
        self.assertEqual(create.call_args.args, ("/runtime/codex", "app-server", "daemon", "start"))
        self.assertEqual(create.call_args.kwargs["env"]["CODEX_HOME"], "/codex-home")


if __name__ == "__main__":
    unittest.main()
