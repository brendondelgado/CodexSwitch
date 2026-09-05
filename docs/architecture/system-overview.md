---
title: CodexSwitch system overview
description: Canonical component, responsibility, persistence, and data-flow architecture.
toc:
  - CodexSwitch System Overview
  - Mission
  - Responsibility Boundary
  - System Topology
  - Core State
  - Active Account Read Model
  - Mac Account Display Order
  - Shared Account-Store Protocol
  - Control Flow
  - Component Map
  - Failure Model
  - Design Decisions
cross_dependencies:
  - ../../Sources/CodexSwitch/App/AppDelegate.swift
  - ../../Sources/CodexSwitch/Models/AccountManager.swift
  - ../../Sources/CodexSwitch/Models/CodexAccount.swift
  - ../../Sources/CodexSwitch/Models/QuotaSnapshot.swift
  - ../../Sources/CodexSwitch/Services/KeychainStore.swift
  - ../../Sources/CodexSwitch/Services/SecureAtomicFileTransaction.swift
  - ../../Sources/CodexSwitch/Services/RateLimitResetService.swift
  - ../../Sources/CodexSwitch/Services/PoolAuthority.swift
  - ../../Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - ../../Tests/CodexSwitchTests/KeychainStoreTests.swift
  - ../../Tests/CodexSwitchTests/AccountManagerTests.swift
  - ../../Tests/CodexSwitchTests/SharedPolicyFixtureTests.swift
  - ../../Tests/Fixtures/Policy
  - ../../crates/codexswitch-cli/src/daemon.rs
  - ../../crates/codexswitch-cli/src/account_store.rs
  - ../../crates/codexswitch-cli/src/pool_authority.rs
  - ../../crates/codexswitch-cli/src/remote_authority.rs
  - ../../scripts/codex-vps
  - ../../scripts/patch-asar.py
  - ../../scripts/test_patch_asar.py
  - quota-and-reset-policy.md
  - runtime-and-host-ownership.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-09-04
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
- One VPS-authoritative desired provider account for the complete Mac/VPS pool.
- Mac menu-bar presentation of that authority state and each host's convergence.
- VPS daemon operation, authority persistence, and remote status transport.
- Banked-reset inventory and redemption safety.
- Bounded CodexSwitch-created logs, backups, downloads, and staging data.

Out of scope:

- General ChatGPT browser session management except a narrowly diagnosed desktop partition repair.
- Hermes or other third-party agent authentication.
- Destructive cleanup of user projects, conversations, or arbitrary caches.
- Starting, killing, or repairing services as a side effect of a status command.
- Allowing a Mac or VPS-local policy decision to replace the pool target without
  a VPS authority transaction.

## System Topology

```text
                    authority requests + observations
 Mac menu app  <------------------------------------>  VPS coordinator
      |                                               desired target + epoch
      | adopts fresh authority target                         |
      v                                                       v
 Mac activation journal                              VPS activation journal
      |                                                       |
      v                                                       v
 ~/.codex/auth.json                                  ~/.codex/auth.json
      |                                                       |
      | verified reload                                       | verified reload
      v                                                       v
 Mac Codex CLI / desktop app-server                 VPS CLI / app-server
```

The VPS coordinator is the sole authority for the desired provider account.
Each host still owns its local credential commit, activation journal, and
runtime reload. A VPS authority observation does not directly rewrite Mac
files; it authorizes the Mac coordinator to converge those files to the one
authority-selected target.

## Core State

### Account Record

An account has a stable local identity, provider account identity when known,
plan, complete token bundle, quota snapshot, reset inventory, health state, and
an active flag. A non-empty account store has exactly one active account. That
flag is a host-local credential projection used to verify activation commits;
it is never an independent source for the logical active account shown by the
product.

### Quota Snapshot

A snapshot contains zero or more typed windows, global allowance state, fetch time, and source metadata. Five-hour and weekly windows are optional. Missing data remains missing.

### Activation Operation

Activation records source and target account, store generation, complete token hash, runtime targets, acknowledgements, and rollback evidence. Account selection is not complete merely because the active flag changed.

