---
title: Mac Computer Use runtime repair
description: Diagnose and repair trusted Computer Use configuration without bypassing platform authorization.
toc:
  - Contract
  - Observed Failure
  - Verification
  - Installation And Rollback
cross_dependencies:
  - ../architecture/runtime-and-host-ownership.md
  - ./2026-07-30-computer-use-native-child.md
  - ../../scripts/computer-use-mcp.mjs
  - ../../scripts/test_computer_use_mcp.mjs
version_control:
  branch: codex/computer-use-repair-20260908
  status: live-canary-verified
  last_updated: 2026-09-08
---

# Mac Computer Use Runtime Repair

## Contract

Keep the VPS and active ChatGPT tasks unchanged. Use the official Computer Use
runtime and its normal signature, native-pipe, and permission checks. Do not
modify TCC or weaken peer authorization. Preserve account hot-swap behavior.

## Observed Failure

The stock OpenAI-signed ChatGPT host has a prepared CodexSwitch app-server child
and a running Computer Use service. The user-configured `node_repl` MCP runtime
registers only the browser trusted RPC service. Calling the installed Computer
Use API fails with `Trusted RPC service is not configured: sky`.

An isolated official node_repl with sky registered still fails when its direct
parent is the Homebrew Node process. Launching the same runtime from ChatGPT's
OpenAI-signed Node succeeds at application discovery. This succeeds with both
the stock CLI and the existing prepared CodexSwitch CLI configured for sandbox
execution. Therefore replacing the prepared app-server is not required for
this connection path.

The dedicated `codexswitch_computer_use` MCP server keeps the official signed
Node parent alive while the official node_repl runs. Both executable signatures
are checked before startup. No binary, signing requirement, TCC state, native
pipe implementation, or approval protocol is modified. Only bundled code is
registered as the trusted sky service. Standard MCP stdio and elicitation pass
through unchanged. ChatGPT owns and rewrites its normal browser/node_repl
configuration, so this connection uses a separate server name.

## Verification

1. Reproduce the failure using the existing node_repl tool.
2. Test the official sky service registration in an isolated official node_repl
   subprocess using MCP, without changing the active tool connection.
3. Preserve the original configuration before a narrowly scoped repair.
4. Require successful application discovery and a harmless UI interaction with
   screenshot/accessibility evidence. Process presence is not a passing canary.
5. Keep any remaining native-pipe/signature failure distinct from missing RPC
   configuration. Never report completion from configuration alone.

The deployed launcher passed app discovery with the canonical managed CLI
wrapper retained. After the user's approval, the installed connection became
available in the existing ChatGPT conversation as `codexswitch_computer_use`.
The live canary read Calculator's accessibility tree, clicked its `2` button,
entered `+ 2` using keyboard actions, and pressed Return. Both the refreshed
accessibility tree and the returned screenshot showed `2 + 2` and result `4`.
No ChatGPT restart, app-server replacement, or VPS change was needed.

This verifies app discovery, app-specific authorization, accessibility reads,
clicking, keyboard input, and screenshots through the installed MCP connection.
It does not assert that the separate desktop-managed browser/node_repl path
has been repaired, or that the previously staged re-signed auth bundle has
been activated or tested with Computer Use.

## Installation And Rollback

Install the reviewed launcher at a content-addressed path in
`~/.local/share/codexswitch/computer-use-mcp/` with mode `0444`. Back up the
existing Codex configuration privately with mode `0600`; it can contain secrets.
Use the existing Codex CLI's structured MCP configuration command:

```sh
codex mcp add codexswitch_computer_use \
  --env "CODEX_HOME=$HOME/.codex" \
  --env "CODEX_CLI_PATH=$HOME/.local/share/codexswitch/patched-codex/codex" \
  -- /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node \
  "$HOME/.local/share/codexswitch/computer-use-mcp/<sha256>.mjs"
```

The server starts the official node_repl tool surface, including normal
Computer Use app approvals. An existing ChatGPT tool session may need a new
conversation or MCP configuration reload before the server is available.
Do not terminate an active turn merely to refresh its tool list.

Rollback removes only the added server using
`codex mcp remove codexswitch_computer_use`. Do not replace the entire live
config with its backup if unrelated settings have changed since installation.
