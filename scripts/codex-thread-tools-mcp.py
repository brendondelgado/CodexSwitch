#!/usr/bin/env python3
"""MCP tools that expose Codex app-server thread RPCs.

This server is intentionally thin: it registers model-callable tools with the
names Codex agents already look for, then maps them to the VPS app-server's
native JSON-RPC methods on 127.0.0.1:8390.
"""

from __future__ import annotations

import asyncio
import json
import os
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

import websockets
from mcp.server.fastmcp import FastMCP


APP_SERVER_URL = os.environ.get("CODEX_THREAD_TOOLS_APP_SERVER_URL", "ws://127.0.0.1:8390")
DEFAULT_CWD = os.environ.get("CODEX_THREAD_TOOLS_DEFAULT_CWD", "/home/signul/SIGNUL")
REQUEST_TIMEOUT_SEC = float(os.environ.get("CODEX_THREAD_TOOLS_TIMEOUT_SEC", "30"))

ALL_SOURCE_KINDS = ["cli", "vscode", "appServer", "exec", "unknown"]

TOOL_RPC_METHODS = {
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

mcp = FastMCP(
    "codex_app",
    instructions=(
        "Expose Codex app-server thread management tools on the SIGNUL VPS. "
        "Most tools map directly to app-server JSON-RPC methods; handoff_thread "
        "is synthetic and creates/forks a target thread before sending a message."
    ),
)


class AppServerRPCError(RuntimeError):
    def __init__(self, method: str, code: int | None, detail: Any) -> None:
        super().__init__(f"{method} failed: {detail}")
        self.method = method
        self.code = code
        self.detail = detail


class ActiveTurnError(RuntimeError):
    pass


def compact_dict(values: dict[str, Any]) -> dict[str, Any]:
    """Drop unset values while preserving false/zero/empty-list when explicit."""
    return {key: value for key, value in values.items() if value is not None}


def trim_result(result: Any, max_chars: int | None) -> Any:
    if not max_chars or max_chars <= 0:
        return result
    encoded = json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True)
    if len(encoded) <= max_chars:
        return result
    return {
        "truncated": True,
        "maxChars": max_chars,
        "jsonPrefix": encoded[:max_chars],
        "note": "Result was larger than max_chars. Re-run with a higher max_chars or narrower query.",
    }


def build_thread_list_params(
    *,
    limit: int,
    cursor: str | None,
    cwd: str | None,
    search_term: str | None,
    archived: bool | None,
    sort_key: str | None,
    sort_direction: str | None,
    include_all_sources: bool,
    use_state_db_only: bool,
) -> dict[str, Any]:
    return compact_dict(
        {
            "limit": limit,
            "cursor": cursor,
            "cwd": cwd,
            "searchTerm": search_term,
            "archived": archived,
            "sortKey": sort_key,
            "sortDirection": sort_direction,
            "sourceKinds": ALL_SOURCE_KINDS if include_all_sources else None,
            "useStateDbOnly": use_state_db_only,
        }
    )


def build_thread_start_params(
    *,
    cwd: str | None,
    model: str | None,
    approval_policy: str | None,
    sandbox: str | None,
    service_tier: str | None,
    ephemeral: bool | None,
) -> dict[str, Any]:
    return compact_dict(
        {
            "cwd": cwd or DEFAULT_CWD,
            "model": model,
            "approvalPolicy": approval_policy,
            "sandbox": sandbox,
            "serviceTier": service_tier,
            "ephemeral": ephemeral,
            "serviceName": "codex-thread-tools-mcp",
        }
    )


def build_turn_start_params(
    *,
    thread_id: str,
    message: str,
    cwd: str | None,
    model: str | None,
    effort: str | None,
    approval_policy: str | None,
    service_tier: str | None,
    client_user_message_id: str | None = None,
) -> dict[str, Any]:
    if not message.strip():
        raise ValueError("message must not be empty")
    return compact_dict(
        {
            "threadId": thread_id,
            "clientUserMessageId": client_user_message_id or f"codex-thread-tools-{uuid.uuid4()}",
            "input": [{"type": "text", "text": message}],
            "cwd": cwd,
            "model": model,
            "effort": effort,
            "approvalPolicy": approval_policy,
            "serviceTier": service_tier,
        }
    )


