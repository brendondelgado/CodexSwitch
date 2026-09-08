---
title: Unified ChatGPT hot-swap repair
description: Restore transparent Mac account transitions without interrupting active work.
toc:
  - Unified ChatGPT Hot-Swap Repair
  - Contract
  - Observed State
  - Replay And Readiness
  - Activation Boundary
cross_dependencies:
  - ../architecture/runtime-and-host-ownership.md
  - ../architecture/macos-runtime-discovery.md
  - ../runbooks/codexswitch-hot-swap-verification.md
  - ../../scripts/patch-asar.py
  - ../../scripts/test_patch_asar.py
  - ../../Sources/CodexSwitch/Services/CodexDesktopAppLocator.swift
  - ../../Sources/CodexSwitch/Services/CodexDesktopNativeChildCoordinator.swift
  - ../../Tests/CodexSwitchTests/DesktopAuthPatchTrustTests.swift
version_control:
  branch: codex/chatgpt-hot-swap-20260908
  status: staged-awaiting-ci-and-activation
  last_updated: 2026-09-08
---

# Unified ChatGPT Hot-Swap Repair

## Contract

Scope is Mac-only. The user explicitly deferred Computer Use repair and requires
the VPS to remain unchanged. Local re-signing is authorized for this repair;
it is not evidence of Computer Use compatibility.

An authenticated account transition must preserve the mounted application,
composer draft, selected task, and in-flight work. Full-token backend reload
requires process-bound SIGHUP acknowledgement; a marker or successful signal
alone does not prove the user-facing transition. Real logout remains supported.
Usage-limit recovery must retry only after a verified account handoff.

## Observed State

- Installed ChatGPT 26.901.51231 (8109) is OpenAI-signed and its renderer lacks
  the CodexSwitch auth transition patch.
- The current desktop has both an SSH connection to the VPS and a local
  prepared stdio app-server child. Preserve both during inspection.
- Automatic ASAR patching is mechanically disabled to preserve signed
  Computer Use ancestry. An explicit patch must not silently claim equivalent
  Computer Use readiness after changing that ancestry.
- The installed renderer uses a priority-aware auth hook that the older
  patcher does not recognize. Its null-auth callback immediately invokes
  logout; the replacement preserves authenticated state while confirming
  logout against a fresh account read.
- VPS behavior is outside this repair. No VPS deployment, restart, or
  configuration change is required or authorized by this plan.

## Replay And Readiness

1. Extract the exact installed renderer into disposable staging only.
2. Reproduce each incompatible minified shape with a bounded semantic fixture.
3. Exercise authenticated transitions, null-status races, overlapping reads,
   confirmed logout, and task/draft preservation before activating a patch.
4. Keep backend identity, frontend delivery, renderer handling, and Computer
   Use signing evidence distinct. Fail closed when a stage is unproven.
5. Run focused deterministic tests and the appropriate complete CI suites.

The priority-aware fixture covers shared account reads, overlapping events,
late null responses, real logout, cache invalidation, and callback cleanup.
Its draft/task checks are simulated UI evidence, not a live application canary.

`scripts/patch-asar.py --stage-auth-only` requires an app copy outside
`/Applications`, patches only auth and the native updater guard, checks the
renderer syntax, and signs the result. The signed Info.plist binds the full
ASAR digest and patch version. CodexSwitch accepts that explicit patch only
after Apple-issued signature verification and full metadata validation;
ad-hoc and unrelated re-signed applications remain ineligible for bootstrap.

## Activation Boundary

Never modify or re-sign the running ChatGPT bundle. Prepare changes and a
rollback artifact first, then obtain a controlled quit/reopen boundary from the
user. Do not force a production account change, spend a reset, restart a VPS
backend, or erase a journal as a test. A live transition canary must use a
disposable task and explicitly coordinated account transition.
