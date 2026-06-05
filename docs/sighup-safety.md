---
toc:
  - Root Cause
  - Fix
  - Desktop Runtime Truth
  - Bundled Plugin Readiness
  - Permission Prompt Guardrails
  - Desktop Headroom Removal
  - Verification
cross_dependencies:
  - Sources/CodexSwitch/Services/SwapEngine.swift
  - Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - Sources/CodexSwitch/Services/CLIStatusChecker.swift
  - Sources/CodexSwitch/Services/DesktopAppConnector.swift
  - scripts/patch-asar.py
  - scripts/test_patch_asar.py
  - Sources/CodexSwitch/Services/DesktopHeadroomCleanup.swift
  - Tests/CodexSwitchTests/SwapEngineTests.swift
  - Tests/CodexSwitchTests/DesktopStatusTests.swift
  - Tests/CodexSwitchTests/DesktopRuntimeHotSwapStateTests.swift
  - Sources/CodexSwitch/App/AppDelegate.swift
  - Sources/CodexSwitch/Services/CodexConfigRepair.swift
  - Tests/CodexSwitchTests/CodexConfigRepairTests.swift
version_control:
  updated_on: 2026-04-29
  updated_by: Codex
  status: working-tree
---

# SIGHUP Safety

## Root Cause

CodexSwitch reloads active CLI sessions by sending `SIGHUP` to processes returned by `pgrep -lf codex`.

The desktop app can run its own bundled `codex` app-server at a path inside the `.app` bundle. The previous matcher treated that process as a CLI target and sent it `SIGHUP` during account swaps.

Desktop logs showed the exact failure at swap time:

- `App-server connection closed ... signal=SIGHUP transport=stdio`

That meant account switching was no longer isolated to terminal CLI sessions.

A second drift path was found on 2026-04-28: a launchd-level `CODEX_CLI_PATH` can force `Codex.app` to spawn `/opt/homebrew/bin/codex` before it considers the bundled app binary. If that Homebrew install is updated back to stock, both desktop and CLI hot-swap can appear patched on disk while the live app-server is actually running an unpatched CLI.

## Fix

`SwapEngine.signalCodexReload()` now filters candidate processes more conservatively:

- only the native `codex` executable, not the Node launcher script
- never detached desktop helpers such as `codex app-server` or `codex_chronicle`
- bundled `Codex.app/Contents/Resources/codex` processes only when that on-disk binary has the verified SIGHUP hot-swap patch
- only processes attached to an interactive TTY

SIGHUP eligibility is also version-gated:

- a `~/.codexswitch/sighup-verified*` marker must exist
- the candidate executable must contain the `sighup-verified` and `SIGHUP: auth reloaded` markers before app-bundled CLI sessions are eligible
- `patch-asar.py` refuses to replace a bundled CLI that supports `gpt-5.5` with an older SIGHUP-capable binary that does not
- `patch-asar.py` searches the local SIGHUP fork at `~/Developer/codex/codex-rs/target/release/codex` before falling back to stock install paths
- the desktop ASAR patch deletes inherited `CODEX_CLI_PATH` before resolving the app-server binary and from sanitized child-process env, so a launchd or shell override cannot hijack Codex.app onto a stale Homebrew wrapper
- CodexSwitch repairs the Homebrew vendor CLI from a verified SIGHUP-capable source while Codex.app is running, so npm/Homebrew updates do not permanently strand CLI hot-swap
- `patch-asar.py` refuses to patch or re-sign `/Applications/Codex.app` while Codex.app is running, unless an explicit emergency override is set, because live re-signing can SIGKILL the app-server and make macOS re-prompt for permissions
- if Codex updates and the bundled CLI is stock again, desktop patch readiness is false until `patch-asar.py` copies in a SIGHUP-capable CLI and the app bundle is re-signed

Launch-time behavior is also stricter:

- app startup writes `auth.json`
- app startup does not SIGHUP running CLI sessions

This keeps terminal CLI sessions protected during CodexSwitch restarts while excluding the desktop app's detached app-server. It also prevents CodexSwitch from claiming the desktop patch is ready when the renderer patch exists but the bundled CLI is still stock.

## Desktop Runtime Truth

Desktop hot-swap now has a stricter live-session contract:

