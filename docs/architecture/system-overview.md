---
title: CodexSwitch system overview
description: Canonical component, responsibility, persistence, and data-flow architecture.
toc:
  - CodexSwitch System Overview
  - Mission
  - Responsibility Boundary
  - System Topology
  - Core State
  - Shared Account-Store Protocol
  - Control Flow
  - Component Map
  - Failure Model
  - Design Decisions
cross_dependencies:
  - ../../Sources/CodexSwitch/App/AppDelegate.swift
  - ../../Sources/CodexSwitch/Models/AccountManager.swift
  - ../../Sources/CodexSwitch/Models/QuotaSnapshot.swift
  - ../../Sources/CodexSwitch/Services/KeychainStore.swift
  - ../../Sources/CodexSwitch/Services/SecureAtomicFileTransaction.swift
  - ../../Sources/CodexSwitch/Services/RateLimitResetService.swift
  - ../../Tests/CodexSwitchTests/KeychainStoreTests.swift
  - ../../Tests/CodexSwitchTests/SharedPolicyFixtureTests.swift
  - ../../Tests/Fixtures/Policy
  - ../../crates/codexswitch-cli/src/daemon.rs
  - ../../crates/codexswitch-cli/src/account_store.rs
  - ../../scripts/codex-vps
  - ../../scripts/patch-asar.py
  - ../../scripts/test_patch_asar.py
  - quota-and-reset-policy.md
  - runtime-and-host-ownership.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-07-13
---

# CodexSwitch System Overview

## Mission

CodexSwitch keeps Codex work running across paid accounts without hiding state transitions or risking active sessions. Reliability comes from a small state machine and explicit host boundaries, not from many polling loops or broad process restarts.

The product has four core capabilities:

1. Account inventory and token storage.
2. Quota and banked-reset observation.
3. Policy-driven account selection and activation.
4. Verified runtime reload and operator-visible status.

## Responsibility Boundary

CodexSwitch owns Codex account coordination. It does not own unrelated agent products, terminal applications, or general machine maintenance.

In scope:

- CodexSwitch account records and quota snapshots.
- Complete Codex token activation in `~/.codex/auth.json`.
- Verified Codex CLI and app-server reloads.
- Mac menu-bar presentation of the same domain state.
- VPS daemon operation and remote status transport.
- Banked-reset inventory and redemption safety.
- Bounded CodexSwitch-created logs, backups, downloads, and staging data.

Out of scope:

- General ChatGPT browser session management except a narrowly diagnosed desktop partition repair.
- Hermes or other third-party agent authentication.
- Destructive cleanup of user projects, conversations, or arbitrary caches.
- Starting, killing, or repairing services as a side effect of a status command.
- Treating the Mac and VPS as one shared active account.

## System Topology

```text
                         read-only remote status
 Mac menu app  <-------------------------------------  VPS coordinator
      |                                                     |
      | local activation                                    | VPS activation
      v                                                     v
 ~/.codex/auth.json                                  ~/.codex/auth.json
      |                                                     |
      | verified reload                                     | verified reload
      v                                                     v
 Mac Codex CLI / desktop app-server                 VPS CLI / app-server

              accounts.json + quota/reset state per host
```

Each host has its own coordinator and runtime activation transaction. `codex-vps` transports commands and status; it does not grant the VPS authority to rewrite Mac active state.

## Core State

### Account Record

An account has a stable local identity, provider account identity when known, plan, complete token bundle, quota snapshot, reset inventory, health state, and an active flag. A non-empty account store has exactly one active account.

### Quota Snapshot

A snapshot contains zero or more typed windows, global allowance state, fetch time, and source metadata. Five-hour and weekly windows are optional. Missing data remains missing.

### Activation Operation

Activation records source and target account, store generation, complete token hash, runtime targets, acknowledgements, and rollback evidence. Account selection is not complete merely because the active flag changed.

### Reset Attempt

A reset attempt records account identity, selected credit, request identity, starting inventory and quota generations, owner, timestamp, and reconciliation state before any network mutation occurs.

## Shared Account-Store Protocol

Swift and Rust share `~/.codexswitch/accounts.json` and therefore implement the same host-local file protocol. The lock coordinates cooperating writers, while path validation and generation checks defend against unsafe filesystem state and non-cooperating changes.