### Pool Authority Record

The VPS persists one token-free authority record containing a monotonically
increasing epoch, exactly one desired provider account identifier, a bounded
request identifier for idempotency, phase (`stable`, `converging`, or
`degraded`), reason, timestamps, and bounded non-secret rotation outcomes. It
contains no access, refresh, or identity tokens. Host convergence is observed
separately against that one desired identity.

Only a transaction serialized through the VPS runtime lease and authority
journal lock advances the epoch. Mac manual and automatic swap requests are
remote-first authority requests. A repeated request or rotation operation
identifier returns the existing result, while a different request carrying a
stale expected epoch is rejected without changing authority or host credentials.
The Mac SSH transport config is token-free, mode `0600`, and separate from
readiness-notification enablement.

### Active Account Read Model

Every Mac presentation surface consumes one immutable active-account read
model derived only from the last accepted pool-authority observation. The model
contains exactly one provider account identifier, its monotonically increasing
authority epoch, and a freshness state (`current`, `stale`, or `unavailable`).
It never inspects account `isActive` flags, list position, quota movement,
runtime-current evidence, or plan ranking to choose an identity.

- A current observation exposes its provider identity and epoch as `current`
  only while authority transport and readiness configuration coherently report
  available. A fresh cached observation behind a disabled or unavailable
  readiness path is presented as `stale`, not current.
- When that observation ages out or authority transport becomes unavailable,
  the same provider identity and epoch remain visible as `stale`. Staleness may
  change styling and health text, but it cannot select or highlight a different
  account.
- Before any authority observation has been accepted, the model is
  `unavailable` and has no identity. The UI must show an unavailable target; it
  must not fall back to a locally configured account.
- A provider identity resolves to an account only when exactly one account
  record matches it. Missing or duplicate matches fail closed and produce no
  logical active account.
- Account ordering may place the resolved authority target first within its
  plan tier, but ordering cannot create a target. Likewise, local activation
  and runtime evidence are convergence details for that target, not alternative
  active-account sources.

This distinction lets local credentials and runtimes remain operational during
an authority outage without presenting their incidental state as pool truth.

One `authorityConfigured` predicate, derived from a valid remote endpoint,
governs transport publication, authority polling, credential convergence, and
readiness. The `Notify when VPS auto-swap is not ready` preference controls
notifications only; disabling that preference cannot disable credential sync
while leaving authority mutation enabled. A periodic authority reconciliation
compares non-secret account, credential-set, active-provider, and active-token
fingerprints before creating an encrypted bundle. Matching evidence performs no
remote mutation; mismatched evidence enters the normal journaled encrypted
credential-sync transaction.

### Mac Account Display Order

Mac account presentation sorts by `CodexAccount.planPriority` descending before
any health or authority preference: Pro, Pro Lite, Plus/other paid, then
Free/unknown. Plan aliases and unknown plans with an active subscription follow
that existing model. An expired subscription or token, exhausted quota, missing
quota, or reauthentication requirement cannot move an account below a lower
plan tier. Even a healthy Free account that is the resolved authority target
remains below Pro and other paid accounts.

Within each tier, retain the existing order: resolved authority target first,
immediately usable accounts next, descending `SwapEngine.score`, then the
earliest most-urgent quota reset. Exact ties retain input order. Local
`isActive` flags do not independently promote an account.

This is a read-only display contract in `AccountManager.sortedAccounts`.
Automatic rotation eligibility, candidate scoring, and candidate ordering stay
under the existing quota policy and `SwapEngine`; display position neither
selects nor activates an account. Regression coverage uses synthetic accounts
and explicit read models without reading or changing live account state.

### Reset Attempt

A reset attempt records account identity, selected credit, request identity, starting inventory and quota generations, owner, timestamp, and reconciliation state before any network mutation occurs.
When a remote authority endpoint exists, the VPS daemon is the sole automatic
reset owner and the Mac cannot start a local automatic attempt. A standalone
Mac with no remote authority endpoint may own local automatic redemption.

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

