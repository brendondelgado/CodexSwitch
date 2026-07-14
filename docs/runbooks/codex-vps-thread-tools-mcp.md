---
toc:
  - Codex VPS Thread Tools MCP
  - Why Restarting App-Server Is Not Enough
  - Independent Remote Endpoints
  - Installed Tool Provider
  - Safe Turn Dispatch
  - Mac Sidebar Freshness
  - Verification
cross_dependencies:
  - scripts/codex-thread-tools-mcp.py
  - scripts/test_codex_thread_tools_mcp.py
  - scripts/codex-vps
  - scripts/patch-asar.py
  - docs/linux-cli-only.md
version_control:
  branch: main
  commit: pending
---

# Codex VPS Thread Tools MCP

## Why Restarting App-Server Is Not Enough

`codex-vps restart` restarts `signul-codex-app-server.service`, refreshes the
Mac tunnel, and, when ChatGPT or legacy Codex is running, recycles its local
desktop remote bridge proxy. It does not register new model-callable tools.

The app-server already exposes thread control-plane JSON-RPC methods such as
`thread/start`, `thread/list`, `thread/read`, `thread/fork`, and `turn/start`,
but those methods are not automatically visible to Codex as tools. If
`tool_search` returns zero matches for `create_thread`, `read_thread`,
`send_message_to_thread`, `list_threads`, or related names, the missing layer is
tool registration, not app-server liveness.

## Independent Remote Endpoints

The port-8390 app-server used by `codex-vps` and this MCP provider is not the
worker used by ChatGPT's built-in SSH remote. The built-in remote reaches a
separately managed VPS app-server through
`~/.codex/app-server-control/app-server-control.sock`; its local bridge is a
`codex app-server proxy` child of ChatGPT (or legacy Codex).

Treat recovery evidence as endpoint-specific. Restarting or health-checking
`signul-codex-app-server.service` proves nothing about the Unix-socket worker.
Recycling the ChatGPT/Codex local proxy, or seeing the built-in SSH remote
reconnect, proves nothing about the service listening on `127.0.0.1:8390`.
Verify the endpoint used by the failing client; verify both independently when
both clients must recover.

## Installed Tool Provider

`scripts/codex-thread-tools-mcp.py` is the repo-owned MCP wrapper for the VPS.
It registers these tool names and maps them to the app-server:

- `list_threads` -> `thread/list`
- `read_thread` -> `thread/read`
- `create_thread` -> `thread/start`
- `fork_thread` -> `thread/fork`
- `send_message_to_thread` -> `turn/start`
- `set_thread_title` -> `thread/name/set`
- `set_thread_archived` -> `thread/archive` or `thread/unarchive`
- `set_thread_pinned` -> explicit unsupported response because app-server has no native pin RPC
- `archive_thread` -> `thread/archive`
- `unarchive_thread` -> `thread/unarchive`
- `handoff_thread` -> synthetic create/fork plus `turn/start`

`handoff_thread` is intentionally labeled synthetic because app-server has no
native method with that name. It creates or forks a target thread and posts a
handoff message with `turn/start`.

## Safe Turn Dispatch

Before `send_message_to_thread`, an initial message, or a synthetic handoff can
call `turn/start`, the provider performs read-only checks with `thread/read` and
`thread/turns/list`. It refuses the new turn when `thread/read` reports an
active thread or the latest listed turn reports `inProgress`. The refusal does
not resume the thread, interrupt its turn, or otherwise mutate that work.

These checks close the determinable busy-thread case, not the race between the
last read and `turn/start`. App-server does not expose an atomic
"start only if idle" precondition, so another client can still begin a turn in
that interval. If `thread/turns/list` is unavailable on an older app-server,
the provider retains the `thread/read` result instead of mutating or
interrupting a turn to discover its state.

Each JSON-RPC request uses one absolute timeout deadline. Notifications or
responses for other request IDs are ignored without extending that deadline.

The MCP server should be registered as `codex_app` because LazyCodex team-mode
instructions expect the host/app namespace `codex_app.create_thread`,
`codex_app.send_message_to_thread`, `codex_app.read_thread`,
`codex_app.set_thread_title`, and `codex_app.set_thread_archived`.

On the VPS, install the script to:

```bash
/home/signul/.local/bin/codex-thread-tools-mcp
```

Then register it in `/home/signul/.codex/config.toml`:

```toml
[features]
tool_search = true
tool_search_always_defer_mcp_tools = true

[mcp_servers.codex_app]
command = "python3"
args = ["/home/signul/.local/bin/codex-thread-tools-mcp"]
startup_timeout_sec = 10
tool_timeout_sec = 120
enabled = true

[mcp_servers.codex_app.env]
CODEX_THREAD_TOOLS_APP_SERVER_URL = "ws://127.0.0.1:8390"
CODEX_THREAD_TOOLS_DEFAULT_CWD = "/home/signul/SIGNUL"
```

`tool_search_always_defer_mcp_tools` is required for this small tool set. By
default, Codex directly exposes small MCP tool sets and only defers large MCP
sets into `tool_search`. LazyCodex team-mode asks agents to discover thread
tools through `tool_search`, so the VPS must force MCP tools into the deferred
search index.

## Mac Sidebar Freshness

Agent-created VPS threads are persisted by the VPS app-server under
`/home/signul/.codex/sessions`. Codex.app on the Mac can display those remote
threads through its remote AppServerManager, but the sidebar recent-conversation
query is intentionally cached with an infinite stale time. It normally updates
from app-server conversation callbacks and refreshes on startup.

If new VPS agent threads are usable through tools but do not appear in the Mac
sidebar until Codex.app restarts, thread creation is working and the bug is the
desktop renderer's live recent-conversations refresh. `scripts/patch-asar.py`
must keep the `CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH` installed alongside
the auth hot-swap patch so enabled remote hosts get a lightweight periodic
recent-thread refresh while the sidebar is mounted.

## Verification

Run the local regression:

```bash
python3 scripts/test_codex_vps.py
python3 scripts/test_codex_thread_tools_mcp.py
```

After installing on the VPS, reload app-server MCP config or restart the VPS
app-server, then check `mcpServerStatus/list` through the port-8390 app-server.
The `codex_app` server should report the expected tool names. New or reloaded
Codex sessions can then discover those names via tool search. Check ChatGPT's
built-in SSH remote separately through its Unix-socket worker when that path is
also part of the incident.
