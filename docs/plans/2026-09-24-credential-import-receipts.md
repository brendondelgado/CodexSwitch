---
title: Durable credential import receipts
description: Receipt-recovery contract, verified server fixtures, and pending live deployment gates.
toc:
  - Contract
  - Persistence And Replay
  - Mac Recovery
  - Legacy Supersession
  - Integration And Verification
  - Original Caller Sketch
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
  last_updated: 2026-09-24
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

Under the runtime activation lease, reject duplicate operations and unresolved
intents before any activation reconciliation. Persist an intent before replacing
accounts; publish completed only after the existing activation outcome is
confirmed. Persist completed before printing the success response. A lost SSH
reply is recoverable from the completed record even after later rotation.

The read-only `credential-import-status` command requires operation UUID,
baseline fingerprint and incoming fingerprint. It returns a strict versioned
envelope: `completed` with the historical receipt, `pending` without a receipt,
or `missing` without a receipt. Mismatched bindings or invalid storage fail
closed. Status never creates directories/locks, performs cleanup, or reloads.
Reissuing update-bundle with an existing operation cannot mutate again; callers
must use status to replay. Even an expired bundle is unnecessary for status.

Crash after intent but before completed is intentionally pending, including a
crash after actual convergence but before completion persistence. Do not infer
its historical outcome from a current matching store. Automatic crash recovery
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

Missing/pending/unsupported status never proves non-execution. Legacy exact
current-state checks remain available separately, but are not historical proof.
Reject unknown fields, malformed states, mismatched UUID/baseline/incoming,
wrong target, staging remnants, and conflicting local/remote receipts.

# Legacy Supersession

The September 9 hold has no durable receipt; this change cannot reconstruct one.
Do not auto-clear it or label it successful. Explicit reviewed supersession must
bind the full local journal generation, target,
current authority epoch, store/auth generations, incoming snapshot and absent
staging, then revalidate under the appropriate local/remote mutation leases.
The new operator-only local eligibility/backup/CAS API is documented below.
The separate operator workflow now provides a lease-keeping authenticated SSH
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
The original coordination notes and sketch below are historical, not the current
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

# Original Caller Sketch

Superseded by Main's integrated caller and the subsequent stale-publication guard.
This original handoff sketch omits that guard and must not be used as deployment
code. See the current integration status above.

Requested edit, not applied by this owner: replace only
`reconcileLinuxDevboxCredentialSyncIfNeeded(operation:settings:)` with the body
below in the Mac worktree. Keep the existing finish helper for unrelated callers.
The new journal `clearRecoveredImport` checks the entire held operation including
its receipt under the exclusive lock and removes with file-generation CAS; a
same-ID record modified during recovery fails closed. Both current-equal and
drifted historical completion invalidate caches and require fresh convergence.
Missing/pending/unsupported status does NOT fall back to a current-state guess.
If James already has a recovery-generation token, also bind this closure to it.

P2 follow-up for main: both the `.unresolved` publication and the
clearRecoveredImport-failure publication must use
`journal.withCurrentRecoveryOperation(operation:receipt:body:)`. For the clear
failure supply the recovered receipt; for unresolved supply no additional
receipt. It compares the full expected operation while holding the exclusive
journal lock and runs the synchronous publication body only on exact match.
False or thrown read failures must not publish an obsolete hold. No nested
journal calls or asynchronous work are allowed in the body. The original hunk
below predates this integration requirement; main owns those two caller edits.

```swift
private func reconcileLinuxDevboxCredentialSyncIfNeeded(
    operation: LinuxDevboxCredentialSyncOperation,
    settings: LinuxDevboxMonitorSettings
) {
    guard !linuxDevboxCredentialSyncInFlight,
          !linuxDevboxCredentialSyncReconciliationInFlight else { return }
    linuxDevboxCredentialSyncReconciliationInFlight = true
    let journal = linuxDevboxCredentialSyncJournal
    let finish: @MainActor @Sendable (LinuxDevboxCredentialReceiptRecovery) -> Void = { [weak self] recovery in
        guard let self else { return }
        self.linuxDevboxCredentialSyncReconciliationInFlight = false
        guard LinuxDevboxMonitor.settings() == settings else { return }
        switch recovery {
        case .completed(let receipt, _):
            do {
                try journal.clearRecoveredImport(operation: operation, receipt: receipt)
            } catch {
                self.surfaceLinuxDevboxCredentialSyncHold(
                    operation: operation, context: "historical-receipt-journal-changed"
                )
                return
            }
            UserDefaults.standard.removeObject(forKey: linuxDevboxLastCredentialSyncFingerprintKey)
            UserDefaults.standard.removeObject(forKey: linuxDevboxCredentialConvergenceProofKey)
            self.clearLegacyLinuxDevboxCredentialSyncHold()
            SwapLog.append(.debug(
                "LINUX_DEVBOX_CREDENTIAL_SYNC_RECONCILED operation=\(operation.operationID) outcome=historical_completed_requires_fresh_convergence"
            ))
            self.scheduleLinuxDevboxCredentialSyncIfNeeded(context: "authority-reconciliation")
        case .unresolved(let reason):
            // Preserve the durable journal; transient observation failures need not rewrite it.
            self.surfaceLinuxDevboxCredentialSyncHold(
                fingerprint: operation.credentialFingerprint,
                reason: reason,
                context: "historical-receipt-reconciliation"
            )
        }
    }
    Task.detached {
        let recovery = LinuxDevboxMonitor.recoverCredentialSyncReceipt(
            settings: settings,
            operation: operation,
            recordImportReceipt: { receipt in
                try journal.recordImportReceipt(operationID: operation.operationID, receipt: receipt)
            }
        )
        await finish(recovery)
    }
}
```