- patched files on disk are not enough
- the currently running `Codex.app` bundled `codex` processes must also have started from the patched binary
- Homebrew vendor app-server processes launched by the desktop app count as desktop runtime and must also have hot-swap markers
- Node launcher wrapper processes alone are ignored; the native `codex app-server` child is the runtime that proves readiness
- a process with marker strings is still unverified until it writes a fresh `.codexswitch/hotswap-ack/<pid>.json` acknowledgement after a reload signal
- if any live bundled `codex` process predates the patched executable, or lacks a fresh acknowledgement, CodexSwitch reports `restart Codex.app to activate hot-swap` instead of claiming readiness
- the desktop auth-watcher marker no longer counts as success on its own when the live bundled CLI is stale

This keeps the menu bar status honest after a desktop patch, app repair, bundled CLI replacement on disk, or failed live reload. See `docs/runbooks/codexswitch-hot-swap-verification.md` for the checklist that must pass before calling hot-swap fixed.

## Bundled Plugin Readiness

Browser Use and Computer Use readiness must be checked against the app-server `plugin/list` contract, not only against files on disk.

Codex app-server 0.125 lists the curated marketplace plus marketplace roots passed through `PluginListParams.cwds`. The older desktop bundle expected `marketplace/add` to make bundled marketplaces globally visible. When that RPC is unavailable, CodexSwitch must patch desktop `plugin/list` callers so they always include `/Applications/Codex.app/Contents/Resources/plugins/openai-bundled`.

The desktop patch is not complete unless `app.asar` contains `CODEXSWITCH_BUNDLED_PLUGIN_LIST_ROOT_PATCH`. A valid runtime probe is:

- `plugin/list` with the bundled root in `cwds` returns `browser-use@openai-bundled`, `computer-use@openai-bundled`, and `latex-tectonic@openai-bundled`
- each bundled plugin is `installed = true` and `enabled = true`
- `plugin/read` can read `computer-use` from the bundled marketplace path without starting the MCP server

## Permission Prompt Guardrails

CodexSwitch must not leave stale Computer Use workarounds in `~/.codex/config.toml`.

The config repair path removes:

- `notify = [...]` entries that launch bundled `SkyComputerUseClient`
- `[mcp_servers.computer-use]` entries whose command launches bundled `SkyComputerUseClient`

The installed plugin should own its MCP server. A manual global `mcp_servers.computer-use` entry overrides the plugin-provided server and can launch the Computer Use binary outside the plugin lifecycle, which can cause repeated macOS Screen Recording prompts or code-signature crashes.

CodexSwitch also forces `features.chronicle = false` whenever it repairs a bundled-plugin config. Patched desktop builds are locally re-signed, while macOS TCC grants can remain pinned to OpenAI's original code requirement. If Chronicle auto-starts on launch in that state, `codex_chronicle` immediately requests Screen Recording and macOS may repeatedly prompt or deny access. Chronicle must stay disabled for patched desktop builds unless CodexSwitch can prove the current signing requirement already matches the stored TCC grant.

## Desktop Headroom Removal

Codex.app must not be routed through Headroom by CodexSwitch.

The desktop patcher now treats Headroom bridges as legacy state to remove:

- `patch-asar.py` strips `CODEXSWITCH_HEADROOM_BASE_URL` transport propagation from the app-server launcher
- `patch-asar.py` strips legacy `OPENAI_BASE_URL = CODEXSWITCH_HEADROOM_BASE_URL` bridges when found
- desktop patch readiness no longer requires Headroom markers
- the menu bar and settings UI no longer advertise desktop Headroom routing
- CodexSwitch launch disables the desktop Headroom default, unsets stale launchd routing env, and stops only the Headroom proxy process it previously owned

Account hot-swap remains supported through the auth cache invalidation, bundled CLI SIGHUP patch, `CODEX_CLI_PATH` guard, and bundled plugin-list patch. The desktop app-server traffic stays on stock OpenAI transport so silent optimizer filtering cannot distort app diagnostics, streaming behavior, or model/provider identity.

## Verification

- Added regression tests for interactive CLI process selection.
- Added regression tests that exclude detached desktop app-server processes.
- Added regression tests for stale SIGHUP verification markers.
- Added patcher tests that copy a SIGHUP-capable CLI into `Codex.app/Contents/Resources/codex` and treat the copy as idempotent once markers are present.
- Added patcher tests for local-fork candidate discovery and the desktop `CODEX_CLI_PATH` guard.
- Added patcher tests that remove current and legacy desktop Headroom env bridges.
- Added desktop runtime tests for Homebrew vendor app-server detection and Node launcher filtering.
- Verified `python3 scripts/test_patch_asar.py` passes after the bundled-CLI repair change.
- Verified `swift build` passes after the SIGHUP target filter change.
