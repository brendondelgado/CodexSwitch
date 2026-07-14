---
toc:
  - Operator Boundary
  - Scope
  - Measured Baseline
  - Runtime Contract
  - Feature Flags and Defaults
  - Review and Build
  - Deployment Gate
  - Activation
  - Verification Metrics
  - Rollback
  - Repository State
  - Authorization Holds
cross_dependencies:
  - docs/architecture/session-retention-contract.md
  - docs/plans/2026-07-12-runtime-storage-hardening.md
  - patches/codex/0.144.1-runtime-storage-hardening.patch
  - crates/codexswitch-cli/src/storage.rs
  - crates/codexswitch-cli/src/codex_update.rs
  - Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
version_control:
  branch: main
  base_commit: 664edf6201fcd7dcdc299084392e3dad510ec9d7
  status: local_uncommitted
  last_updated: 2026-07-13
operator_boundary:
  status: OPERATOR_DIRECTIVE_ACTIVE
  sha256: 4416348576c92302dc3836955482bd6fd86c62b2aa9b66e5c7228b0161fc14fd
  lines: 58
  bytes: 2724
---

# Codex Runtime Storage Hardening Deployment Packet

## Operator Boundary

This packet is subordinate to the verified `OPERATOR_DIRECTIVE_ACTIVE` packet `/tmp/session-history-vps-only-boundary-20260713.md`, SHA-256 `4416348576c92302dc3836955482bd6fd86c62b2aa9b66e5c7228b0161fc14fd`, 58 lines / 2,724 bytes. The packet was read without retaining a Mac copy.

All session/log bytes and all per-session or content-derived metadata remain on the SIGNUL VPS. This includes raw/compressed bytes, titles, manifests, hashes, summaries, tags, embeddings, indexes, receipts, and searchable catalog data. Only aggregate non-content operational measurements without session identifiers may leave the VPS. Mac development and tests use synthetic fixtures only. No live compression, migration, plain-representation retirement, log-row retirement, copy, restart, feature activation, or release is authorized.

## Scope

This packet integrates the Codex runtime-storage fix with the VPS-local storage program. It covers local build/review and a future quiesced activation. It does not authorize a live deployment, compression, rollout deletion, automatic archive, plain-representation retirement, log-row retirement, SQLite file replacement, copying, secret access, or release publication.

The only runtime home in scope is exact `/home/signul/.codex`. Hermes is excluded.

Session and log retention is permanently lossless-only and VPS-only. No retention implementation may call `thread/delete`, retire institutional log rows under the current contract, replace raw history with summaries/indexes, or copy any byte/metadata/catalog/hash/title/summary/index to the Mac or an external service. `logs_2` retirement requires both a separately reviewed VPS-local lossless archive contract and separate execution authorization. Per-session zstd files, manifests, search, and the durable SQLite catalog all remain private on the VPS. See `docs/architecture/session-retention-contract.md`.

VPS program planning row:

| Field | Bytes |
|---|---:|
| Total Codex runtime | 27,628,306,432 |
| Bounded local hot budget | 8,000,000,000 |
| Potential local eviction after every gate | 19,628,306,432 |

## Measured Baseline

Read-only SIGNUL snapshot from 2026-07-12:

| Metric | Before |
|---|---:|
| Rollout files | 2,786 |
| Rollout apparent bytes | 14,448,038,198 |
| Rollout bytes newer than 24 hours | 11,445,153,991 |
| `logs_2.sqlite` | 4,465,893,376 |
| `logs_2.sqlite-wal` | 198,579,912 |
| SQLite freelist | 20 pages / 81,920 bytes |
| Sample zstd level-3 ratio | 17.6282% |
| Sample savings | 82.3718% |

Expected steady rollout production at the measured ratio:

- Raw: about 11.45 GB/day.
- Compressed: about 2.02 GB/day.
- Expected reduction: about 9.43 GB/day, or 82.37%.
- Fourteen-day addition: about 28.25 GB; acceptance ceiling is 32 GB.

Compression controls the burst but does not provide indefinite zero-growth retention. The operator has explicitly accepted the single-VPS failure domain; no remote copy, external disaster-recovery path, or lossy deletion is admissible under this packet.

## Runtime Contract

- Every live rollout writer owns an OS advisory lease at `${CODEX_HOME}/.tmp/rollout-leases/<thread-id>.lock` before resolving a plain/compressed representation and for the writer's full lifetime.
- Lease basenames use lowercase canonical hyphenated UUID syntax with the RFC
  variant. UUIDv4 and UUIDv7 are both valid; diagnostics parse UUID syntax
  instead of maintaining a fixed version allowlist. Uppercase, non-RFC,
  malformed, symlinked, or special lease entries fail the inventory closed and
  remove nothing.
