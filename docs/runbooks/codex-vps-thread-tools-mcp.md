---
toc:
  - Codex VPS Thread Tools MCP
  - Why Restarting App-Server Is Not Enough
  - Independent Remote Endpoints
  - Shared Task Owner Contract
  - Installed Tool Provider
  - Safe Turn Dispatch
  - Mac Sidebar Freshness
  - Verification
  - Staged Canary Evidence
cross_dependencies:
  - scripts/codex-thread-tools-mcp.py
  - scripts/test_codex_thread_tools_mcp.py
  - scripts/codex-vps
  - scripts/patch-asar.py
  - docs/linux-cli-only.md
  - docs/architecture/runtime-and-host-ownership.md
version_control:
  branch: main
  commit: pending
  last_updated: 2026-09-06
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

The port-8390 app-server used by `codex-vps` is not the
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

## Shared Task Owner Contract

The desktop task helper must connect to the existing desktop Unix-socket
app-server. Sharing `CODEX_HOME` across different servers shares history, not
live task ownership. The former MCP default `ws://127.0.0.1:8390` let that server
hold the writer lock while the desktop tried to load the same task through its
Unix server, producing "This is open in another app."

The default `unix://` resolves to
`$CODEX_HOME/app-server-control/app-server-control.sock`, with `~/.codex` used
when `CODEX_HOME` is unset. An explicit `unix:///absolute/path.sock` is supported
for a verified desktop socket. TCP URLs are rejected. Missing or unavailable
sockets fail clearly: the helper never starts a server, falls back to port
8390, retries a mutation, or modifies writer locks. Initialization completes
with both `initialize` and `initialized` before task requests. Unix WebSocket
compression is disabled to match the native client handshake; the deployed
0.153.2 control socket rejects the Python library's default extension offer.

Closing a helper connection removes its subscriptions but does not transfer
ownership. Upstream retains inactive, unsubscribed tasks for 30 minutes; active
turns continue on the owning server. Desktop clients subscribe to that same
server and can follow active work. The compatibility `unsubscribe_thread` tool
only removes its own connection subscription; it never resumes a task first
and cannot release another server's writer lock.

Account reload remains CodexSwitch's responsibility for both running runtimes.
The helper does not cache credentials or bind routing to an account. Each call
reconnects to the same socket, including after auth reload or desktop reconnect.
Already-owned tasks on port 8390 are not forcibly migrated by this change.

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
- `unsubscribe_thread` -> connection-only `thread/unsubscribe`, not writer handoff
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
For a fresh task whose history query reports `missing source rollout`, a second
read with `includeTurns=true` must confirm live `idle` status and an explicitly
empty turn list before dispatch. Active, unknown, and nonempty results still
fail closed; other history errors are not bypassed.

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
CODEX_THREAD_TOOLS_APP_SERVER_URL = "unix://"
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
must keep `CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH_V2` installed alongside the
auth hot-swap patch. Native callbacks and the native startup refresh remain the
primary path; one cleanup-bound 60-second timer is only a missed-notification
fallback while the sidebar is mounted.

## Verification

Run the local regression:

```bash
python3 scripts/test_codex_vps.py
python3 scripts/test_codex_thread_tools_mcp.py
```

The deterministic regression uses real temporary Unix WebSocket connections:
create, detach an active turn, subscribe from a second frontend, observe
progress, follow up, and reconnect all retain one owner. Missing sockets,
initialization failure, and legacy TCP configuration must fail without fallback.
This fixture does not replace a real desktop canary.

Before activation, compare installed source and save backups of the script and
config outside shared artifact folders. Migrate the explicit MCP environment
above as well as the script; changing the default alone is insufficient.
Existing MCP processes keep their old code and environment. Do not restart
shared services, reload active MCP clients, or switch accounts without approval
when existing work could be interrupted. New MCP processes pick up the change.

Check `mcpServerStatus/list` on the desktop Unix endpoint and verify installed
source hash and selected socket. With a disposable task only: create through
the helper, open in the desktop while active, follow progress, send a follow-up,
and reconnect. Record actual desktop evidence separately from protocol tests.
Test account switching only during an approved safe window; do not disable it.

## Staged Canary Evidence

On 2026-09-06, the staged helper passed 23 focused tests on both macOS and the
SIGNUL VPS; the adjacent `test_codex_vps.py` suite passed 24 tests on macOS.
The disposable task `01a077ed-afb7-7540-a39a-b114265f1b64` was created through
the helper and opened in ChatGPT desktop during its active turn. The desktop
displayed `CANARY-ACTIVE`, then `CANARY-DONE`, followed by a completed
`CANARY-FOLLOWUP-DONE` turn. A separate connection resumed the active task on
the same Unix owner without conflict. Screenshots and server reads agreed.

This was staged validation, not activation of the installed MCP provider.
The installed script/config and existing MCP processes were not changed.
No shared service, desktop app, or account-switch daemon was restarted, and
neither protected production task was interrupted or steered. Full desktop
SSH reconnect and real account-switch testing remain approval-gated; the
regression fixture covers transport reconnect and simulated auth reload.
