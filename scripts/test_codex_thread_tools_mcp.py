#!/usr/bin/env python3
import asyncio
import importlib.util
import json
import pathlib
import sys
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


if __name__ == "__main__":
    unittest.main()
