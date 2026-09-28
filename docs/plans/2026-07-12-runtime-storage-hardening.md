---
toc:
  - Operator Boundary
  - Local Resume Status
  - Goal
  - Wave Analysis
  - Tasks
  - Verification
  - Execution Handoff
cross_dependencies:
  - docs/architecture/session-retention-contract.md
  - crates/codexswitch-cli/src/codex_update.rs
  - crates/codexswitch-cli/src/runtime_storage.rs
  - crates/codexswitch-cli/src/codex_update/source_runtime_storage_patching.rs
  - patches/codex/0.144.1-runtime-storage-hardening.patch
  - docs/runbooks/runtime-storage-hardening-deployment.md
version_control:
  branch: main
  base_commit: 462eda79a5545eef7630b37985ecec0bb4502020
  status: resumed_local_implementation
  last_updated: 2026-07-17
operator_boundary:
  status: OPERATOR_DIRECTIVE_ACTIVE
  sha256: 4416348576c92302dc3836955482bd6fd86c62b2aa9b66e5c7228b0161fc14fd
  lines: 58
  bytes: 2724
---

# Codex Runtime Storage Hardening Implementation Plan

> **For Codex:** Execute serially in the authoritative dirty checkout. Do not install or enable the result until independent review and a separately authorized quiesced deployment.

## Operator Boundary

This plan is subordinate to the verified `OPERATOR_DIRECTIVE_ACTIVE` packet `/tmp/session-history-vps-only-boundary-20260713.md`, SHA-256 `4416348576c92302dc3836955482bd6fd86c62b2aa9b66e5c7228b0161fc14fd`, 58 lines / 2,724 bytes. The packet was read without retaining a Mac copy.

All session/log bytes and all per-session or content-derived metadata remain on the SIGNUL VPS. This includes raw/compressed bytes, titles, manifests, hashes, summaries, tags, embeddings, indexes, receipts, and searchable catalog data. Only aggregate non-content operational measurements without session identifiers may leave the VPS. Synthetic fixtures are mandatory for Mac development and tests. No live action is authorized.

## Local Resume Status

The 2026-07-13 implementation pause is superseded for local repository work only. The frozen operator boundary remains unchanged. This resume authorizes source, documentation, and synthetic-test changes in the Mac checkout; it does not authorize receiving VPS session/log content, reading per-session VPS metadata, installing or activating a runtime, changing VPS configuration, or performing any live compression, catalog write, migration, retirement, prune, or delete.

The generated source cache from the paused prototype is no longer present. Recovery therefore uses the pinned upstream Codex `0.144.1` source contract plus the durable CodexSwitch source-patcher mechanism. The current unrelated macOS artifact edits in the dirty checkout remain outside this task and must not be overwritten.

## Goal

Build a fail-closed, cross-platform storage layer that losslessly compresses inactive Codex rollouts without racing patched append writers and measures the global `logs_2.sqlite` hot budget across all processes and partitions without retiring log history or automatically executing physical SQLite maintenance.

Session history has a permanent lossless-only and VPS-only invariant: raw event bytes/order remain the source of truth; no retention path may call thread deletion or keep only summaries. Cold bytes remain as independent per-session deterministic zstd files on the VPS with a versioned VPS-local SQLite catalog, same-VPS reopen/full-restore verification, grace/pin/lease gates, and separate authorization before retiring a plain representation.

The durable owner is CodexSwitch. A generated `codex-source-stable-*` checkout is disposable build input only. The durable implementation is a reviewed CodexSwitch source-patcher module pinned to Codex `0.144.1` at upstream commit `44918ea10c0f99151c6710411b4322c2f5c96bea`. The updater must refuse an unknown version or source commit before applying any storage patch.

## Wave Analysis

The work has distinct review themes, but execution in this task is serial because the rollout writer, compressor, updater patch artifact, and compatibility diagnostics share a generated source tree and final patch file. Parallel edits would create avoidable patch-generation conflicts in the already-dirty parent checkout.

