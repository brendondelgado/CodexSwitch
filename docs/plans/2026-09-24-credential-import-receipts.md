---
title: Durable credential import receipts
description: Receipt-recovery contract, verified server fixtures, and pending live deployment gates.
toc:
  - Contract
  - Persistence And Replay
  - Mac Recovery
  - Legacy Supersession
  - Integration And Verification
  - Upgrade Compatibility
  - Explicit Legacy Supersession
cross_dependencies:
  - 2026-09-24-vps-reliability-repair.md
  - 2026-09-24-legacy-sync-operator-recovery.md
  - ../../crates/codexswitch-cli/src/main.rs
  - ../../crates/codexswitch-cli/src/credential_import_receipts.rs
  - ../../Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - ../../Tests/CodexSwitchTests/AppDelegateCredentialSyncTests.swift
version_control:
  branch: codex/vps-reliability-20260924
  base_commit: 7f60ba3c691ea9bafe91df66f0b8abc266a769b6
  status: verified-mac-installed-vps-protocol-not-deployed
  last_updated: 2026-09-28
---

# Contract

An import receipt proves a historical operation, not present-day credential or
runtime convergence. Receipt recovery must not import, reload, refresh, call a
provider, or manufacture success from current credentials. Preserve the full
existing authority-preserving monotonic merge and runtime activation protocol.

# Persistence And Replay

Use the existing secure-file implementation (owned regular files, no-follow,
0600, bounded reads, generation CAS, atomic replacement and fsync). The ledger
is adjacent to, and named after, the account store. A record binds a canonical
operation UUID, the exact incoming credential fingerprint, actual baseline,
store/auth path scope and the existing token-free receipt. No tokens, account
store images, bundle paths, passphrases, or provider responses are persisted.

New Mac requests pass `--receipt-baseline-fingerprint`; the VPS checks it under
the account-store lock before preparing the receipt/import. Older callers may
omit this optional precondition for compatibility, but their actual receipt
baseline must still match the held operation before Mac can accept it.
Rejection before intent persistence remains `missing`, not a durable rejection
receipt; Mac conservatively holds it for review. A future explicit non-execution
receipt must also guard against an outstanding original import process.

Under the runtime activation lease, reject duplicate operations before any
activation reconciliation. Persist an intent before replacing accounts.

Update 2026-09-28: publish completed as soon as the store and auth files are
committed and read back, not after runtime confirmation. The receipt attests
the credential effect; runtime convergence belongs to the activation barrier.
The original rule turned a committed import whose runtime reload could not
confirm (the VPS had zero app-servers during a release activation) into a
permanent `pending` record, a nonzero exit, and a Mac hold, although the
credentials were durably committed. The importer now prints the completed
receipt and exits 0 while reporting pending runtime convergence on stderr.
Pending intents of other operations no longer block new imports: under the
exclusive runtime lease their importer has ended, their IDs still reject replay,
and the monotonic merge keeps later imports safe. Persist completed before
printing the success response. A lost SSH reply is recoverable from the
completed record even after later rotation.

The read-only `credential-import-status` command requires operation UUID,
baseline fingerprint and incoming fingerprint. It returns a strict versioned
envelope: `completed` with the historical receipt, `pending` without a receipt,
or `missing` without a receipt. Mismatched bindings or invalid storage fail
closed. Status never creates directories/locks, performs cleanup, or reloads.
Reissuing update-bundle with an existing operation cannot mutate again; callers
must use status to replay. Even an expired bundle is unnecessary for status.

Crash after intent but before completed is intentionally pending, including a
crash after the credential commit but before completion persistence. Do not
infer its historical outcome from a current matching store. Since 2026-09-28 the
Mac supersedes such a `pending` operation (outcome unknown) once its importer and
staging are absent, then re-baselines with a fresh operation; see
`../architecture/runtime-and-host-ownership.md`. Automatic crash recovery
would require activation-journal operation binding outside this workstream.

Retention is bounded to 1024 operations and 8 MiB, with individual receipts at
most 64 KiB. No automatic eviction: deleting completed UUIDs would permit an old
request to execute again. Capacity exhaustion fails before mutation and needs
review. Future rolling retention requires an epoch/expiry protocol that rejects
retired requests; silently dropping IDs is not an acceptable implementation.

# Mac Recovery

Keep exact current-evidence reconciliation distinct from recovered historical
completion. A strict operation-bound completed status can close the uncertainty
of an old operation after stage absence is proven, even when current evidence
has drifted or is unavailable. It must not create a convergence proof or mark
the old local fingerprint synchronized. Fresh sync must start with a fresh
operation and current baseline/authority observation. Persist a recovered receipt
with the existing operation-CAS journal API before releasing the old hold.

Missing/pending/unsupported status never proves non-execution of a held
operation. The one exception is observed directly by the caller: a `missing`
status read right after the import command's own completed nonzero exit proves
that importer finished without an intent, so it is a rejection, not a hold. Legacy exact
current-state checks remain available separately, but are not historical proof.
Reject unknown fields, malformed states, mismatched UUID/baseline/incoming,
wrong target, staging remnants, and conflicting local/remote receipts.

# Legacy Supersession

