---
title: CodexSwitch clean-code recovery
description: Audit and remediation contract for reliable Mac and VPS account switching, quota handling, runtime reloads, updates, and remote workflows.
toc:
  - Intent
  - Non-negotiable contracts
  - Target architecture
  - Remediation order
  - Verification gates
  - Deletion and consolidation candidates
cross_dependencies:
  - Sources/CodexSwitch/App/AppDelegate.swift
  - Sources/CodexSwitch/Models/QuotaSnapshot.swift
  - Sources/CodexSwitch/Services/KeychainStore.swift
  - Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - crates/codexswitch-cli/src/account_store.rs
  - crates/codexswitch-cli/src/daemon.rs
  - crates/codexswitch-cli/src/reload.rs
  - scripts/codex-vps
  - scripts/patch-asar.py
  - docs/runbooks/codexswitch-hot-swap-verification.md
version_control:
  branch: main
  base_commit: 664edf6
  status: active
  last_updated: 2026-07-12
---

# CodexSwitch Clean-Code Recovery

## Intent

Make CodexSwitch predictable, small enough to reason about, and safe to operate on both the Mac and the SIGNUL VPS. Correctness must come from explicit state-machine contracts and deterministic tests, not polling luck, process-name guesses, UI labels, or duplicated policy code.

This document authorizes repository work only. It does not authorize restarting live Mac or VPS sessions, patching the installed ChatGPT app, consuming banked resets, changing account credentials, deleting history, or deploying to the VPS without a separately verified deployment gate.

## Non-negotiable Contracts

1. **One state owner per host.** A host has one account/quota/reset coordinator. UI, CLI, status, and remote helpers are clients of that coordinator rather than independent whole-file writers.
2. **One cross-language account-store protocol.** Every writer uses the same lock, generation, validation, atomic replacement, and recovery rules. The store must contain unique account identities and exactly one active account when non-empty.
3. **Account activation is a recoverable transaction.** Account state, complete token set, runtime reload request, acknowledgement, and rollback evidence belong to one journaled operation.
4. **Reset redemption is durable and globally serialized.** Persist the selected credit, request UUID, inventory generation, quota generation, owner, attempt state, and reconciliation deadline before the network request. Never infer success from a missing response, and never spend again until inventory and quota reconcile.
5. **Quota windows are optional capabilities.** Paid plans may temporarily expose only a weekly window. Missing five-hour data is not zero usage, a placeholder five-hour window, or an error. Unknown windows never become synthetic available capacity.
6. **Status is observational.** `status`, `doctor`, `list`, `help`, and connection probes do not install, heal, start, restart, rewrite, consume, or delete anything.
7. **Process identity is stable.** Signals require PID plus start time and executable identity revalidation immediately before delivery. Broad `pkill` patterns are prohibited.
8. **Desktop patching and updating are staged transactions.** Modify and sign a complete staged app, verify the versioned patch manifest and launchability, then atomically replace the installed bundle with crash recovery.
9. **Live sessions win over maintenance.** Updates may prepare future runtime generations while work is active, but activation and service restarts require an idle/readiness gate.
10. **No unbounded storage producers.** Backups, logs, build roots, downloaded apps, staging directories, and token-bearing recovery copies require semantic change detection, retention, and startup cleanup.

## Target Architecture

### Core Domain

Define one versioned domain contract for:

- account identity and subscription tier;
- optional quota windows keyed by semantic kind (`fiveHour`, `weekly`, or future server-advertised kinds);
- authoritative quota freshness and runtime-limit evidence;
- reset inventory, redemption journal, and reconciliation;
- activation transaction and runtime convergence result.

Swift and Rust may keep platform adapters, but policy behavior must be proven against the same language-neutral JSON fixtures. A missing window is represented by absence, never by a fabricated `0% used` window.

### Mac

- `CodexSwitchApp` owns presentation only.
- An account coordinator owns account state, polling, reset decisions, activation, and persistence.
- A desktop integration coordinator owns ChatGPT discovery, reload, staged patching, and staged updates.
- A VPS client owns remote status and explicit remote commands; it cannot write local account state implicitly.
- `AppDelegate` becomes lifecycle wiring instead of a policy and maintenance god object.

### VPS

