---
toc:
  - Root Cause
  - Fix
  - Verification
cross_dependencies:
  - Sources/CodexSwitch/Services/SwapEngine.swift
  - Tests/CodexSwitchTests/SwapEngineTests.swift
  - Sources/CodexSwitch/App/AppDelegate.swift
version_control:
  updated_on: 2026-03-19
  updated_by: Codex
  status: working-tree
---

# SIGHUP Safety

## Root Cause

CodexSwitch reloads active CLI sessions by sending `SIGHUP` to processes returned by `pgrep -lf codex`.

After the Codex desktop update, the desktop app started running its own bundled `codex` app-server at a path inside the `.app` bundle. The previous matcher treated that process as a CLI target and sent it `SIGHUP` during account swaps.

Desktop logs showed the exact failure at swap time:

- `App-server connection closed ... signal=SIGHUP transport=stdio`

That meant account switching was no longer isolated to terminal CLI sessions.

## Fix

`SwapEngine.signalCodexReload()` now filters candidate processes more conservatively:

- only the native `codex` executable, not the Node launcher script
- never bundled `.app/Contents/.../codex` processes
- only processes attached to an interactive TTY

SIGHUP eligibility is also version-gated:

- the `~/.codexswitch/sighup-verified` marker must be at least as new as the installed vendor `codex` binary
- if Codex updates and the marker is older than the binary, SIGHUP is disabled until re-verified

Launch-time behavior is also stricter:

- app startup writes `auth.json`
- app startup does not SIGHUP running CLI sessions

This keeps terminal CLI sessions protected during CodexSwitch restarts while excluding the desktop app's detached app-server.

## Verification

- Added regression tests for interactive CLI process selection.
- Added regression tests that exclude detached desktop app-server processes.
- Added regression tests for stale SIGHUP verification markers.
- Verified `swift test --filter SwapEngineTests` passes after the change.