1. Resolve the store parent one descriptor-relative component at a time with no-follow directory opens, validating every opened component. Root-owned system ancestors must not be group- or other-writable unless they are sticky shared directories such as `/tmp`; sticky shared ancestors must be root-owned. Current-user-owned ancestors must not be group- or other-writable, and ancestors owned by any other user are rejected. The final store parent must be current-user-owned and is normalized to mode `0700`. When it does not exist, create it with `mkdirat`, inspect the no-follow entry, set `0700` with anchored `fchmodat` before reopening, and prove the reopened descriptor has the created identity. This remains safe when a hostile umask initially produces mode `000` and never trusts a traversed symlink. Open `accounts.json.lock` with `O_NOFOLLOW | O_CLOEXEC`, require a regular file owned by the current user, set mode `0600`, and take an exclusive `flock`.
2. Read `accounts.json` through a no-follow descriptor. Missing state is represented distinctly from every other open, metadata, read, decode, or validation error. Legacy Keychain reads follow the same tri-state rule: `errSecItemNotFound` alone means missing, `errSecSuccess` requires a `Data` payload, and a non-data success result or every other status is an error that must propagate.
3. A snapshot generation is the lowercase SHA-256 digest of the exact stored bytes, or the literal `missing` when the file does not exist. Immediately before any mutation, reread the store while holding the cooperative lock and reject a generation mismatch.
4. Every decoded and proposed store must have unique nonempty provider account IDs, unique non-nil local UUIDs, and exactly one active account unless the store is empty. Persistence and placeholder sanitization preserve the optional quota-window shape: a weekly-only snapshot remains weekly-only and must not gain or lose a five-hour window.
5. Commit through a unique same-directory temporary file created with exclusive, no-follow, close-on-exec mode and permissions `0600`. Complete the write loop, `fsync` the temporary file, atomically rename it over the store, and `fsync` the parent directory.
6. After commit, read back through the no-follow path, decode and validate again, and require both exact bytes and generation to equal the committed payload before reporting success.
7. Migration cleanup removes the legacy Keychain credential only after its replacement file has completed atomic rename, parent-directory `fsync`, no-follow readback, decode and validation, and exact byte-generation proof. Keychain cleanup is itself a fallible transaction step: only `errSecSuccess` and `errSecItemNotFound` are success, while every other status is propagated. A cleanup failure reports operation failure but leaves the proven replacement file authoritative and recoverable.
8. Explicit user-requested deletion is intentionally destructive across both stores and never reports success until legacy cleanup is confirmed successful or already missing. When `accounts.json` is authoritative and accounts remain, commit and read back the reduced file first, then clean up legacy credentials; a commit failure preserves both prior authorities, while a cleanup failure reports failure and leaves the reduced file authoritative. Deleting the last account and delete-all generation-check and safely unlink the file, `fsync` the parent directory, prove no-follow readback is missing, and only then remove the legacy Keychain credential. They do not write an empty replacement `accounts.json`; failed absence proof preserves the legacy credential, and failed cleanup reports failure with the legacy credential remaining recoverable.
9. Deleting one account from a legacy-only store does not run migration first. Decode and validate the legacy records in memory. If the requested account is the last matching record, durably prove `accounts.json` remains missing and then remove the legacy credential without ever creating the file. If validated records remain, commit and read back only those records before removing the legacy credential. A missing match or any failure before the final absence or replacement proof leaves the legacy credential unchanged. If cleanup fails after proof, the operation fails: an absent file leaves the legacy data recoverable, while a proven replacement file remains authoritative and prevents remigration.

The protocol provides durable compare-and-swap semantics for one host. It does not make Mac and VPS account stores a shared authority.

The same Swift secure-file primitive protects `~/.codex/auth.json` and the reset-attempt journal. Each file has its own same-directory lock and generation, but all use the descriptor-anchored path policy, unique exclusive temporary files, file and directory `fsync`, atomic rename, and exact-byte no-follow readback. Structured callers decode and validate the proven bytes before publishing success.

Account-store I/O runs on a serial persistence actor, never on `MainActor`. User-visible mutations such as import, activation, deletion, and reset reconciliation await durable completion. Telemetry-only quota, subscription, and reset-inventory snapshots are coalesced to the newest pending account snapshot; shutdown explicitly flushes that pending snapshot before termination completes.

## Control Flow

### Observation

1. The host coordinator reads a validated account-store generation.
2. It fetches quota and reset inventory without changing active state.
3. It parses only windows actually returned by the service.
4. It publishes a new immutable observation generation and queues one coalescible persistence snapshot.