- `${CODEX_HOME}/.tmp` and `.tmp/rollout-leases` must each be real directories,
  not symlinks or special files. Each lease is opened with no-follow semantics;
  its device/inode/type must still match the preceding `lstat` result. An inode
  replacement during inspection fails closed.
- Compression, materialization, stable readers, archive, unarchive, rearchive, restore, and any future plain-representation retirement use the same per-thread lease.
- Compression never waits for an active lease; it records a skip and retries in a later pass.
- A rollout is eligible only when it is a scoped regular file, its filename UUID matches the first canonical SessionMeta ID, no lease is held, and it is stable for at least fifteen minutes.
- Compression uses zstd level 3 with frame checksum, exact decoded SHA-256/length validation, same-directory no-clobber installation, file and directory fsync, and source retirement only after durable verification.
- Plain wins if both representations survive a crash. Doctor reports the dual state; it is never double counted.
- Global log measurement and non-destructive maintenance are claimed through a singleton SQLite row. One process performs a due pass; other processes skip the cadence window.
- `logs_2` rows are non-retirable until a separately reviewed VPS-local lossless archive contract and separate execution authorization exist. Passive WAL checkpoint and bounded incremental vacuum must not imply row-retirement authority.

## Feature Flags and Defaults

| Setting | Value | Activation state |
|---|---:|---|
| Codex feature | `local_thread_store_compression` | enabled by the reviewed app-server unit on a separately authorized activation |
| Capability marker | `codex-runtime-storage-leases-v1` | required in every active Codex executable |
| Compression level | 3 | private default |
| Zstd frame checksum | enabled | mandatory |
| Minimum inactivity | 15 minutes | private default |
| Coordinator interval | 5 minutes | private default |
| Pass work budget | 15 minutes | private default |
| Concurrent compression jobs | 2 | private default |
| Rollout hot retention | 14 days / 32 GiB compressed addition ceiling | older objects remain losslessly retrievable in the VPS-local archive |
| Log hot retention | 1 GiB / 250,000 rows | overflow becomes archive work; row retirement requires a verified local receipt |
| Total runtime plus archive admission | 100,000 files / 3,650 days / 64 GiB | installer fails closed; no session or archive object is deleted |
| Global estimated log budget | 1 GiB | private default |
| Global log row budget | 250,000 | private default |
| Institutional-history eviction batch | 0 rows | disabled pending verified cold receipts and authorization |
| Log maintenance cadence | 15 minutes | private default |
| WAL journal size limit | 128 MiB | per-connection SQLite pragma |
| WAL autocheckpoint | 1,000 pages | per-connection SQLite pragma |
| Incremental vacuum budget | 4,096 pages/pass | post-commit best effort |

Defaults are intentionally private in the first patch. There is no public
tuning surface that can bypass the bounds. The coordinator makes progress
within its fifteen-minute pass budget, preserves every active lease, and fails closed
on an over-budget state rather than deleting an active or unarchived object. The
1 GiB/250,000-row log limits and 14-day/32-GiB rollout limits bound hot runtime
storage; they are not permission to destroy history.

Before staging or activation, the Linux installer inventories regular files
beneath `sessions/`, `archived_sessions/`, and `logs_*.sqlite*`. It rejects
symlinks and enforces the total count, oldest-age, and byte ceilings. Directory
enumeration is streaming and bounded by entry count, nesting depth, bytes, and
elapsed work before allocating or retaining another record; exceeding any scan
bound fails closed before cleanup. Advisory locks beneath
`.tmp/rollout-leases/` identify active sessions for diagnostics; active leased
objects remain counted and protected. A violation reports the active-leased
count and removes nothing. Raising a bound is an explicit reviewed
configuration change, not automatic retention drift. Session filenames receive
lease protection only when they contain one lowercase canonical RFC UUID token;
malformed tokens never alias a valid active lease.

### VPS-local orchestrator interfaces and artifacts

The VPS-local storage orchestrator consumes these versioned artifacts. They remain private on the VPS and are never sent to the Mac or an external service:

- `RuntimeStorageStatusV1` from a VPS-local `codexswitch-cli storage status --json`: local representation counts/bytes, log DB/WAL/page metrics, lease-aware process inventory, and budget posture. A separate Mac-facing status projection may contain aggregate non-content measurements only, with no session identifiers, paths, titles, hashes, or catalog rows.
- `LosslessArchiveManifestV1` JSONL: one independently retrievable VPS-local session/log object with thread ID, source host, project/cwd, timestamps/title, raw/compressed digests and lengths, codec contract, local object identity, local catalog generation, and restore/residency state.
- `LosslessArchiveReceiptV1` JSON: local install/reopen/digest/decode/catalog/restore/grace/pin/lease/active gate evidence bound to the manifest generation.
- `LosslessMigrationPlanV1`: exact selected object generations, before bytes, projected after bytes, hot-budget target, and zero default eviction count.
- `RestoreResultV1`: isolated same-VPS target, local object identity, decoded digest/length, install result, latency, and catalog compare-and-set generation.
- VPS-local key contract: `${CODEX_HOME}/archived_sessions/v1/sha256/<raw-sha256>/zstd-3/<compressed-sha256>.jsonl.zst`; future log segments use a separate VPS-local prefix and exact row-range identity.
- VPS-local SQLite catalog contract: immutable object generations plus current-state rows keyed by stable thread/session or log-segment ID; it is never mirrored externally.
- Private storage-root contract: archive objects, manifests, receipts, leases, and catalog live beneath a VPS-local root with permissions `0700` or stricter.

The orchestrator must reject unknown schema/codec versions and any receipt whose manifest generation, digest, length, VPS-local object identity, or local SQLite catalog generation differs.

## Review and Build

Use the authoritative Mac checkout with synthetic fixtures only. Do not receive or copy real VPS session/log bytes or per-session metadata for development or testing:

```text
cd /Users/brendondelgado/Developer/CodexSwitch
git status --short --branch
cargo test -p codexswitch-cli storage
swift test --filter LinuxDevboxMonitorTests
```

Replay the embedded patch in a clean Codex `0.144.1` checkout and run:

```text
cd <clean-codex-0.144.1>/codex-rs
just test -p codex-rollout
just test -p codex-thread-store
just test -p codex-state
just test -p codex-cli
just fix -p codex-rollout
just fix -p codex-thread-store
just fix -p codex-state
just fix -p codex-cli
just fmt
```

Do not run the full Codex workspace test suite without explicit approval. Do not install the built binary during review.

## Deployment Gate

Run read-only status and doctor first:

```text
codexswitch-cli storage status --codex-home /home/signul/.codex --json
codexswitch-cli storage doctor --codex-home /home/signul/.codex --json
```

Activation is refused unless all conditions are true:

- the repository release is pinned by a reviewed full 40- or 64-character Git
  SHA reachable from the approved origin ref, and the runtime artifact has its
  own reviewed full source SHA;
- exact runtime home equals `/home/signul/.codex` for the SIGNUL deployment;
- disk has source-sized temporary headroom plus safety reserve;
- every active Codex PID is enumerated with PID, start time, executable path, executable fingerprint, and FD count;
- every executable contains `codex-runtime-storage-leases-v1`;
- no old binary shares the runtime home;
- native Codex doctor and CodexSwitch inventory both count compressed-only rollouts and deduplicate dual representations;
- rollout concurrency/fault tests and multi-process log-cap tests are green;
- `local_thread_store_compression` is still false before the controlled restart.

## Activation

Activation requires a separately authorized maintenance window:

1. Freeze new work through the managed daemon boundary.
2. Wait for every managed turn to become terminal; refuse ambiguous external processes.
3. Record `storage status --json` as the before artifact.
4. Prepare the reviewed lease-aware runtime as an input artifact only. A helper
   must not copy it into a live path, replace a public CLI, enable a unit, or
   restart a process.
5. Stage and inspect the immutable repository release with
   `CODEXSWITCH_GIT_SHA=<full-sha>`, the approved origin ref, full runtime source
   SHA, and `scripts/install-linux.sh`; stage-only changes no live pointer or
   process.
6. Activate only through the same full-SHA installer invocation with explicit
   restart flags. Unit bytes, pointers, boot links, prior inactive service
   posture, and any requested import remain one rollback-protected transaction;
   mixed old/new writers are forbidden.
7. Re-run `storage doctor --json` and require every live executable to contain the capability marker.
8. Treat `local_thread_store_compression` as immutable release configuration;
   do not toggle it with a direct mutable feature command.
9. Verify the first bounded pass. Never use raw `kill`, broad `pkill`, a direct
   service command, or a mutable install helper as a deployment shortcut.