- One Rust daemon owns the VPS account store, quota polling, reset journal, and active account.
- Systemd owns process lifecycle; helper scripts do not silently start or restart services.
- The app-server exposes authoritative readiness with an auth fingerprint acknowledgement.
- `codex-vps` is a thin transport/client command. Setup, repair, connection, status, and session attachment are separate explicit operations.
- SecureDrop and knowledge sync use immutable transfer claims, hashes, generations, and conditional deletion.

## Remediation Order

### Phase 0: Containment

- Validate and safely pass every remote thread/archive identifier.
- Disable implicit rollout healing until the documented lease exists.
- Prevent concurrent patch transactions.
- Stop reset redemption from continuing after an external inventory decrement or an unresolved prior attempt.
- Remove the non-core Hermes authentication integration from all CodexSwitch swap, import, daemon, TUI, and Mac paths without touching Hermes itself.

### Phase 1: State Integrity

- Implement the shared account-store lock/generation protocol.
- Enforce account uniqueness and one-active-account invariants on load and save.
- Journal account activation and reset redemption before external effects.
- Persist consumed-credit state before reload attempts.
- Separate transient token-refresh failures from permanent reauthentication failures.

### Phase 2: Weekly-Only Quotas

- Parse windows by server data and duration, not fixed primary/secondary assumptions.
- Make five-hour and weekly windows optional in the domain model.
- Base usability, polling, reset protection, and pooled capacity only on present authoritative windows.
- Render only present windows in the Mac UI and remote status output.
- Prime only windows that exist and still require activation.
- Add fixtures for legacy two-window, weekly-only, reordered, missing, placeholder, and unknown-window responses.

### Phase 3: Runtime Convergence

- Pass the selected auth path through every reload and acknowledgement path.
- Revalidate process identity before each signal.
- Require nonce-bound complete-token fingerprints for readiness and convergence.
- Make reload failure a durable transaction state with an explicit retry or rollback path.

### Phase 4: Desktop Transactions

- Consolidate patching into one coordinator and one versioned patch manifest.
- Patch, sign, verify, and launch-check a staged app before replacement.
- Make appcast cache and validators transactional.
- Recover hidden `/Applications` and temporary staging leftovers on startup.
- Ensure only one updater owns downloads and installation.

### Phase 5: Deletion and Simplification

- Remove dormant patching and compatibility stacks after their callers/tests migrate.
- The dormant `CodexDesktopAppPatcher`, `CodexAutoPatchMonitor`, process classifier, state store, and self-referential tests have been removed; shared app discovery now lives in `CodexDesktopAppLocator`.
- Replace embedded shell/Python mutation blocks with typed helpers or structured parsers.
- Split `AppDelegate`, `codex_update.rs`, and `codex-vps` along ownership boundaries.
- Remove source-text-only tests in favor of deterministic behavioral fixtures.

## Verification Gates

1. **Pure domain replay:** shared fixtures produce identical Swift and Rust decisions.
2. **Persistence fault injection:** failures before and after every rename preserve a recoverable old or new generation, never a split state.
3. **Reset replay:** timeout, malformed response, external decrement, stale quota, and delayed propagation consume at most one credit.
4. **Process replay:** PID reuse, stale ACK, wrong executable, missing token fields, and custom auth paths cannot report convergence.
5. **Desktop transaction replay:** interruption at every patch/sign/install stage leaves a launchable installed app or a recoverable journal.
6. **Remote helper integration:** fake SSH/systemd/rsync/tar fixtures prove informational commands are read-only and inputs cannot inject commands.
7. **Storage soak:** repeated healthy polling and update checks have bounded disk growth.
8. **Live canary:** deploy to an idle VPS generation first, verify readiness and reconnect, then activate Mac integration without terminating active sessions.

## Deletion and Consolidation Candidates

- Unused desktop PID/environment helpers and obsolete reload compatibility wrappers.
- Duplicated launcher-script bodies in `CodexVersionChecker` (consolidated into one bounded router).
- Fabricated quota-window fallbacks and fixed two-window UI assumptions.
- Implicit mutation paths in `codex-vps --check`, list, resume, and attachment.
- Source-text assertion tests that do not execute behavior.
- Documentation and runtime-storage references to implementations that do not exist in the repository.