Legacy recovery is deliberately not included in this hunk. Main/James must review
supersession separately with a fresh authority/store/auth observation and local
journal-generation guard. The reported live runtime repair and subsequent daemon
rotation do not establish what the September 9 credential import did.

# Upgrade Compatibility

Mac operation preparation now performs a read-only help capability probe before
returning an operation to AppDelegate, which begins the journal only on success.
Both credential-import-status and the baseline flag must be advertised; the old
7f60 CLI parse failure is a non-holding, non-retrying upgrade deferral, not an
unknown mutation. Transport failure is safely retryable before execution. A
second check precedes staging in syncCredentials. No caller edit is needed.
These gates do not authorize runtime activation while work is active.

# Explicit Legacy Supersession

Separate local API, not historical receipt recovery: review the exact unresolved,
receipt-less journal snapshot (bytes, content generation, file identity, path).
Require the operator's operation-and-generation-specific confirmation. Pure
eligibility requires a stable fresh authority target matching current store/auth
evidence, SHA-256 store/auth generations, cleared activation barrier, absent
operation staging and importer processes, and a continuously held runtime lease.
Revalidate immediately before backup and again before compare-and-delete. Epoch,
request ID, credentials, file generations and lease nonce must not change.

One fixed adjacent private backup slot retains the old unresolved journal
byte-for-byte. A different existing backup is never overwritten. Backup failure,
guard loss, stale evidence, changed journal, receipt arrival or staging remnants
leave the hold intact. Only after durable backup/readback may exact-generation
CAS retire the old journal. Result is `supersededUnknownOutcome`, never completed
or converged. No cached success or credential files are written by this API.

Concrete live adapter prerequisites on the existing 7f60 release:

1. Main must stop the CodexSwitch primary in the approved window so the operator
   can hold its existing singleton lock, quiesce sync/reconciliation submissions,
   and reject remaining import processes before reading the local review.
   This does not require stopping the user's ChatGPT desktop or local app-server.
2. An operator-approved authenticated SSH session must hold the EXISTING remote
   account-store runtime lock, accounts.runtime-activation.lock, exclusively and
   nonblocking for the entire local backup/CAS call. Validate owned regular lock
   inode with no-follow; do not unlink/recreate it. Keep the shared runtime
   start/install lock too, preserving release routing. Never hold the store lock
   while invoking CLI status commands that may need it.
3. Under that lease, inspect all owned process identities/argv/start times to
   exclude this operation's update-bundle importer and staging shell (including
   an importer between decryption and lease acquisition), prove its exact remote
   stage absent with no-follow checks, and read authority/store/auth/barrier
   without writing or refreshing. Freeze new submissions until local retirement
   returns. Recheck the process set, lock inode/owner and stage on each challenge.
4. Supply two fresh token-free observations from the same still-live lease nonce
   to the injected revalidation callback. A completed `flock -n ... true` probe,
   stale doctor report, stage absence alone, or booleans typed from memory are
   NOT valid evidence. On SSH/lease loss the callback must throw.
5. After successful local retirement, release the remote guard. Main separately
   invalidates stale sync caches and lets normal authority-based observation run.
   On old 7f60, a new import remains upgrade-deferred by the capability gate.

The local eligibility/backup/CAS API is testable without network or credentials.
The separate operator script now supplies the real lease-keeping SSH adapter,
but it has not been applied live. Its authenticated read-only review must pass
under the continuously held real guards before apply. Passing synthetic fixture
evidence to retire the September 9 journal is explicitly unsafe.

Additional Swift fixtures now include two upgrade-capability tests, five legacy
supersession tests, and two guarded publication tests. `git diff --check` passes;
all Swift compilation/tests remain reserved for main's integrated run. No live
recovery, provider calls, Cargo jobs or Swift builds were performed by this owner.
