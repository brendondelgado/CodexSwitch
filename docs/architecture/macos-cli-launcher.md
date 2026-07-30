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
  - ../../Sources/CodexSwitch/App/AppDelegate.swift
  - ../../Sources/CodexSwitch/Services/AccountActivationTransaction.swift
  - ../../Sources/CodexSwitch/Services/SingleInstanceLock.swift
  - ../../Sources/CodexSwitch/Services/AppRelaunchPlanner.swift
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
  last_updated: 2026-07-29
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
4. Acquire a shared advisory lease on both prepared runtime executable inodes
   through the generation's attested `codexswitch-cli` control binary.
5. Execute the managed runtime while preserving those lease descriptors for
   `codex` and inherited `codex-code-mode-host` processes.
6. Fail with an actionable repair message when the selected unit is missing or
   its generation cannot be leased.

`CODEX_CLI_PATH` is output from repair for other clients; it is not an
unchecked launcher fallback.

Local CLI authentication has one visibility boundary. The Mac menu process
does not publish a changed configured account until the matching account store
and `~/.codex/auth.json` generation have both been committed, synchronized, and
read back under the activation lease. Any CLI launched after that publication
therefore reads the new generation immediately. A running CLI can still require
one explicit exit when runtime reload is unavailable, but a newly launched or
resumed CLI must never require a second exit to catch a delayed auth-file write.

Only one CodexSwitch menu process may perform that commit. The app bundle
prohibits multiple instances, startup takes a per-user advisory lease before
services begin, duplicate termination skips persistence, and relaunch helpers
ask LaunchServices to reopen the existing bundle without forcing `open -n`.

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

Prepared-generation retention takes nonblocking exclusive leases on both
runtime executable inodes before deletion and also inventories live macOS
process mappings by path, device, and inode for compatibility with historical
launchers. A shared lease or matching live `codex` /
`codex-code-mode-host` mapping protects the complete generation. Inventory or
lease uncertainty fails before any retention mutation. This closes both the
already-running case and the launch-versus-retention race.

A historical process may outlive an attempt directory that an older updater
already unlinked. macOS then keeps the mapped executable alive while
`proc_pidpath` returns `ENOENT`. Retention may ignore that process only when its
command path names a valid attempt beneath the canonical prepared root and the
exact attempt directory is proven absent with a no-follow metadata check.
There is no remaining on-disk generation to protect. An existing attempt,
unexpected path shape, or metadata error remains a fail-closed inventory
failure.

Retention confirmation uses the same-user process inventory, not the narrower
auth-reload target filter. A live `codex-code-mode-host` is intentionally not a
standalone reload target, but it still owns a mapped prepared-runtime inode and
must protect its complete generation. If the process is proven absent during
confirmation, retention may continue because no live mapping remains. A live
PID with a changed start, command, owner, or executable identity remains a
fail-closed inventory race.

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