```text
Contract and fixtures
        |
        +--> Rollout lease and durable transitions --> thread-store archive compatibility
        |
        +--> Global logs maintenance -------------> storage status metrics
        |
        +--> Compressed inventory readers --------> deployment gate and packet
```

## Tasks

### Task 1: Freeze the contract and baseline

**Specialist:** storage-architecture
**Depends on:** None
**Produces:** This plan and the deployment runbook acceptance scorecard.

- Record the exact VPS baseline, measured zstd ratio, fail-closed defaults, rollback boundary, and authorization holds.
- Keep `local_thread_store_compression` disabled and treat all live VPS operations as out of scope.

### Task 2: Add cross-process rollout exclusion

**Specialist:** rust-storage
**Depends on:** Task 1
**Produces:** A stable per-thread OS advisory lease used by every append and representation-mutating path.

- Add `${CODEX_HOME}/.tmp/rollout-leases/<thread-id>.lock` under a VPS-private runtime root with permissions `0700` or stricter and crash-released advisory locking.
- Acquire before representation resolution; live writers hold the lease for their full lifetime.
- Stable readers, archive/unarchive operations, restore, and any future plain-representation retirement use the same lease.
- Compressor acquisition is non-blocking and reports active-lease skips.
- Reject symlinks, non-regular files, path escapes, aliases, and filename/SessionMeta identity mismatches.

### Task 3: Make compression and materialization durable

**Specialist:** rust-storage
**Depends on:** Task 2
**Produces:** Lossless `.jsonl` to `.jsonl.zst` and restore transitions.

- Use zstd level 3 with frame checksum, decoded byte-count and SHA-256 verification.
- Fsync temporary and installed files plus parent directories around atomic no-clobber installation and source retirement.
- Prefer plain files after dual-representation crash states; never retire the readable source on drift or failure.
- Scan only explicitly archived sessions, never the active session root. Run bounded passes every five minutes, require fifteen minutes since modification before candidate creation, retain the verified dual representation for a minimum 24-hour grace window, use two jobs, and stop each pass after fifteen minutes.

### Task 4: Fence archive lifecycle operations

**Specialist:** rust-storage
**Depends on:** Task 2
**Produces:** A disabled feature-on archive/unarchive bundle path under one lease contract while the default-off path preserves the exact upstream plain-only lifecycle.

- When the feature is explicitly enabled, acquire the thread lease before locating, reading as a stable representation, or moving either physical representation.
- Preserve compressed-only rollouts across archive/unarchive and materialize only when append resumes after the feature-on activation holds are closed.
- While the feature is absent/false, route archive and unarchive directly to the exact upstream plain-only helpers and never inspect or reconcile a bundle journal.
- Keep the CodexSwitch support CLI restore subcommand unconditionally `HELD`; it is not an executable substitute for a native leased, generation-CAS, crash-reconciled restore lifecycle.

### Task 5: Measure the global log budget without destructive pruning

**Specialist:** sqlite-runtime
**Depends on:** Task 1
**Produces:** Additive migration, bounded cross-process observation, generation-fenced cadence claims, and non-enforced budget signals.

- Retain existing per-partition behavior but do not introduce new retention deletion.
- Add a singleton SQL cadence claim and measure the 1 GiB/250,000-row global hot budget across all partitions.
- Run a due, single-flight observation at startup and after committed inserts without forcing the cadence; stale finalizers cannot overwrite a newer claim generation.
- A post-commit observation failure is reported separately and never changes a successfully committed insert into an insertion error.
- Set SQLite automatic WAL checkpointing to zero and expose the configured 128 MiB journal-size limit as non-enforced telemetry. Automatic checkpoint and incremental vacuum remain disabled/not-run pending separate implementation review and authority.
- A future orchestrator may retire exact exported rows only after a verified VPS-local lossless archive receipt and separate authorization; default retirement batch is zero.

### Task 6: Add compressed-aware inventory and guardrails

