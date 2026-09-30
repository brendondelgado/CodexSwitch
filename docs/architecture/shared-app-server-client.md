---
title: Shared app-server client
description: How per-thread frontends such as T3 Code join the host's shared Codex app-server daemon instead of spawning a competing private writer.
toc:
  - Shared App-Server Client
  - Why
  - Design
  - Invocation Contract
  - Per-Thread MCP Injection And Token Handling
  - Daemon Resolution And Start
  - macOS Fallback
  - Relay Contract
  - Discovery Exclusion
  - Configuring T3 Code
  - Open Questions
cross_dependencies:
  - ../../crates/codexswitch-cli/src/shared_app_server_client.rs
  - ../../crates/codexswitch-cli/src/main.rs
  - ../../crates/codexswitch-cli/src/reload.rs
  - ../../crates/codexswitch-cli/tests/shared_app_server_client.rs
  - ../../scripts/codex-shared
  - ../../Sources/CodexSwitch/Services/SwapEngine.swift
  - ../../Sources/CodexSwitch/Services/DesktopRuntimeDiagnostics.swift
  - ../../Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - ../../Tests/CodexSwitchTests/SwapEngineTests.swift
  - runtime-and-host-ownership.md
  - t3-usage-hub.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-09-28
---

# Shared App-Server Client

## Why

