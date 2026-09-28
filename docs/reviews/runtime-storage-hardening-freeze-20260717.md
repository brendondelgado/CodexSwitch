---
toc:
  - Verdict
  - Boundary and Subject
  - Required Outcomes
  - F1 Through F7
  - ADV-01 Through ADV-10
  - Exact Test Evidence
  - Remaining Holds
  - External-Write Attestation
cross_dependencies:
  - docs/reviews/runtime-storage-hardening-subject-20260717.json
  - patches/codex/0.144.1-runtime-storage-hardening.patch
  - docs/architecture/session-retention-contract.md
  - docs/runbooks/runtime-storage-hardening-deployment.md
version_control:
  branch: main
  status: local_disabled_review_candidate_not_accepted
  last_updated: 2026-07-17
---

# Runtime Storage Hardening Terminal Freeze

## Verdict

The immutable local subject is ready for independent review as a disabled-by-default candidate. Acceptance is not self-ratified and live activation is not authorized. F4 executable restore, feature-on F5 descriptor-relative journal identity, ADV-02 legacy pre-open append descriptors, ADV-07 executable downgrade rehearsal, and the full syscall-level ADV-10 hermetic trace remain explicit holds.

## Boundary and Subject

The controlling VPS-only boundary is SHA-256 `4416348576c92302dc3836955482bd6fd86c62b2aa9b66e5c7228b0161fc14fd`. The source patch is pinned to Codex `0.144.1`, commit `44918ea10c0f99151c6710411b4322c2f5c96bea`. The exact 19-file parent subject is `docs/reviews/runtime-storage-hardening-subject-20260717.json`. The embedded patch has 31 nonempty exact postimages; its immediate and final manifests cover the same denominator, with only the deterministic downstream `Cargo.lock` postimage differing.

No reviewer, reviewer authority, deployment authority, or live authority is bound.

## Required Outcomes

- Defaults off: feature default false; every local store constructor false unless the resolved disabled feature is explicitly enabled; tracked service, installer, updater template, and tests contain no true activation.
- VPS-only: no real VPS session/log bytes or per-session metadata were read, received, copied, or written. All fixtures are generated synthetic data.
- Lease: patched writers/readers/compressors share a kernel-held per-thread lock; a real paused subprocess cannot be bypassed and death releases the lock.
- Lossless transition: deterministic zstd level 3 with frame checksum, exact raw/compressed digest and length, same-directory temporary install, fsync/reopen verification, grace/pin/lease/format gates, and refusal on ambiguity.
- Compatibility: exact compressed restore/read verification is implemented; default-off archive/unarchive uses the exact upstream plain-only helpers and never reads journals.
- Metadata: schema/version/generation/digests/lengths are bound; SQLite mutation uses `BEGIN IMMEDIATE` plus strict generation CAS; unknown future manifests refuse.
- Logs: whole-database observation only, generation-fenced claims/finalizers, no row retirement/hiding, no automatic checkpoint/vacuum, and committed inserts never become insertion errors due to later observation.
- Durable updater: embedded pinned patch, wrong-source/version refusal, marker fast-path verification, complete postimage denominator, and final verifier after downstream source patching.

## F1 Through F7

- F1 complete: exact two-phase 31-path postimage manifests, complete-denominator test, marker-revert/mutation refusal, idempotent second apply, downstream drift refusal, and clean pinned replay.
- F2 local-disabled disposition: crash journal tests pass for every rename/fsync boundary; journaled bundle moves are unreachable while the feature is off. Feature-on identity hardening remains an activation hold.
- F3 complete: generation-one creation, strict next-generation CAS, exact equal-generation replay only, conflict preservation, and concurrent different-thread serialization.
- F4 held/non-executable: `codexswitch-cli storage restore` refuses at the command boundary before path access. Exact decode verification exists, but a native leased generation-CAS restore mutation is not implemented.
- F5 local-disabled disposition: archive and unarchive branch to upstream plain helpers before journal access when off; every constructor defaults false. Feature-on descriptor-relative journal identity remains held.
- F6 complete: catalog absence/open/schema errors are typed; doctor scans all rows and cannot report complete/ok after a late corruption.
- F7 complete for observe-only scope: startup is not forced, claims/finalizers are generation fenced, inserts are post-commit error-isolated, physical work is disabled/not-run, and history is never retired or hidden.