def build_handoff_message(source_thread_id: str | None, message: str) -> str:
    prefix = "Synthetic Codex thread handoff"
    if source_thread_id:
        prefix += f" from {source_thread_id}"
    return f"{prefix}:\n\n{message.strip()}"


def extract_thread_id(result: dict[str, Any]) -> str | None:
    thread = result.get("thread") or {}
    if not isinstance(thread, dict):
        return None
    return thread.get("id") or thread.get("sessionId")


def normalize_status(status: Any) -> str | None:
    if isinstance(status, dict):
        status = status.get("type") or status.get("status")
    if not isinstance(status, str):
        return None
    return "".join(character for character in status.lower() if character.isalnum())


def active_turn_evidence_from_thread_read(result: dict[str, Any]) -> dict[str, Any] | None:
    thread = result.get("thread")
    if not isinstance(thread, dict):
        return None
    status = normalize_status(thread.get("status"))
    if status in {"active", "inprogress", "running"}:
        return {"source": "thread/read", "threadStatus": thread.get("status")}
    return active_turn_evidence_from_turns(thread.get("turns"), source="thread/read")


def active_turn_evidence_from_turns(turns: Any, *, source: str) -> dict[str, Any] | None:
    if not isinstance(turns, list):
        return None
    for turn in turns:
        if not isinstance(turn, dict):
            continue
        if normalize_status(turn.get("status")) == "inprogress":
            return {"source": source, "turnId": turn.get("id"), "turnStatus": turn.get("status")}
    return None


async def _await_before_deadline(
    awaitable_factory: Callable[[], Awaitable[Any]],
    *,
    deadline: float,
    clock: Callable[[], float],
    method: str,
    timeout_sec: float,
) -> Any:
    remaining = deadline - clock()
    if remaining <= 0:
        raise asyncio.TimeoutError(f"{method} timed out after {timeout_sec:g}s")
    try:
        return await asyncio.wait_for(awaitable_factory(), timeout=remaining)
    except asyncio.TimeoutError as exc:
        raise asyncio.TimeoutError(f"{method} timed out after {timeout_sec:g}s") from exc