Update 2026-09-27: automatic bounded supersession replaces the rule below that
forbade automatic clearing. The receipt-aware VPS must report `missing`, the
operation must be at least 24 hours old, and its importer and staging must be
absent. The result is `superseded_unknown_outcome`, never success. See
`../architecture/runtime-and-host-ownership.md` and
`../runbooks/credential-sync-hold-recovery.md`. The operator script below remains
available for receipt-less holds on hosts that cannot run the status command.

The September 9 hold has no durable receipt; this change cannot reconstruct one.
Do not auto-clear it or label it successful. Explicit reviewed supersession must
bind the full local journal generation, target,
current authority epoch, store/auth generations, incoming snapshot and absent
staging, then revalidate under the appropriate local/remote mutation leases.
The separate operator workflow provides a lease-keeping authenticated SSH
adapter, private backup and exact-generation retirement. It passed 39 offline
fixtures and independent process-scan review. Live supersession remains gated on
the fresh attested release and an authenticated read-only review under approved
Mac quiescence; no blind compare-and-delete or force flag is permitted. See
`2026-09-24-legacy-sync-operator-recovery.md` for the cooperative-process threat
boundary and full entrypoint readiness gate.

# Integration And Verification

Current integration status: Main applied the historical-recovery caller in the
Mac worktree and added lock-held full-operation validation before either failure
branch can publish a hold. Delayed results cannot invalidate newer readiness
after the journal is replaced, removed, or unreadable. The full local Rust suite
passed 655 tests; the isolated Linux replay passed 20 focused tests, including the
Linux-only lost-reply integration. The combined Mac suite passed 289 tests across
12 suites after correcting new-fixture compile errors. The Mac update was
installed at 16:29 UTC and recovered authority selection with verified live
runtime convergence. The legacy receipt-less hold remains intact. No new server
release is active, so full credential-pool syncing is not restored yet.
The installed Mac changes are in the separate Mac recovery worktree and are not
part of this Linux release branch; the installed dirty-source identifier above
must not be confused with committed-main Mac behavior.
The original coordination notes below are historical, not the current
caller implementation. The implementation in `AppDelegate.swift` is authoritative.

Exclusive edits: Rust main/new receipt module/tests; Swift LinuxDevboxMonitor
and AppDelegateCredentialSyncTests. AppDelegate.swift belongs to James; do not
edit it. Main owns canonical architecture and VPS plan. No remote mutations,
credentials, provider requests, build jobs, service changes, or activation.

James/main handoff: integrate the new historical recovery API into
reconcileLinuxDevboxCredentialSyncIfNeeded before the legacy reconciliation.
On recovered completion, persist the receipt through recordImportReceipt,
revalidate target/operation before clear, remove the cached last-sync fingerprint
and convergence proof, clear the old hold, and schedule fresh authority-based
sync. Do not route historical completion through `.committed`, whose current
handler writes a convergence cache. Keep a generation guard on asynchronous
publication and leave failures held. The API is additive until this hunk is
coordinated. No agent messaging tool is available in the receipt-owner session.

Added deterministic fixtures cover missing lookup with no writes, lost-reply replay,
operation/input/path mismatches, duplicate import rejection, intent-only crash,
unknown fields, capacity, token-free output, and rotation after completion.
Mac fixtures cover exact versus historical evidence, unknown/pending receipts,
binding failures, staging remnants, and journal persistence. Compile/test runs
are delegated: Galileo alone owns the single-job Rust target, and main owns one
integrated Swift build after James integrates the caller. This owner ran no
Cargo or Swift compiler commands, provider calls, or live VPS operations.

Static verification passed: `git diff --check` in both worktrees; rustfmt parsing
of main.rs with skip_children and stdout discarded; rustfmt check of the new
receipt module. These are not type-check or test-pass claims.

Galileo test filters (run serially in the coordinated target):

- `credential_import_receipts::tests` (six tests)
- `credential_import_status_requires_canonical_binding_arguments`
- `durable_import_receipt_survives_lost_reply_and_prevents_second_activation`
  (Linux-only, no live/provider calls)
- `import_production_path_runs_runtime_reload_without_store_lock`
- `import_receipt_proves_newer_inactive_destination_generation_without_secrets`
- `import_file_only_handoff_requires_explicit_flag`

Main Swift test suite: `AppDelegateCredentialSyncTests` (five new regression
tests) plus existing `LinuxDevboxMonitorTests` and credential convergence tests.
Do not run the live recovery APIs as fixtures. The Mac caller remains unapplied
by this owner so James can integrate it without overlapping writes.

# Upgrade Compatibility

Mac operation preparation now performs a read-only help capability probe before
returning an operation to AppDelegate, which begins the journal only on success.
Both credential-import-status and the baseline flag must be advertised; the old
7f60 CLI parse failure is a non-holding, non-retrying upgrade deferral, not an
unknown mutation. Transport failure is safely retryable before execution. A
second check precedes staging in syncCredentials. No caller edit is needed.
These gates do not authorize runtime activation while work is active.

# Explicit Legacy Supersession

Removed 2026-09-28. The Swift operator-only review/backup/CAS API described
here was never called by the app; `scripts/recover-legacy-credential-sync.py`
implements its own adapter, and automatic supersession (see Legacy
Supersession) retired the September 9 hold at 2026-09-28T06:04:24Z. The
operator script remains for receipt-less holds on hosts that cannot run
`credential-import-status`.