## ADV-01 Through ADV-10

- ADV-01 complete for patched processes: stable kernel lock, no timeout takeover, subprocess pause/death test, nonreplaceable lease identity checks, `BEGIN IMMEDIATE` shared-catalog serialization, and CAS.
- ADV-02 incomplete for live activation: patched writers participate and pathname/inode aliases refuse, but a legacy pre-open `O_APPEND` descriptor cannot be universally fenced. Global quiescence and binary replacement are mandatory.
- ADV-03 complete for compression; feature-on bundle moves remain held: failure boundaries retain a verified representation and never silently accept split state.
- ADV-04 complete for catalog CAS/reconciliation in the admitted path; raw verified bytes remain authoritative.
- ADV-05 complete for reader ambiguity and exact decoded bytes; executable restore mutation remains held under F4.
- ADV-06 partial: current and unknown-future manifest versions are tested and unknown versions refuse; prior-binary downgrade compatibility remains an ADV-07 hold.
- ADV-07 incomplete: the rollback runbook is ordered and non-destructive, but executable old-reader/plain-restoration rehearsal is not present because restore mutation is held.
- ADV-08 complete for the immutable subject: library/config/service/updater defaults are off and invalid activation is never inferred.
- ADV-09 complete: no log delete/hide/checkpoint/vacuum path; only additive singleton telemetry may change.
- ADV-10 partial: tests use explicit temporary roots/synthetic identifiers, storage code has no network path, out-of-root/live-looking paths refuse, and evidence contains no real payload. A syscall-level path/network trace with fully scrubbed inherited environment was not produced.

## Exact Test Evidence

Only nonzero discovered filters count:

- `codex-state runtime_storage`: 5 passed, including concurrent shared-catalog serialization and equal-generation conflict preservation.
- Four exact F7 tests: 4 passed.
- `delete_thread_cleans_associated_state`: 1 passed; durable logs retained.
- `codex-rollout bundle_move::tests`: 4 passed.
- `codex-rollout lease::tests`: 5 passed, including real subprocess pause/death.
- `codex-rollout manifest::tests`: 3 passed, including unknown-future refusal.
- `codex-rollout compression::tests::`: 6 passed. The earlier zero-match filter is excluded.
- Thread-store archive: 3 passed; unarchive: 3 passed; both default-off journal-refusal tests passed.
- Parent `runtime_storage`: 8 passed, covering updater postimages/idempotency/drift, held restore, diagnostic errors, late corruption, and observe-only logs.
- Tracked Linux default-off policy: 1 passed.
- Native `cargo check -p codex-state -p codex-rollout -p codex-thread-store --tests`: passed.
- `cargo fmt --all` and parent `cargo fmt --all -- --check`: passed. Upstream fmt emitted stable-toolchain warnings for nightly-only import granularity.
- Parent Clippy with warnings denied reached the full crate and refused on unrelated pre-existing lint debt; the one task-owned boolean-assert finding was corrected. Repository-wide Clippy is therefore not claimed green.
- The broad Linux installer suite is not evidence: it had an earlier failure and then hung in an unrelated inactive-runtime staging fixture until interrupted.

## Remaining Holds

Future activation requires exact global quiescence, replacement of every participating binary with the reviewed artifact, fresh proof that no legacy append descriptor survives, closure/review of feature-on journal identity, an executable native restore/rollback rehearsal, independent review, and separate operator authority. All mutation remains off. No live compression, catalog mutation, prune, deletion, migration, install, restart, config change, push, release, or provider action occurred.

## External-Write Attestation

Zero session/log bytes and zero per-session/content-derived session/log metadata were externally written. No real VPS session/log contents were received or copied to the Mac. Policy-only contract files were read by exact path and hash. No R2, Cloudflare, Neon, SecureDrop, provider, secret, Keychain, or live VPS mutation occurred.
