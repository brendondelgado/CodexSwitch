---
title: Computer Use native child migration
description: Migration from the launchd WebSocket bridge to an official ChatGPT-owned native stdio app-server.
toc:
  - Goal
  - Invariants
  - Implementation
  - Verification
cross_dependencies:
  - ../architecture/macos-runtime-discovery.md
  - ../architecture/runtime-and-host-ownership.md
  - ../sighup-safety.md
  - ../../Sources/CodexSwitch/Services/CodexDesktopBridgeKeepAlive.swift
  - ../../Sources/CodexSwitch/Services/SwapEngine.swift
  - ../../crates/codexswitch-cli/src/readiness.rs
version_control:
  branch: codex/computer-use-native-child
  status: implementation
  last_updated: 2026-07-30
---

# Computer Use Native Child Migration

## Goal

Restore Computer Use's supported process lineage while retaining CodexSwitch
account hot-swapping. The official OpenAI-signed ChatGPT app owns the local
Codex app-server. `CODEX_CLI_PATH` selects CodexSwitch's prepared CLI without
changing the signed desktop parent.

## Invariants

1. `/Applications/ChatGPT.app` has OpenAI Team ID `2DC432GLL2`.
2. ChatGPT starts `codex app-server --listen stdio://` through its native child
   path; CodexSwitch does not host a desktop app-server.
3. `CODEX_APP_SERVER_WS_URL` is absent and
   `com.codexswitch.desktop-app-server-9223` is not loaded.
4. CodexSwitch publishes only a validated prepared launcher through
   `CODEX_CLI_PATH`.
5. Hot swaps remain fail-closed version-3 request/ACK operations bound to the
   exact app-server process identity and complete token fingerprint.
6. Computer Use helper ancestry must reach the official ChatGPT process without
   traversing a CodexSwitch-owned app-server or shell wrapper.
7. No verifier bypass, TCC mutation, desktop re-signing, or private signing key
   is part of installation or repair.

## Implementation

- Replace desktop bridge installation with idempotent retirement of the exact
  legacy launchd job and its generated files.
- Stop restarting a desktop bridge after prepared CLI updates. Publish
  `CODEX_CLI_PATH`; a running ChatGPT process adopts a new generation on its
  next native-child launch.
- Admit only exact native `stdio://` desktop app-server invocations for Mac
  desktop hot-swap and keep strict frontend-delivery acknowledgements.
- Add a structured `computerUseLineage` result to `codexswitch-cli doctor
  --json`, including the stock-app signature, native-child ancestry, helper
  ancestry, and legacy-bridge absence.
- Disable automatic desktop ASAR patching/re-signing in the supported path.

## Verification

- Unit tests cover retirement idempotence, exact stdio classification, refusal
  of the legacy listener, and lineage failures.
- `doctor --json` reports the native child and lineage canary separately from
  general account readiness.
- A synthetic hot swap produces a current version-3 ACK from the native child.
- Computer Use starts under official ChatGPT ancestry and performs a harmless
  canary action.