No direct feature, install, enable, or restart command in this packet is an
authorized deployment path. The immutable full-SHA installer transaction is the
only activation boundary.

## Verification Metrics

Capture status immediately before activation, after the first pass, at 30 minutes, and at 24 hours. Compare:

- plain, compressed, and dual rollout counts;
- logical rollout count and physical bytes by active/archive root;
- eligible uncompressed bytes and oldest eligible age;
- source bytes, compressed bytes, ratio, reclaimed bytes, lease skips, and failures;
- projected rollout bytes/day and days to disk floor;
- log main/WAL bytes, page count, freelist count, live-page bytes;
- global log rows, estimated bytes, thread/process partition counts;
- maintenance claimed/skipped/failed, over-budget posture, checkpoint state, and incremental-vacuum pages;
- SQLite busy, locked, full, and queue-drop errors.

Acceptance targets:

- zero lost or duplicate rollout lines;
- zero active/leased rollouts compressed;
- p95 eligible age-to-compressed no more than 30 minutes;
- eligible uncompressed backlog no more than 2 GiB after 30 minutes;
- observed compression ratio no more than 25%;
- global log budget posture is measured consistently across partitions without retiring rows;
- no increase in SQLite busy/locked/full errors;
- quiesced WAL no more than 128 MiB;
- after separately authorized offline physical compaction, main DB no more than 1.5 GiB.

## Rollback

Binary rollback and representation rollback are separate:

1. Freeze new work and require all managed turns terminal.
2. Select and validate the immutable `previous` release manifest and its full
   Git/runtime source SHAs; malformed or aliased pointers are blockers.
3. Activate that reviewed SHA through `scripts/install-linux.sh`. Do not disable
   a feature, replace a binary, or restart a unit directly. The patched binary
   continues to read existing `.jsonl.zst` files.
4. Before installing any older binary without compressed-read support, materialize every compressed rollout under the same per-thread lease, verify the complete zstd frame and exact decoded hash/length, fsync the plain file and parent, then retire the compressed representation.
5. Re-run both doctors and prove plain-only inventory before downgrade.

The logs migration is additive and must remain on binary rollback. Do not down-migrate it. No log-row retirement is authorized. Any future physical SQLite operation requires its own reviewed rollback contract and must retain hashed VPS-local main/WAL/SHM rollback artifacts until post-restart verification succeeds.

## Repository State

**Status:** repository policy and deployment wiring are active for review as of
2026-07-13. The immutable runtime must contain
`codex-runtime-storage-leases-v1`; the checked-in app-server definition enables
`local_thread_store_compression` and applies bounded pass, inactivity, and hot
storage defaults. This repository state is not evidence of VPS deployment or
feature activation.

**External-write attestation:** Zero session/log bytes and zero per-session or content-derived session/log metadata were written to R2, Cloudflare, Neon, the Mac, SecureDrop, or any other external destination. No real VPS session/log contents were received or copied to the Mac. The frozen boundary packet and the earlier storage workpack were read-only policy/aggregate context; the temporary Mac file used to verify the boundary packet was removed. No live VPS compression, migration, plain-representation retirement, log-row retirement, deletion, restart, feature activation, or install occurred.

**Durable task-owned documents:**

- `docs/architecture/session-retention-contract.md`
- `docs/plans/2026-07-12-runtime-storage-hardening.md`
- `docs/runbooks/runtime-storage-hardening-deployment.md`

All three bind to operator packet SHA-256 `4416348576c92302dc3836955482bd6fd86c62b2aa9b66e5c7228b0161fc14fd` and prohibit session/log bytes or per-session/content-derived metadata outside the VPS.

**Verification state:** Linux deployment fixtures use synthetic runtime/session
data only. They prove the capability marker requirement, immutable release
retention, exact systemd resource policy, and non-live activation behavior.
Native Codex rollout/thread-store/state tests and any live storage migration
remain separate gates before an operator authorizes deployment.

## Authorization Holds

- Live rollout compression or materialization: held.
- Feature enablement or runtime restart: held.
- One-time SQLite checkpoint/compaction/file replacement: held.
- Automatic archive or plain-representation retirement: not authorized.
- External session/log storage, remote offload, Mac mirroring, and external disaster-recovery copies: forbidden by the active operator boundary.
- Automatic or policy-driven session deletion: permanently prohibited.
- Account store, OAuth tokens, Keychain, Hermes, and SecureDrop secrets: out of scope.
- Commit, push, pull request, release, and publication: held for independent review.