### Decision

1. Evaluate whether the active account is usable using the canonical injected-time freshness policy.
2. Rank immediately usable paid accounts through the one shared eligibility and ranking implementation.
3. Consider a banked reset only when switching cannot preserve a better outcome.
4. Suppress a reset near a natural weekly recovery unless no usable alternative exists and capacity is required now.

### Activation

1. Acquire the host account-store operation lock.
2. Revalidate source state and target eligibility.
3. Persist the target account and complete token bundle atomically.
4. Read back and verify the committed identity and token hash.
5. Reload only verified runtime targets.
6. Record acknowledgement or actionable degraded state.
7. Publish status after commit, never before it.

### Desktop Compatibility Patch

The desktop patcher discovers renderer behavior by content, not hashed chunk
names. Fast Mode has two supported bundle shapes: a combined chunk where the
account entitlement gate and service-tier option mapper live together, and a
split chunk layout where the option mapper is separate from the entitlement
gate. In both layouts CodexSwitch may synthesize missing bundled-model tier
metadata only at the unique service-tier option mapper. It must never weaken,
replace, or manufacture the account entitlement gate.

An unknown layout is a fail-closed compatibility failure. The patcher must
leave the installed archive untouched, gain a fixture from the current stock
build, and pass the regression suite before installation is retried.

Model compatibility hooks are discovered independently for the same reason.
The readable-label and power-preset renderer may live in a different chunk
from the server-model availability and reasoning-effort filters. A release is
patchable only when each required behavior has one unambiguous owner; hashed
filenames and historical chunk co-location are not part of the contract.

Nested official helpers are preserved only when strict code-signature checks,
the OpenAI Team ID, and the expected OpenAI entitlement namespace all agree.
Gatekeeper acceptance is an additional signal. The exact macOS beta
`internal error in Code Signing subsystem` assessment failure is classified as
unavailable, not as a signature rejection; it is advisory only after all three
authoritative signature checks pass. Every other failed assessment remains a
hard rejection.

## Component Map

| Layer | Mac | VPS/Linux | Responsibility |
| --- | --- | --- | --- |
| Presentation | SwiftUI views, status bar | CLI/status JSON | Render domain state and explicit commands |
| Coordination | `AppDelegate`, `AccountManager` during migration | Rust daemon | Own host-local observation and activation |
| Policy | Swift domain services during migration | Rust domain modules | Evaluate quota, ranking, reset, readiness |
| Persistence | `KeychainStore` file protocol | `account_store.rs` | Locked, validated, atomic account state |
| Runtime reload | desktop reload client and signal services | `reload.rs` | Verify identity, deliver reload, collect ack |
| Transport | `LinuxDevboxMonitor` | status endpoints | Read VPS state without taking Mac ownership |
| Operator entry | menu app and local CLI | `codexswitch-cli`, `codex-vps` | Explicit actions and diagnostics |

Swift and Rust implement host-specific policy adapters against one versioned
fixture contract in `Tests/Fixtures/Policy`. Both test suites must decode the
same files and prove equivalent outcomes for candidate ordering, optional quota
windows, natural-reset protection, terminal non-consumption, and uncertain
reset reconciliation. Presentation remains platform-specific.

## Failure Model

CodexSwitch assumes these failures are normal and recoverable:

- Quota windows disappear, change duration, or arrive in a new order.
- A quota fetch times out or returns stale data.
- A reset POST succeeds but its response is lost.
- Another process changes account state between decision and commit.
- A PID exits and is reused before a signal is sent.
- A runtime reload is accepted but acknowledgement is delayed.
- A download, patch, build, or install is interrupted.
- The Mac loses the VPS tunnel while local work continues.
- A deployed artifact is older than repository source.

The response is durable state, revalidation, bounded retry, and explicit degraded status. It is not repeated mutation until an error disappears.

## Design Decisions

- One owner per host prevents Swift, Rust, scripts, and remote monitors from racing whole-file writes.
- Optional quota windows prevent a temporary service policy change from becoming false exhaustion.
- Complete token bundles prevent access-token-only swaps from failing on the next refresh.
- Read-only diagnostics make `status` safe to run during incidents.
- Immutable staged releases make provenance and rollback observable.
- Bounded storage protects session continuity on machines with limited disk and memory.
- Legacy third-party auth bridges are separated from the switching core because they expand the secret and failure surface without improving Codex switching.
