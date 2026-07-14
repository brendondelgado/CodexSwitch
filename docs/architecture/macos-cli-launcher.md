---
title: macOS CLI launcher
description: Contract for validating and routing the managed Codex CLI without per-launch binary scans.
toc:
  - macOS CLI Launcher
  - Ownership
  - Prepared Runtime Binding
  - Validation Boundary
  - Launch Contract
  - Explicit Activation Flow
  - Automatic Update Boundary
  - Repair And Verification
cross_dependencies:
  - ../../Sources/CodexSwitch/Services/RuntimeHotSwapContract.swift
  - ../../Sources/CodexSwitch/Services/CodexVersionChecker.swift
  - ../../Tests/CodexSwitchTests/CodexVersionCheckerTests.swift
  - ../../crates/codexswitch-cli/src/codex_update.rs
  - ../../crates/codexswitch-cli/src/reload.rs
  - ../../Tests/Fixtures/RuntimeConvergence/hot-swap-markers-v3.json
  - ../../Tests/Fixtures/RuntimeConvergence/reload-contract-v3.json
  - macos-runtime-artifact.md
  - runtime-and-host-ownership.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-07-13
---

# macOS CLI Launcher

## Ownership

CodexSwitch owns the managed local Codex runtime and the two shell entrypoints
that route `~/.local/bin/codex` and the Homebrew-visible path to that runtime.
Rust publishes both entrypoints as identical static bridges to one managed
launcher. Swift observes and verifies that route; it never rewrites it.

Remote `--remote` invocations may route to the separately synchronized remote
client. Local invocations never fall back to a stock, environment-provided, or
historical fork binary.

## Prepared Runtime Binding

The updater JSON report is the only authority for the prepared runtime. A
`ready_to_install` report must provide its exact `preparedBinaryPath`; the Mac
menu app never reconstructs a candidate as `prepared-codex/<version>/codex`,
scans version directories, or searches stock and historical runtime locations.
Prepared generations are attempt-scoped, so the current path shape is
`prepared-codex/<version>/<attempt-id>/codex`.

Before activation, the reported path must be absolute and normalized, remain
inside the managed prepared-runtime root with the reported version and one
attempt-id component, and name an executable regular file rather than a
directory, symlink, or special file. The attempt id is the updater-generated
simple UUID. Missing or invalid state is terminal for that activation attempt;
the menu app does not substitute a nearby generation.

## Validation Boundary

Runtime validation happens before a launcher is installed or repaired. That
validation proves the native executable shape, required hot-swap and goal
markers, executable `codex-code-mode-host` companion, and launch health.
The marker contract is convergence v3: the shared runtime markers include
`codexswitch-runtime-convergence-v3` and
`codexswitch-runtime-rotation-handoff-v1`, while the external app-server and
local interactive paths respectively require `codexswitch-hotswap-contract-v3`
and `codexswitch-hotswap-cli-contract-v3`. Swift, Python, and Rust validators
must reject every former v2/v1 combination.

The launcher is not a validator. It must not run `strings`, `file`, `awk`,
`grep`, or `codex --version` during normal invocation. Repeating full binary
inspection on every command adds hundreds of megabytes of reads and makes
interactive startup depend on expensive mutable probes.

## Launch Contract

The generated launcher performs only bounded, constant-time routing:

1. Detect whether arguments explicitly request remote mode.
2. For remote mode, require and execute the synchronized remote client.
3. For local mode, require the prevalidated managed executable and its
   executable companion.
4. Execute the managed runtime with the CodexSwitch plugin override.
5. Fail with an actionable repair message when the selected unit is missing.

`CODEX_CLI_PATH` is output from repair for other clients; it is not an
unchecked launcher fallback.

## Explicit Activation Flow

The canonical artifact installer performs this ordered handshake:

1. Independently verify all four GitHub build attestations and the complete
   artifact manifest before executing the downloaded control plane.
2. Run `codexswitch-cli activate-macos-runtime-artifact --directory <path>`.
   Rust holds one updater lease across staging, recovery, activation, and every
   launcher write.
3. Require an `installed` report bound to the manifest's exact source commit,
   upstream commit, patch digest, runtime version, and prepared generation.
4. Verify, without rewriting, that both static bridges name the same managed
   launcher and that it names the exact prepared generation.
5. Revalidate the exact reported generation and publish `CODEX_CLI_PATH` before
   presenting success.

The standalone `install-prepared-codex` recovery path remains available for an
already staged generation, but it must revalidate the retained manifest. An
`idle`, `preparing`, `installing`, `failed`, or still-`ready_to_install` result
cannot be reported as a successful artifact activation. A path mismatch or
missing regular file also fails closed.

## Automatic Update Boundary

The Mac menu app may automatically run only the bounded metadata command
`codexswitch-cli check-codex-update --json` and report that a newer managed
runtime is available. It must never invoke `auto-install-codex-update`, pass
`--prepare`, invoke `install-prepared-codex`, compile Codex, clean build targets,
replace a runtime, or repair launchers from an automatic timer. Remote build
and local activation are explicit operator actions performed after storage,
provenance, and live-session checks. Source compilation on the Mac is
prohibited.

An available update therefore produces a deferred, actionable status. It does
not become an automatic build merely because the current managed runtime is
missing or incomplete.

## Repair And Verification

Post-install verification accepts only the exact attempt-scoped path captured
from the ready updater report. Rust has already journaled and read back the
control-plane binary, both static bridges, and the managed launcher. Swift checks
that route and publishes the stable local bridge through launchd; it cannot
repair, select, or substitute a runtime. Periodic missing-runtime checks may
observe the route and schedule metadata refresh only.

Tests assert the attempt-scoped binding, rejection of the former guessed
`<version>/codex` path, explicit install command ordering, metadata-only timer
behavior, bridge-to-managed route agreement, missing-unit failure, and the
absence of per-launch binary or version probes.