Codex allows exactly one writer per thread across all app-server processes,
and ownership cannot be transferred. T3 Code spawns its own
`codex app-server` for every T3 thread. When the same Codex thread is already
loaded by another app-server (on the VPS, the ChatGPT desktop's SSH daemon),
T3's private server fails with `thread <id> already has an active writer`.

The fix is not to steal or release ownership. It is to make T3 a client of
the same daemon that already owns the thread, so there is only ever one
writer process.

## Design

`scripts/codex-shared` is installed as T3's Codex binary path. It executes
`codexswitch-cli app-server-client "$@"`, which receives the exact argv T3
would have given `codex`:

1. **Plan.** A plain stdio `app-server` invocation becomes a shared session.
   Anything else is passed through (see Invocation Contract).
2. **Connect.** Resolve the daemon's control socket, verify the socket peer
   runs as this user, and complete the WebSocket upgrade.
3. **Relay.** Newline-delimited JSON-RPC on stdio is relayed to one WebSocket
   text frame per message and back, with the invocation's overrides merged
   into thread-opening requests.
4. **Fall back.** If no verified daemon is reachable, replace this process
   with the real Codex using the original argv and untouched stdin. The
   frontend then behaves exactly as it did before this client existed.

The client never holds account credentials. Threads it opens live inside the
daemon and follow that daemon's account reload like every other daemon client.

## Invocation Contract

A shared session requires, in order: any number of global `-c/--config`,
`--enable`, and `--disable` flags; the literal `app-server`; then any number of
the same flags plus `--stdio` or `--listen stdio://`. All clap spellings are
accepted (`-c V`, `-cV`, `-c=V`, `--config V`, `--config=V`).

Everything else is executed on the real Codex with the original argv:

- non-app-server commands T3 uses for probes (`--version`, `exec`,
  `login status`, ...);
- app-server subcommands (`proxy`, `daemon`, `generate-*`, `help`);
- app-server options the shared daemon cannot honour per connection
  (`--analytics-default-enabled`, `--strict-config`, `--listen` other than
  stdio, `--ws-*`, `--code-mode-host`);
- malformed overrides (missing `=`, empty key, missing value) and non-UTF-8
  arguments, so Codex reports the error itself.

The real Codex is `$CODEXSWITCH_REAL_CODEX`, else the public managed launcher
`~/.local/bin/codex`, else on Linux
`~/.local/share/codexswitch/current/patched-codex/codex`. Never install this
launcher as `~/.local/bin/codex`: the fallback would execute itself.

## Per-Thread MCP Injection And Token Handling

Each `-c key=value` is parsed like Codex does: the value is TOML when it
parses, otherwise the raw string without surrounding quotes. `--enable X` and
`--disable X` become `features.X = true/false`. Later flags win.

The resulting dotted-key map is merged into `params.config` of every
`thread/start`, `thread/resume`, and `thread/fork` request (all three accept a
free-form `config` object in the 0.153 protocol schema). Keys the client
already sends win. Only these requests are rewritten; every other message is
forwarded byte-for-byte. A live probe confirmed that
`mcp_servers.<name>.*` overrides passed this way attach that MCP server to
only that thread inside the shared daemon.

T3 passes its MCP credential as
`mcp_servers.t3-code.bearer_token_env_var="T3_MCP_BEARER_TOKEN"` with the token
in the child environment. The shared daemon cannot read this client's
environment, so when the named variable is set and non-empty the client
replaces that key with
`mcp_servers.<name>.http_headers = {Authorization = "Bearer <token>"}`
(existing headers are kept). Nested table forms (`mcp_servers.<name>={...}`
and `mcp_servers={...}`) are converted the same way.

Token rules:

- The token appears only in the thread-opening request sent over the verified
  same-user socket. It is never logged, never placed in argv, and never
  written to stderr.
- Credentials are sent only after the socket peer uid (Linux `SO_PEERCRED`,
  macOS `getpeereid`) equals this process's effective uid.
- Variables converted this way are removed from the environment of any daemon
  this client starts, so the long-lived daemon never inherits one thread's
  token.

## Daemon Resolution And Start

`$CODEXSWITCH_APP_SERVER_SOCKET` names an explicit socket on any platform. An
explicit socket is never started; if it is absent the client falls back.

Otherwise, on Linux the socket is
`$CODEX_HOME/app-server-control/app-server-control.sock` (`CODEX_HOME`
defaults to `~/.codex`). If it is absent or refuses connections, the client
launches the daemon itself: `<real codex> -c features.code_mode_host=true
app-server --listen unix://`, the exact listener the desktop daemon has always
run, so the daemon has one configuration regardless of which frontend connects
first. Codex 0.159 removed the auto-start from `app-server proxy`, and its
`app-server daemon start` accepts only Codex's own package directory, so
neither can start a CodexSwitch-managed runtime. On Linux the daemon runs in its
own transient `systemd-run --user --scope`, so it never joins the frontend's
service cgroup (restarting T3 must not kill the shared daemon):

- the client waits up to 30 seconds for the socket to accept, and falls back at
  once if the launch exits first without a socket (a launch that loses a start
  race to another client simply finds the winner's socket);
- in its own process group with null stdin and output appended to
  `$CODEX_HOME/app-server-control/app-server.log`, so the daemon cannot hold the
  frontend's pipes open or receive the frontend's signals;
- with `HOME` as its working directory and the converted token variables
  removed.

Starting through the real Codex keeps the managed contract: on the VPS the
public launcher takes the shared runtime lock and the patched daemon resolves
its child through `current/patched-codex/codex`. Any start failure falls back
to a private app-server. This differs deliberately from the desktop task tools
in `runtime-and-host-ownership.md`, which must never start a server: T3 is a
frontend that would otherwise start its own private writer, so starting the
shared daemon strictly reduces the number of writers.

## macOS Fallback

On macOS the client never starts a daemon and, without an explicit socket,
never connects to one; it falls back immediately. The Mac desktop contract
gives the ChatGPT desktop ownership of its stdio app-server child and treats
any WebSocket desktop bridge as unsupported, so a Mac daemon would be an
unmanaged runtime outside CodexSwitch's hot-swap discovery. The explicit socket
exists for tests and deliberate operator use.

## Relay Contract

- One JSON-RPC message per stdin line; `\r\n` and blank lines are tolerated.
  A final line without a newline is sent at EOF.
- Each server text frame is written to stdout followed by `\n` and flushed.
- Messages are bounded at 64 MiB in each direction. The bound caps memory; it
  matches tungstenite's default message cap because resume and read responses
  can carry long histories with inline images.
- Stdin is read only after every earlier line has been handed to the socket,
  so a slow daemon applies backpressure instead of growing memory.
- Stdin EOF sends a WebSocket close and exits 0 once the daemon closes, or
  after 5 seconds. A daemon close exits 0. Transport or stdout failures exit 1
  with a secret-free message on stderr.

## Discovery Exclusion

The client and its launcher are never account-bearing runtimes:

- Rust `is_codex_app_server_command_line` rejects any command line containing
  the `app-server-client` token or a `codex-shared` executable (in addition
  to the existing `codexswitch-cli` rule). This also keeps the Linux
  fail-closed unreadable-process probe from treating a client as an
  unidentified Codex runtime.
- Swift `SwapEngine.processMatchesRuntime` rejects a `codexswitch-cli`
  executable and an `app-server-client` first argument. Without this, a
  control binary inside a prepared runtime directory would classify as the
  official desktop stdio child.
- Swift `DesktopRuntimeDiagnostics.parseAppServerProcessLine` and
  `DesktopPatchManager.isDesktopHotSwapRuntimeLine` ignore client and launcher
  lines.

After a fallback exec the process is the real Codex app-server and is
discovered normally.

## Configuring T3 Code

1. Deploy a CodexSwitch release that contains `app-server-client`.
2. Install the launcher on the host where T3 runs Codex:
   `install -m 0755 scripts/codex-shared ~/.local/bin/codex-shared`.
   It uses `~/.local/bin/codexswitch-cli` unless `CODEXSWITCH_CLI` is set.
3. In T3 Code, set the Codex provider's binary path to the absolute launcher
   path, for example `/home/<user>/.local/bin/codex-shared`.

T3's launch args, `--version` probes, and `exec` calls keep working because
every non-shared invocation is the real Codex.

A connected T3 client is an initialized frontend of the daemon. The VPS
external idle proof therefore cannot acknowledge a reload while T3 is
connected; the daemon must complete the normal `account/updated` write.

## Verified Behavior And Limits

Live probes against the VPS daemon (Codex 0.153.2, 2026-09-28):

- Per-thread `config` on `thread/start` attaches the MCP server to that thread
  only (`mcpServer/startupStatus/updated` carries the thread id).
- A literal Authorization header passed in `config` was not written to
  sessions, `state_5.sqlite`, or any other Codex store, so T3's per-thread token
  is not persisted.
- `thread/resume` needs a materialized rollout; a thread with no turns reports
  `no rollout found`. Codex logs `... override was provided and ignored while
  running` for a thread that is already loaded, so when another client (for
  example ChatGPT) already has the thread loaded, T3 shares it without a writer
  conflict but its MCP tools attach only if T3 loads the thread first.