The protocol provides durable compare-and-swap semantics for one host. The
stores are not a shared filesystem and retain separate generations, but their
active selections must converge to the provider identity named by the VPS
authority epoch.

The same Swift secure-file primitive protects `~/.codex/auth.json` and the reset-attempt journal. Each file has its own same-directory lock and generation, but all use the descriptor-anchored path policy, unique exclusive temporary files, file and directory `fsync`, atomic rename, and exact-byte no-follow readback. Structured callers decode and validate the proven bytes before publishing success.

Account-store I/O runs on a serial persistence actor, never on `MainActor`. User-visible mutations such as import, activation, deletion, and reset reconciliation await durable completion. Telemetry-only quota, subscription, and reset-inventory snapshots are coalesced to the newest pending account snapshot; shutdown explicitly flushes that pending snapshot before termination completes.

## Control Flow

### Observation

1. The host coordinator reads a validated account-store generation.
2. It fetches quota and reset inventory without changing active state.
3. It parses only windows actually returned by the service.
4. It publishes a new immutable observation generation and queues one coalescible persistence snapshot.

### Decision

1. The VPS coordinator evaluates whether the authority target is usable using
   the canonical injected-time freshness policy.
2. It ranks immediately usable paid accounts through the canonical Rust
   eligibility and ranking implementation.
3. It considers a banked reset only when switching cannot preserve a better
   outcome.
4. It suppresses a reset near a natural weekly recovery unless no usable
   alternative exists and capacity is required now.
5. Mac usage-limit, token-invalidated, routine, and manual requests do not select
   or activate a local replacement first. They submit one idempotent authority
   request and await the resulting epoch.

### Activation

1. The VPS serializes a request against the current authority epoch.
2. It persists the new desired target and next epoch as `converging` before any
   host reports the new target current.
3. Each host independently acquires its account-store operation lock, validates
   that fresh authority epoch, and atomically persists the target account and
   complete local token bundle.
4. Each host reads back the committed identity and token hash, reloads only
   verified runtime targets, and records local acknowledgement or degraded
   evidence.
5. The Mac reports convergence for that exact epoch and target. Stale or
   contradictory reports cannot advance authority state.
6. The VPS publishes `stable` only when required host evidence agrees. Partial
   convergence remains `degraded` on the same desired target and does not choose
   another target automatically.

The VPS is always a required host. A Mac that is offline and not participating
is reported as offline/not required, so VPS standalone operation can become
stable. Once the Mac requests or begins adoption for an epoch, its convergence
result is tracked explicitly and cannot be replaced by credential-sync evidence.

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
| Pool authority | authority client | Rust daemon | Own the one desired provider target, epoch, and request idempotency |
| Host convergence | `AppDelegate`, activation services | Rust activation modules | Apply the authority target to local credentials and verified runtimes |
| Policy | Observation and standalone-only adapters | Rust domain modules | Evaluate quota and readiness on both hosts; rank/select on the VPS |
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
- The Mac loses the VPS authority connection while local credentials and
  sessions remain intact.
- A deployed artifact is older than repository source.

The response is durable state, revalidation, bounded retry, and explicit degraded status. It is not repeated mutation until an error disappears.

## Design Decisions

- One fixed VPS decision owner prevents Mac and VPS policy from selecting
  different accounts. One local effect owner per host still prevents Swift,
  Rust, scripts, and remote monitors from racing credential and runtime writes.
- A configured but unavailable authority fails closed for new Mac activation
  decisions. Cached authority state may be displayed as stale but cannot
  authorize another target.
- Optional quota windows prevent a temporary service policy change from becoming false exhaustion.
- Complete token bundles prevent access-token-only swaps from failing on the next refresh.
- Read-only diagnostics make `status` safe to run during incidents.
- Immutable staged releases make provenance and rollback observable.
- Bounded storage protects session continuity on machines with limited disk and memory.
- Legacy third-party auth bridges are separated from the switching core because they expand the secret and failure surface without improving Codex switching.
