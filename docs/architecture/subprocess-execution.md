---
title: Subprocess execution
description: Bounded output, timeout, reaping, and actor-isolation contract for local helper processes.
toc:
  - Subprocess Execution
  - Scope
  - Capture Contract
  - Timeout Contract
  - Call-Site Contract
  - Verification
cross_dependencies:
  - ../../Sources/CodexSwitch/Services/ProcessRunner.swift
  - ../../Tests/CodexSwitchTests/ProcessRunnerTests.swift
  - runtime-and-host-ownership.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-07-13
---

# Subprocess Execution

## Scope

`ProcessRunner` is the shared boundary for bounded local commands used by
runtime discovery, diagnostics, repair, and installation. It is not a shell
interpreter and receives an executable path plus an argument array.

## Capture Contract

Standard output and standard error are drained concurrently so either stream
can exceed the operating-system pipe capacity without deadlocking the child.
Each retained stream has a fixed byte limit. Additional bytes are discarded
while the pipe continues to drain, and the result reports truncation.

The runner never calls an unbounded `readToEnd` after timeout or termination.

## Timeout Contract

At the deadline, the runner marks the result timed out, requests graceful
termination, escalates to `SIGKILL` after a short grace period, and performs a
bounded wait for process termination and reader shutdown. A timed-out child
must not remain running after the runner returns.

## Call-Site Contract

The synchronous API is permitted only from a background executor or a context
whose bounded wait is explicitly acceptable. App launch, menu updates, timer
callbacks, and other main-actor paths dispatch subprocess work away from the
main actor and publish only the completed result back to UI state.

## Verification

Tests saturate both pipes beyond their retention caps, assert truncation and
prefix preservation, exercise timeout escalation, and prove the child PID is
gone before return. Main-actor call sites are reviewed separately because a
bounded runner can still freeze UI when invoked from the wrong executor.