async def _send_request(
    ws: websockets.ClientConnection,
    request_id: int,
    method: str,
    params: dict[str, Any] | None = None,
    timeout_sec: float = REQUEST_TIMEOUT_SEC,
    _clock: Callable[[], float] | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        payload["params"] = params
    clock = _clock or asyncio.get_running_loop().time
    deadline = clock() + max(0.0, timeout_sec)
    await _await_before_deadline(
        lambda: ws.send(json.dumps(payload)),
        deadline=deadline,
        clock=clock,
        method=method,
        timeout_sec=timeout_sec,
    )
    while True:
        raw = await _await_before_deadline(
            ws.recv,
            deadline=deadline,
            clock=clock,
            method=method,
            timeout_sec=timeout_sec,
        )
        message = json.loads(raw)
        if message.get("id") != request_id:
            continue
        if "error" in message:
            error = message["error"]
            detail = error.get("message") if isinstance(error, dict) else error
            code = error.get("code") if isinstance(error, dict) else None
            raise AppServerRPCError(method, code, detail)
        result = message.get("result")
        return result if isinstance(result, dict) else {"result": result}


async def _connect_initialized() -> websockets.ClientConnection:
    ws = await websockets.connect(APP_SERVER_URL, max_size=64 * 1024 * 1024)
    try:
        await _send_request(
            ws,
            1,
            "initialize",
            {
                "clientInfo": {"name": "codex-thread-tools-mcp", "version": "0.1.0"},
                "protocolVersion": "2025-05-19",
                "capabilities": {"experimentalApi": True},
                "optOutNotificationMethods": ["item/agentMessage/delta"],
            },
        )
        return ws
    except Exception:
        await ws.close()
        raise


async def app_server_request(method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    ws = await _connect_initialized()
    try:
        return await _send_request(ws, 2, method, params)
    finally:
        await ws.close()


async def assert_thread_has_no_active_turn(
    ws: websockets.ClientConnection,
    thread_id: str,
) -> None:
    read_result = await _send_request(
        ws,
        2,
        "thread/read",
        {"threadId": thread_id, "includeTurns": False},
    )
    evidence = active_turn_evidence_from_thread_read(read_result)
    if evidence is None:
        try:
            turns_result = await _send_request(
                ws,
                3,
                "thread/turns/list",
                {
                    "threadId": thread_id,
                    "limit": 1,
                    "sortDirection": "desc",
                    "itemsView": "notLoaded",
                },
            )
        except AppServerRPCError as exc:
            if exc.code != -32601:
                raise
        else:
            evidence = active_turn_evidence_from_turns(
                turns_result.get("data"),
                source="thread/turns/list",
            )
    if evidence is None:
        return

    source = evidence["source"]
    turn_id = evidence.get("turnId")
    identifier = f" {turn_id}" if turn_id else ""
    raise ActiveTurnError(
        f"Refusing to start a new turn on thread {thread_id}: {source} reports an active"
        f" in-progress turn{identifier}. The existing turn was not interrupted or mutated."
    )


async def start_turn(
    *,
    thread_id: str,
    message: str,
    cwd: str | None,
    model: str | None,
    effort: str | None,
    approval_policy: str | None,
    service_tier: str | None,
    wait_for_completion: bool,
    wait_timeout_sec: int,
    max_events: int,
) -> dict[str, Any]:
    params = build_turn_start_params(
        thread_id=thread_id,
        message=message,
        cwd=cwd,
        model=model,
        effort=effort,
        approval_policy=approval_policy,
        service_tier=service_tier,
    )
    ws = await _connect_initialized()
    try:
        await assert_thread_has_no_active_turn(ws, thread_id)
        await _send_request(ws, 4, "thread/resume", {"threadId": thread_id, "excludeTurns": True})
        result = await _send_request(ws, 5, "turn/start", params)
        if not wait_for_completion:
            return {
                "turnStart": result,
                "detached": True,
                "note": "Turn was started and may continue running after this tool call returns.",
            }
        events: list[dict[str, Any]] = []
        turn_id = ((result.get("turn") or {}) if isinstance(result, dict) else {}).get("id")
        loop = asyncio.get_running_loop()
        deadline = loop.time() + max(1, wait_timeout_sec)
        while len(events) < max_events:
            remaining = deadline - loop.time()
            if remaining <= 0:
                break
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=min(1, remaining))
            except asyncio.TimeoutError:
                continue
            message_obj = json.loads(raw)
            if "method" not in message_obj:
                continue
            events.append(message_obj)
            method = message_obj.get("method")
            params_obj = message_obj.get("params") or {}
            event_turn = (params_obj.get("turn") or {}).get("id") if isinstance(params_obj, dict) else None
            if method == "turn/completed" and (not turn_id or event_turn == turn_id):
                return {"turnStart": result, "completed": True, "events": events}
        return {
            "turnStart": result,
            "completed": False,
            "events": events,
            "note": "Timed out or hit max_events while waiting; the turn may still be running.",
        }
    finally:
        await ws.close()


@mcp.tool(description="List Codex threads from the VPS app-server.")
async def list_threads(
    limit: int = 50,
    cursor: str | None = None,
    cwd: str | None = None,
    search_term: str | None = None,
    archived: bool | None = False,
    sort_key: str | None = "updated_at",
    sort_direction: str | None = "desc",
    include_all_sources: bool = True,
    use_state_db_only: bool = False,
    max_chars: int = 120000,
) -> dict[str, Any]:
    params = build_thread_list_params(
        limit=limit,
        cursor=cursor,
        cwd=cwd,
        search_term=search_term,
        archived=archived,
        sort_key=sort_key,
        sort_direction=sort_direction,
        include_all_sources=include_all_sources,
        use_state_db_only=use_state_db_only,
    )
    return {"rpcMethod": TOOL_RPC_METHODS["list_threads"], "response": trim_result(await app_server_request("thread/list", params), max_chars)}


@mcp.tool(description="Read one Codex thread by id. Set include_turns=true for full history.")
async def read_thread(thread_id: str, include_turns: bool = False, max_chars: int = 120000) -> dict[str, Any]:
    result = await app_server_request("thread/read", {"threadId": thread_id, "includeTurns": include_turns})
    return {"rpcMethod": TOOL_RPC_METHODS["read_thread"], "response": trim_result(result, max_chars)}


@mcp.tool(description="Create a new Codex thread on the VPS app-server.")
async def create_thread(
    cwd: str | None = None,
    model: str | None = None,
    approval_policy: str | None = None,
    sandbox: str | None = None,
    service_tier: str | None = None,
    ephemeral: bool | None = None,
    title: str | None = None,
    initial_message: str | None = None,
) -> dict[str, Any]:
    params = build_thread_start_params(
        cwd=cwd,
        model=model,
        approval_policy=approval_policy,
        sandbox=sandbox,
        service_tier=service_tier,
        ephemeral=ephemeral,
    )
    result = await app_server_request("thread/start", params)
    thread_id = extract_thread_id(result)
    extra: dict[str, Any] = {}
    if title and thread_id:
        extra["title"] = await app_server_request("thread/name/set", {"threadId": thread_id, "name": title})
    if initial_message and thread_id:
        extra["initialTurn"] = await start_turn(
            thread_id=thread_id,
            message=initial_message,
            cwd=cwd,
            model=model,
            effort=None,
            approval_policy=approval_policy,
            service_tier=service_tier,
            wait_for_completion=False,
            wait_timeout_sec=1,
            max_events=1,
        )
    return {"rpcMethod": TOOL_RPC_METHODS["create_thread"], "threadId": thread_id, "response": result, **extra}


@mcp.tool(description="Fork an existing Codex thread into a new thread.")
async def fork_thread(
    thread_id: str,
    cwd: str | None = None,
    model: str | None = None,
    approval_policy: str | None = None,
    sandbox: str | None = None,
    service_tier: str | None = None,
    ephemeral: bool = False,
    title: str | None = None,
) -> dict[str, Any]:
    params = compact_dict(
        {
            "threadId": thread_id,
            "cwd": cwd,
            "model": model,
            "approvalPolicy": approval_policy,
            "sandbox": sandbox,
            "serviceTier": service_tier,
            "ephemeral": ephemeral,
        }
    )
    result = await app_server_request("thread/fork", params)
    new_thread_id = extract_thread_id(result)
    extra: dict[str, Any] = {}
    if title and new_thread_id:
        extra["title"] = await app_server_request("thread/name/set", {"threadId": new_thread_id, "name": title})
    return {"rpcMethod": TOOL_RPC_METHODS["fork_thread"], "threadId": new_thread_id, "response": result, **extra}


@mcp.tool(description="Send a user message to an existing Codex thread and start a turn.")
async def send_message_to_thread(
    thread_id: str,
    message: str,
    cwd: str | None = None,
    model: str | None = None,
    effort: str | None = None,
    approval_policy: str | None = None,
    service_tier: str | None = None,
    wait_for_completion: bool = False,
    wait_timeout_sec: int = 30,
    max_events: int = 100,
) -> dict[str, Any]:
    result = await start_turn(
        thread_id=thread_id,
        message=message,
        cwd=cwd,
        model=model,
        effort=effort,
        approval_policy=approval_policy,
        service_tier=service_tier,
        wait_for_completion=wait_for_completion,
        wait_timeout_sec=wait_timeout_sec,
        max_events=max_events,
    )
    return {"rpcMethod": TOOL_RPC_METHODS["send_message_to_thread"], "response": result}


@mcp.tool(description="Set the visible title/name for a Codex thread.")
async def set_thread_title(thread_id: str, title: str) -> dict[str, Any]:
    result = await app_server_request("thread/name/set", {"threadId": thread_id, "name": title})
    return {"rpcMethod": TOOL_RPC_METHODS["set_thread_title"], "response": result}


@mcp.tool(description="Archive or unarchive a Codex thread, matching LazyCodex codex_app.set_thread_archived.")
async def set_thread_archived(thread_id: str, archived: bool = True) -> dict[str, Any]:
    method = "thread/archive" if archived else "thread/unarchive"
    result = await app_server_request(method, {"threadId": thread_id})
    return {"rpcMethod": TOOL_RPC_METHODS["set_thread_archived"], "archived": archived, "response": result}


@mcp.tool(description="Report that pinning is unsupported by the current VPS app-server schema.")
async def set_thread_pinned(thread_id: str, pinned: bool = True) -> dict[str, Any]:
    return {
        "rpcMethod": TOOL_RPC_METHODS["set_thread_pinned"],
        "threadId": thread_id,
        "pinned": pinned,
        "unsupported": True,
        "note": "The inspected VPS app-server schema has no native pinned-thread field or pin/unpin RPC.",
    }


@mcp.tool(description="Archive a Codex thread. This moves the persisted rollout to archived storage.")
async def archive_thread(thread_id: str) -> dict[str, Any]:
    result = await app_server_request("thread/archive", {"threadId": thread_id})
    return {"rpcMethod": TOOL_RPC_METHODS["archive_thread"], "response": result}


@mcp.tool(description="Restore an archived Codex thread.")
async def unarchive_thread(thread_id: str) -> dict[str, Any]:
    result = await app_server_request("thread/unarchive", {"threadId": thread_id})
    return {"rpcMethod": TOOL_RPC_METHODS["unarchive_thread"], "response": result}


@mcp.tool(
    description=(
        "Synthetic handoff helper. If target_thread_id is provided, send the handoff "
        "message there. Otherwise fork source_thread_id when provided, or create a new "
        "thread. This is not a native app-server handoff primitive."
    )
)
async def handoff_thread(
    message: str,
    source_thread_id: str | None = None,
    target_thread_id: str | None = None,
    cwd: str | None = None,
    title: str | None = None,
    model: str | None = None,
    effort: str | None = None,
    approval_policy: str | None = None,
    service_tier: str | None = None,
    wait_for_completion: bool = False,
) -> dict[str, Any]:
    handoff_message = build_handoff_message(source_thread_id, message)
    created: dict[str, Any] | None = None
    if target_thread_id:
        destination_thread_id = target_thread_id
    elif source_thread_id:
        created = await fork_thread(
            thread_id=source_thread_id,
            cwd=cwd,
            model=model,
            approval_policy=approval_policy,
            sandbox=None,
            service_tier=service_tier,
            ephemeral=False,
            title=title,
        )
        destination_thread_id = extract_thread_id(created.get("response") or {}) if isinstance(created, dict) else None
    else:
        created = await create_thread(
            cwd=cwd,
            model=model,
            approval_policy=approval_policy,
            sandbox=None,
            service_tier=service_tier,
            ephemeral=False,
            title=title,
            initial_message=None,
        )
        destination_thread_id = extract_thread_id(created.get("response") or {}) if isinstance(created, dict) else None
    if not destination_thread_id:
        raise RuntimeError("handoff_thread could not determine a destination thread id")
    sent = await start_turn(
        thread_id=destination_thread_id,
        message=handoff_message,
        cwd=cwd,
        model=model,
        effort=effort,
        approval_policy=approval_policy,
        service_tier=service_tier,
        wait_for_completion=wait_for_completion,
        wait_timeout_sec=30,
        max_events=100,
    )
    return {
        "rpcMethod": TOOL_RPC_METHODS["handoff_thread"],
        "synthetic": True,
        "sourceThreadId": source_thread_id,
        "destinationThreadId": destination_thread_id,
        "created": created,
        "sent": sent,
    }


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
