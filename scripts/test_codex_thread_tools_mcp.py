#!/usr/bin/env python3
import asyncio
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch


SCRIPT = pathlib.Path(__file__).with_name("codex-thread-tools-mcp.py")


class NotificationOnlyWebSocket:
    def __init__(self):
        self.sent = []
        self.recv_count = 0

    async def send(self, payload):
        self.sent.append(json.loads(payload))

    async def recv(self):
        self.recv_count += 1
        return json.dumps({"jsonrpc": "2.0", "method": "thread/status/changed", "params": {}})


def load_module():
    spec = importlib.util.spec_from_file_location("codex_thread_tools_mcp", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CodexThreadToolsMcpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_expected_tool_names_are_mapped(self):
        expected = {
            "list_threads": "thread/list",
            "read_thread": "thread/read",
            "create_thread": "thread/start",
            "fork_thread": "thread/fork",
            "send_message_to_thread": "turn/start",
            "set_thread_title": "thread/name/set",
            "set_thread_archived": "thread/archive-or-unarchive",
            "set_thread_pinned": "unsupported:no-native-app-server-pin-api",
            "archive_thread": "thread/archive",
            "unarchive_thread": "thread/unarchive",
            "unsubscribe_thread": "thread/unsubscribe",
            "handoff_thread": "synthetic:thread/start-or-fork+turn/start",
        }
        self.assertEqual(self.module.TOOL_RPC_METHODS, expected)

    def test_thread_list_defaults_include_non_interactive_sources(self):
        params = self.module.build_thread_list_params(
            limit=25,
            cursor=None,
            cwd=None,
            search_term=None,
            archived=False,
            sort_key="updated_at",
            sort_direction="desc",
            include_all_sources=True,
            use_state_db_only=False,
        )
        self.assertEqual(params["sourceKinds"], ["cli", "vscode", "appServer", "exec", "unknown"])
        self.assertEqual(params["sortKey"], "updated_at")
        self.assertEqual(params["archived"], False)

    def test_turn_start_uses_text_input_shape(self):
        params = self.module.build_turn_start_params(
            thread_id="thr_123",
            message="continue the work",
            cwd="/home/signul/SIGNUL",
            model="gpt-5.5",
            effort="xhigh",
            approval_policy="never",
            service_tier=None,
            client_user_message_id="client_msg_test",
        )
        self.assertEqual(params["threadId"], "thr_123")
        self.assertEqual(params["input"], [{"type": "text", "text": "continue the work"}])
        self.assertEqual(params["clientUserMessageId"], "client_msg_test")
        self.assertEqual(params["cwd"], "/home/signul/SIGNUL")
        self.assertNotIn("serviceTier", params)

    def test_empty_message_is_rejected(self):
        with self.assertRaises(ValueError):
            self.module.build_turn_start_params(
                thread_id="thr_123",
                message="  ",
                cwd=None,
                model=None,
                effort=None,
                approval_policy=None,
                service_tier=None,
            )

    def test_handoff_message_declares_synthetic_origin(self):
        message = self.module.build_handoff_message("thr_source", "Please pick this up.")
        self.assertIn("Synthetic Codex thread handoff from thr_source", message)
        self.assertTrue(message.endswith("Please pick this up."))

    def test_socket_follows_codex_home_not_account(self):
        with patch.object(self.module, "APP_SERVER_URL", "unix://"):
            with patch.dict(os.environ, {"CODEX_HOME": "/tmp/test-codex"}):
                self.assertEqual(self.module.desktop_socket_path(),
                                 "/tmp/test-codex/app-server-control/app-server-control.sock")
            with patch.dict(os.environ, {"CODEX_HOME": ""}):
                self.assertEqual(self.module.desktop_socket_path(), str(
                    pathlib.Path.home() / ".codex/app-server-control/app-server-control.sock"))

    def test_legacy_tcp_and_relative_routes_fail_closed(self):
        for url in ["ws://127.0.0.1:8390", "wss://example.test", "unix://relative", ""]:
            with self.subTest(url=url), patch.object(self.module, "APP_SERVER_URL", url):
                with self.assertRaises(ValueError):
                    self.module.desktop_socket_path()

    def test_sandbox_compatibility(self):
        self.assertIsNone(self.module.turn_sandbox_policy(None))
        self.assertEqual(self.module.turn_sandbox_policy("read-only"),
                         {"type": "readOnly", "networkAccess": False})
        with self.assertRaises(ValueError):
            self.module.turn_sandbox_policy("invalid")

    def test_thread_id_extraction_supports_hook_response(self):
        self.assertEqual(self.module.extract_thread_id({"thread": {"id": "thr_123"}}), "thr_123")
        self.assertEqual(self.module.extract_thread_id({"thread": {"sessionId": "thr_session"}}), "thr_session")
        self.assertIsNone(self.module.extract_thread_id({"thread": None}))


class CodexThreadToolsMcpProtocolTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def start_turn_kwargs(self):
        return {
            "thread_id": "thr_target",
            "message": "continue the work",
            "cwd": None,
            "model": None,
            "effort": None,
            "approval_policy": None,
            "service_tier": None,
            "wait_for_completion": False,
            "wait_timeout_sec": 30,
            "max_events": 100,
        }

    async def test_request_notifications_do_not_extend_absolute_deadline(self):
        ws = NotificationOnlyWebSocket()
        clock_values = iter([0.0, 0.0, 1.0, 2.0, 3.1])

        with self.assertRaisesRegex(asyncio.TimeoutError, "thread/read timed out after 3s"):
            await self.module._send_request(
                ws,
                2,
                "thread/read",
                {"threadId": "thr_target"},
                timeout_sec=3,
                _clock=lambda: next(clock_values),
            )

        self.assertEqual(ws.recv_count, 2)
        self.assertEqual(ws.sent[0]["method"], "thread/read")

    async def test_detached_turn_is_blocked_when_thread_read_reports_active(self):
        ws = AsyncMock()
        methods = []

        async def fake_request(_ws, _request_id, method, _params=None, **_kwargs):
            methods.append(method)
            if method == "thread/read":
                return {"thread": {"id": "thr_target", "status": {"type": "active"}}}
            self.fail(f"unexpected mutating request: {method}")

        with (
            patch.object(self.module, "_connect_initialized", AsyncMock(return_value=ws)),
            patch.object(self.module, "_send_request", new=AsyncMock(side_effect=fake_request)),
        ):
            with self.assertRaisesRegex(self.module.ActiveTurnError, "thread/read reports an active"):
                await self.module.start_turn(**self.start_turn_kwargs())

        self.assertEqual(methods, ["thread/read"])
        ws.close.assert_awaited_once()

    async def test_detached_turn_is_blocked_when_turns_list_reports_in_progress(self):
        ws = AsyncMock()
        methods = []

        async def fake_request(_ws, _request_id, method, _params=None, **_kwargs):
            methods.append(method)
            if method == "thread/read":
                return {"thread": {"id": "thr_target", "status": {"type": "notLoaded"}}}
            if method == "thread/turns/list":
                return {"data": [{"id": "turn_active", "status": "inProgress"}]}
            self.fail(f"unexpected mutating request: {method}")

        with (
            patch.object(self.module, "_connect_initialized", AsyncMock(return_value=ws)),
            patch.object(self.module, "_send_request", new=AsyncMock(side_effect=fake_request)),
        ):
            with self.assertRaisesRegex(self.module.ActiveTurnError, "thread/turns/list reports an active"):
                await self.module.start_turn(**self.start_turn_kwargs())

        self.assertEqual(methods, ["thread/read", "thread/turns/list"])
        ws.close.assert_awaited_once()

    async def test_detached_turn_starts_after_read_only_checks_report_idle(self):
        ws = AsyncMock()
        methods = []

        async def fake_request(_ws, _request_id, method, _params=None, **_kwargs):
            methods.append(method)
            if method == "thread/read":
                return {"thread": {"id": "thr_target", "status": {"type": "idle"}}}
            if method == "thread/turns/list":
                return {"data": [{"id": "turn_done", "status": "completed"}]}
            if method == "thread/resume":
                return {}
            if method == "turn/start":
                return {"turn": {"id": "turn_new", "status": "inProgress"}}
            self.fail(f"unexpected request: {method}")

        with (
            patch.object(self.module, "_connect_initialized", AsyncMock(return_value=ws)),
            patch.object(self.module, "_send_request", new=AsyncMock(side_effect=fake_request)),
        ):
            result = await self.module.start_turn(**self.start_turn_kwargs())

        self.assertEqual(
            methods,
            ["thread/read", "thread/turns/list", "thread/resume", "turn/start"],
        )
        self.assertTrue(result["detached"])
        ws.close.assert_awaited_once()

    async def test_thread_read_preflight_is_retained_when_turns_list_is_unsupported(self):
        ws = AsyncMock()
        methods = []

        async def fake_request(_ws, _request_id, method, _params=None, **_kwargs):
            methods.append(method)
            if method == "thread/read":
                return {"thread": {"id": "thr_target", "status": {"type": "idle"}}}
            if method == "thread/turns/list":
                raise self.module.AppServerRPCError(method, -32601, "method not found")
            if method == "thread/resume":
                return {}
            if method == "turn/start":
                return {"turn": {"id": "turn_new", "status": "inProgress"}}
            self.fail(f"unexpected request: {method}")

        with (
            patch.object(self.module, "_connect_initialized", AsyncMock(return_value=ws)),
            patch.object(self.module, "_send_request", new=AsyncMock(side_effect=fake_request)),
        ):
            result = await self.module.start_turn(**self.start_turn_kwargs())

        self.assertEqual(
            methods,
            ["thread/read", "thread/turns/list", "thread/resume", "turn/start"],
        )
        self.assertTrue(result["detached"])
        ws.close.assert_awaited_once()

    async def test_mcp_server_advertises_thread_tools(self):
        try:
            from mcp import ClientSession, StdioServerParameters
            from mcp.client.stdio import stdio_client
        except Exception as exc:  # pragma: no cover - dependency guard for lean systems
            self.skipTest(f"mcp client dependency unavailable: {exc}")

        server = StdioServerParameters(command=sys.executable, args=[str(SCRIPT)])
        async with stdio_client(server) as (read_stream, write_stream):
            async with ClientSession(read_stream, write_stream) as session:
                await session.initialize()
                tools = await session.list_tools()

        names = {tool.name for tool in tools.tools}
        self.assertTrue(set(self.module.TOOL_RPC_METHODS).issubset(names))

    async def test_missing_rollout_requires_live_idle_and_empty_turns(self):
        for status, turns, allowed in [
            ("idle", [], True), ("active", [], False),
            ("notLoaded", [], False), ("idle", [{"status": "completed"}], False),
            ("idle", None, False), ("idle", [{"status": "inProgress"}], False),
        ]:
            with self.subTest(status=status, turns=turns):
                ws = AsyncMock()
                methods = []

                async def fake(_ws, _id, method, params=None, **kwargs):
                    methods.append(method)
                    if method == "thread/read":
                        if params.get("includeTurns"):
                            return {"thread": {"status": {"type": status}, "turns": turns}}
                        return {"thread": {"status": {"type": "idle"}}}
                    if method == "thread/turns/list":
                        raise self.module.AppServerRPCError(method, -32600, "missing source rollout")
                    self.fail(f"mutating preflight: {method}")

                with patch.object(self.module, "_send_request", AsyncMock(side_effect=fake)):
                    if allowed:
                        await self.module.assert_thread_has_no_active_turn(ws, "new")
                    else:
                        with self.assertRaises((self.module.AppServerRPCError, self.module.ActiveTurnError)):
                            await self.module.assert_thread_has_no_active_turn(ws, "new")
                self.assertEqual(methods, ["thread/read", "thread/turns/list", "thread/read"])

    async def test_other_history_errors_fail_without_mutation(self):
        ws = AsyncMock()
        request = AsyncMock(side_effect=[
            {"thread": {"status": {"type": "idle"}}},
            self.module.AppServerRPCError("thread/turns/list", -32600, "history unavailable"),
        ])
        with patch.object(self.module, "_send_request", request):
            with self.assertRaises(self.module.AppServerRPCError):
                await self.module.assert_thread_has_no_active_turn(ws, "target")
        self.assertEqual(request.await_count, 2)

    async def test_lost_turn_start_response_is_not_retried(self):
        ws = AsyncMock()
        request = AsyncMock(side_effect=[
            {"thread": {"status": {"type": "idle"}}}, {"data": []},
            {}, ConnectionError("response lost after dispatch"),
        ])
        connect = AsyncMock(return_value=ws)
        with patch.object(self.module, "_connect_initialized", connect), patch.object(
            self.module, "_send_request", request
        ):
            with self.assertRaises(ConnectionError):
                await self.module.start_turn(**self.start_turn_kwargs())
        self.assertEqual([call.args[2] for call in request.await_args_list],
                         ["thread/read", "thread/turns/list", "thread/resume", "turn/start"])
        connect.assert_awaited_once()
        ws.close.assert_awaited_once()


class SharedOwnerSocketTests(unittest.IsolatedAsyncioTestCase):
    """Real transport fixture; task lifecycle is deliberately deterministic."""

    async def asyncSetUp(self):
        import fcntl
        from websockets.asyncio.server import unix_serve

        self.module = load_module()
        self.temp = tempfile.TemporaryDirectory(prefix="ctm-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.socket = str(pathlib.Path(self.temp.name) / "server.sock")
        self.lock_path = pathlib.Path(self.temp.name) / "writer.lock"
        self.writer = self.lock_path.open("w")
        self.addCleanup(self.writer.close)
        fcntl.flock(self.writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.active = False
        self.turn_count = 0
        self.methods = []
        self.subscribers = set()
        self.account_generation = 1
        self.reject_initialize = False
        self.connections = 0
        self.module.APP_SERVER_URL = "unix://" + self.socket
        self.server = await unix_serve(self.handle, self.socket)
        self.addAsyncCleanup(self.close_server)

    async def close_server(self):
        self.server.close()
        await self.server.wait_closed()

    async def handle(self, ws):
        self.connections += 1
        self.assertNotIn("Sec-WebSocket-Extensions", ws.request.headers)
        initialized = False
        try:
            async for raw in ws:
                request = json.loads(raw)
                method = request["method"]
                self.methods.append(method)
                if method == "initialized":
                    initialized = True
                    continue
                response = {"id": request["id"]}
                if method == "initialize":
                    if self.reject_initialize:
                        response["error"] = {"code": -1, "message": "fixture failure"}
                    else:
                        response["result"] = {"userAgent": "fixture"}
                elif not initialized:
                    response["error"] = {"code": -1, "message": "not initialized"}
                else:
                    result = {}
                    thread = {"id": "fixture-thread", "status": {
                        "type": "active" if self.active else "idle"}}
                    if method in {"thread/start", "thread/fork", "thread/resume"}:
                        self.subscribers.add(ws)
                        result = {"thread": thread}
                    elif method == "thread/read":
                        result = {"thread": thread, "generation": self.account_generation}
                    elif method == "thread/turns/list":
                        result = {"data": []}
                    elif method == "turn/start":
                        self.active = True
                        self.turn_count += 1
                        result = {"turn": {"id": f"turn-{self.turn_count}", "status": "inProgress"}}
                    elif method == "thread/unsubscribe":
                        self.subscribers.discard(ws)
                        result = {"status": "notSubscribed"}
                    response["result"] = result
                await ws.send(json.dumps(response))
        finally:
            self.subscribers.discard(ws)

    async def test_active_detach_desktop_progress_followup_and_auth_reconnect_share_owner(self):
        import fcntl

        created = await self.module.create_thread(initial_message="fixture only")
        self.assertEqual(created["threadId"], "fixture-thread")
        self.assertTrue(created["initialTurn"]["detached"])
        self.assertTrue(self.active)
        desktop = await self.module._connect_initialized()
        try:
            resumed = await self.module._send_request(desktop, 2, "thread/resume", {
                "threadId": created["threadId"]})
            self.assertEqual(resumed["thread"]["status"]["type"], "active")
            with self.lock_path.open("r+") as competing_writer:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(competing_writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for subscriber in list(self.subscribers):
                await subscriber.send(json.dumps({"method": "item/agentMessage/delta",
                                                 "params": {"delta": "progress"}}))
            event = json.loads(await asyncio.wait_for(desktop.recv(), 2))
            self.assertEqual(event["params"]["delta"], "progress")
            self.active = False
        finally:
            await desktop.close()
        self.account_generation = 2  # Simulated server auth reload, no endpoint change.
        read = await self.module.read_thread(created["threadId"])
        self.assertEqual(read["response"]["generation"], 2)
        sent = await self.module.send_message_to_thread(created["threadId"], "follow-up")
        self.assertTrue(sent["response"]["detached"])
        self.assertEqual(self.turn_count, 2)
        reconnected = await self.module._connect_initialized()
        try:
            resumed = await self.module._send_request(reconnected, 2, "thread/resume", {
                "threadId": created["threadId"]})
            self.assertEqual(resumed["thread"]["status"]["type"], "active")
        finally:
            await reconnected.close()

    async def test_unsubscribe_never_resumes_or_claims_writer_handoff(self):
        result = await self.module.unsubscribe_thread("fixture-thread")
        self.assertNotIn("thread/resume", self.methods)
        self.assertIn("does not transfer", result["note"])

    async def test_missing_socket_does_not_connect_tcp(self):
        self.module.APP_SERVER_URL += "-missing"
        with patch.object(self.module.websockets, "connect") as tcp:
            with self.assertRaisesRegex(RuntimeError, "no fallback server was started"):
                await self.module.create_thread()
            tcp.assert_not_called()
        self.assertEqual(self.connections, 0)

    async def test_initialization_error_is_not_retried_and_no_task_is_started(self):
        self.reject_initialize = True
        with self.assertRaises(self.module.AppServerRPCError):
            await self.module.create_thread()
        self.assertEqual(self.methods, ["initialize"])
        self.assertEqual(self.connections, 1)

    async def test_legacy_tcp_route_never_opens_a_connection(self):
        self.module.APP_SERVER_URL = "ws://127.0.0.1:8390"
        with patch.object(self.module.websockets, "connect") as tcp:
            with self.assertRaisesRegex(ValueError, "separate task owners"):
                await self.module.create_thread()
            tcp.assert_not_called()
        self.assertEqual(self.connections, 0)


if __name__ == "__main__":
    unittest.main()