**Specialist:** runtime-integration
**Depends on:** Tasks 3 and 5
**Produces:** Native doctor coverage, VPS-local CodexSwitch storage status/doctor output, and aggregate-only Mac VPS usage compatibility.

- Deduplicate plain/compressed siblings with plain precedence and ignore temporary/malformed paths.
- Report logical rollout count, physical representation bytes, compressed population, dual-representation count, SQLite main/WAL bytes, page/freelist/live-page bytes, global log rows/bytes, and partition cardinality locally on the VPS. Any Mac-facing projection is aggregate-only, non-content, and contains no session identifiers.
- Verify every discovered Codex runtime contains the lease capability marker before reporting activation readiness.
- Keep per-session scans, decoded bytes, paths, hashes, titles, manifests, and catalog rows on the VPS. An aggregate-only VPS usage command may count `.jsonl.zst` files through bounded memory without returning identifiers or content.

### Task 7: Embed and guard the patch

**Specialist:** runtime-integration
**Depends on:** Tasks 2 through 6
**Produces:** Versioned source templates, a deterministic source-patcher module, and an updater source-identity guard.

- Require stable version `0.144.1` and upstream commit `44918ea10c0f99151c6710411b4322c2f5c96bea`.
- Verify the exact checked-out source commit, apply the embedded patch idempotently, and verify the frozen SHA-256 postimage denominator on the marker fast path, immediately after application, and again after every downstream source transformation.
- Refuse future upstream versions until the patch is intentionally rebased and tests are rerun.

### Task 8: Publish VPS-local archive coordination contracts

**Specialist:** runtime-integration
**Depends on:** Tasks 3, 5, and 6
**Produces:** Versioned VPS-local manifest/catalog schemas, deterministic object identity, eligibility state machine, read-only list/search/show interfaces, and an explicitly held restore surface for the VPS orchestrator.

- Keep every session/log byte and all related metadata on the VPS; do not design or write an external store or Mac mirror.
- Keep the archive/catalog root private with permissions `0700` or stricter. Readers that require representation stability use the same per-thread lease as writers and representation transitions.
- Emit per-thread raw/compressed hashes and byte counts, host/project/time/title metadata, codec version, VPS-local identity, restore state, and gate evidence only into the private VPS-local manifest/catalog.
- Record total bytes `27,628,306,432`, local hot budget `8,000,000,000`, and potential eviction `19,628,306,432` only after all gates.
- Accept the explicitly frozen single-VPS failure domain. Do not design an external disaster-recovery path unless a future operator directive supersedes the boundary.

## Verification

- `cargo test -p codex-rollout 'compression::tests::' -- --nocapture`
- `cargo test -p codex-rollout bundle_move::tests -- --nocapture`
- `cargo test -p codex-rollout lease::tests -- --nocapture`
- `cargo test -p codex-rollout manifest::tests -- --nocapture`
- `cargo test -p codex-thread-store archive_thread -- --nocapture`
- `cargo test -p codex-thread-store unarchive_thread -- --nocapture`
- `cargo test -p codex-state runtime_storage -- --nocapture`
- Run the exact discovered F7 log-observer tests and the thread-deletion log-retention test by name; a zero-match filter is not evidence.
- `just test -p codex-cli`
- `just fix -p codex-rollout`
- `just fix -p codex-thread-store`
- `just fix -p codex-state`
- `just fix -p codex-cli`
- `just fmt`
- `cargo test -p codexswitch-cli runtime_storage -- --nocapture`
- `python3 -m unittest scripts.test_linux_resource_policy`
- Generate a clean pinned upstream tree and prove the source patcher applies idempotently and refuses the wrong commit.

The complete Codex workspace suite requires separate approval because shared runtime crates are changed. No live VPS validation is part of this local task.

## Execution Handoff

Execution stays in this dedicated task and remains local. The deliverable is ready for independent review when scoped tests, patch replay, task-owned diff inspection, and the deployment packet are complete. Activation, quiesced restart, one-time SQLite physical compaction, and release publication remain separate authorizations.
