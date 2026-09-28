---
toc:
  - Operator Boundary
  - Permanent Invariant
  - Lossless Session Object
  - Catalog Contract
  - VPS-Local Archive Contract
  - Eligibility
  - Representation State Machine
  - Historical Access
  - Metrics
  - Review Admission
  - Authorization Boundary
cross_dependencies:
  - docs/plans/2026-07-12-runtime-storage-hardening.md
  - docs/runbooks/runtime-storage-hardening-deployment.md
  - crates/codexswitch-cli/src/runtime_storage.rs
  - patches/codex/0.144.1-runtime-storage-hardening.patch
version_control:
  branch: main
  base_commit: 664edf6201fcd7dcdc299084392e3dad510ec9d7
  status: local_uncommitted
  last_updated: 2026-07-17
operator_boundary:
  status: OPERATOR_DIRECTIVE_ACTIVE
  sha256: 4416348576c92302dc3836955482bd6fd86c62b2aa9b66e5c7228b0161fc14fd
  lines: 58
  bytes: 2724
review_contracts:
  acceptance_json_sha256: 5deb0dead45e1dd5aebe3acff98655ef759d9df2dc1174a4576ad80aec0074c7
  acceptance_md_sha256: 81ab0911c1c74790348bab768e05f8dde69e19b4abfc066b13071f23636baea7
  adversarial_md_sha256: 91a91c98afac3965e533fd1e869ee5467c53222db0794d777c5f54e4fbc3d2fb
  admission_json_sha256: ef6035dea4d11f762f0fb836b83ff80f246e85e70a4ff75cf6f04c6b073bb13c
  admission_md_sha256: b7cd7da5dd6b3345c691124317af0f9ef307d7a87db1f82d35da853de6bc1d98
---

# Permanent Session Retention Contract

## Operator Boundary

This document is subordinate to the verified `OPERATOR_DIRECTIVE_ACTIVE` packet `/tmp/session-history-vps-only-boundary-20260713.md`, SHA-256 `4416348576c92302dc3836955482bd6fd86c62b2aa9b66e5c7228b0161fc14fd`, 58 lines / 2,724 bytes. The packet was read without retaining a Mac copy.

Codex/CodexSwitch session and log history is separate from SIGNUL, Source Mesh, proof-store, corpus, and product data. Raw/compressed bytes, per-session metadata, manifests, hashes, titles, summaries, tags, embeddings, indexes, restore receipts, and content-derived data must remain on the SIGNUL VPS. Copies for testing, development, backup, analytics, search, or disaster recovery outside the VPS are forbidden. Only aggregate non-content operational measurements without session identifiers may leave the VPS. This boundary grants no live-action authority.

## Permanent Invariant

Session files are irreplaceable source history and must never be reclaimed through lossy deletion. Raw session/event bytes and their exact ordering are permanent. Derived summaries, search indexes, tags, embeddings, or database rows may supplement raw history but must never replace it.

In this repository, “session reclaim,” “retention,” “compaction,” “archive,” and “cold tier” mean only a verified lossless representation or location transition. They never authorize `thread/delete`, filesystem deletion without a verified durable replacement, summary-only retention, or age-based discard.

`logs_2` history is also durable and non-retirable until a separately reviewed VPS-local lossless archive contract exists and receives separate execution authorization. A hot-budget measurement is not row-retirement authority.

## Lossless Session Object

Each closed, inactive session is an independent retrieval object. Do not combine the history population into one opaque archive.

- Canonical raw form: exact rollout JSONL bytes.
- Cold encoding: deterministic zstd level 3 with frame checksum, or an equivalently reviewed lossless codec.
- Identity: raw SHA-256 and raw byte count.
- Encoded identity: compressed SHA-256 and compressed byte count.
- Verification: full decompression must reproduce the raw SHA-256 and byte count before a representation transition can complete.
- Ordering: decoded bytes must be byte-for-byte identical, which preserves every event boundary and order.

Local plain-to-compressed replacement is permitted only under the per-thread writer lease and durable fsync/atomic-install contract. It is not a deletion because the same raw bytes remain exactly recoverable from the installed compressed representation.

## Catalog Contract

Every cold object has a versioned manifest entry containing only non-secret metadata:

- manifest schema version;
- stable thread/session ID;
- source host identity;
- project and cwd;
- created and updated timestamps;
- title where present;
- raw SHA-256 and compressed SHA-256;
- raw and compressed byte counts;
- codec name, level, frame options, and codec contract version;
- VPS-local object path, catalog generation, and content-addressed identity;
- publication, verification, restore-drill, pin, grace, and local-residency state.

Prompts, tool output, tokens, secrets, and other session contents must never be copied into manifest metadata. Content-derived summaries/tags require a separately reviewed safe indexing policy.

The durable searchable catalog is a private VPS-local SQLite database under a VPS-local storage root with permissions `0700` or stricter. It stores only the metadata required for local identity, verification, search, restore, and residency. It must never be copied to the Mac or any external service. Raw history remains authoritative when catalog state and rollout bytes disagree.

## VPS-Local Archive Contract

Cold bytes remain on the VPS in individually addressable per-session zstd files. No session/log bytes, metadata, titles, summaries, indexes, hashes, manifests, or content-derived data may leave the VPS. Objects may deduplicate locally only when raw and compressed identities, codec contract, ownership, and restore behavior are identical and unambiguous.

The local representation transition is manifest-last:

1. Freeze a stable, eligible session under its lease; readers requiring representation stability use the same per-thread lease contract.
2. Produce and verify the independent compressed object.
3. Fsync and atomically install the VPS-local compressed representation.
4. Reopen the installed representation from its final path.
5. Verify compressed digest and byte count.
6. Decompress the installed representation and verify raw digest and byte count.
7. Commit the versioned manifest/catalog row durably to the VPS-local SQLite catalog.
8. Perform the required same-VPS isolated restore drill and record its result.
9. Start the grace window; retain the local plain source.
10. Recheck pin, active/unfinished state, modification time, lease, format, catalog, and local object generation immediately before any separately authorized plain-representation retirement.

Any ambiguity returns the object to a non-retirable state. An installed compressed file alone is never sufficient without exact decode verification and durable local catalog state.

## Eligibility

The following are always non-eligible for cold eviction:

- active or leased sessions;
- pinned sessions;
- unfinished sessions or sessions with unknown goal/turn state;
- recently modified sessions;
- unknown or unsupported formats;
- corrupt or digest-mismatched representations;
- sessions without a complete durable catalog entry;
- sessions whose final VPS-local compressed object cannot be reopened and fully restored;
- sessions inside the grace window;
- sessions with ambiguous host, project, thread identity, or object generation.

Hot-cache residency is bounded but age- and pressure-aware. Pressure may prioritize already-published eligible objects; it never weakens an eligibility gate.

## Representation State Machine

```text
plain_local
  -> compress_verified
  -> local_install_fsynced
  -> local_reopen_verified
  -> catalog_committed
  -> restore_drilled
  -> grace_period
  -> plain_retirement_eligible
  -> compressed_only_local
  -> plain_restored_local
```

Every transition is idempotent and compare-and-set against the expected prior state, manifest version, raw digest, compressed digest, and VPS-local object generation. Crashes may leave duplicate durable representations; they must never leave no verified representation. Concurrent processes use the same per-thread lease plus catalog generation fencing.

Plain-representation retirement is a future state, not an authorization in the runtime-storage implementation task. The current planning row is 27,628,306,432 total runtime bytes, an 8,000,000,000-byte local hot budget, and at most 19,628,306,432 potential plain-representation retirement bytes only after every lossless/restore gate succeeds.

The same invariant applies to session-associated and CodexSwitch/Codex runtime log history. A global log budget may identify archive candidates, but it must not delete rows without a durable cold-object receipt covering the exact exported bytes.

## Historical Access

Bounded commands/API must support:

- list and search by thread ID, date range, source host, project/cwd, title, tag, residency, and publication state;
- safe content-derived search where policy permits;
- show manifest and verification state without exposing secret session content;
- transparent read or one-command selective restore for a single session;
- restore with VPS-local reopen, compressed digest verification, full raw digest/byte verification, same-directory durable install, and local catalog state update.

No command may require reading or decoding the entire VPS-local archive population to retrieve one session.

## Metrics

Record exact before/after and rate metrics:

- raw and compressed bytes/day;
- compression ratio and bytes saved;
- local plain, compressed-only local, dual-representation, pinned, and non-eligible bytes/counts;
- local install/reopen/digest/restore success and failure counts;
- list/search/show latency and selective restore latency;
- grace-window population and eviction eligibility;
- local residency days and projected days to disk floor;
- crash recovery, idempotent retry, lease contention, and catalog generation conflicts.

## Review Admission

This repository can qualify only for `ACCEPT_LOCAL_DISABLED_IMPLEMENTATION` while the legacy-descriptor boundary remains open. A process that opened a rollout with `O_APPEND` before participating in the patched lease protocol cannot be universally fenced by this patch alone. A successful synthetic review therefore does not authorize activation.

Every mutator remains off by default. Any future activation requires exact global quiescence of every process that may hold a rollout descriptor, replacement with the reviewed patched binary, fresh mechanical evidence that no legacy descriptor survives, and separate operator authority. Missing, empty, malformed, unknown, case-variant, or conflicting activation values mean off.

The frozen pre-freeze findings are part of the subject:

- F1 postimage verification: `e5a33bd34afabbb4b12c79a90c99ad009f959e1665de90c13124a83030973d22` JSON; `c6092d269049857bacff3a5396cfb5a32b738996751a1d2c0cc297b51c8a5bee` Markdown.
- F2 bundle-move crash recovery: `dfc9a3a61c638c0ce58c5d641ed12accf4b95b2c29e67e58c1d49a26aa041c6f`; `5735c6c4648afbecb412226536ede8f258d1ce3c0025ae07056a34bd9e457c0f`.
- F3 equal-generation CAS: `9c112b3fe39af6c37b516e92fb9cf368a371930c49385931a60e5b8f2b0df710`; `0c5da906c8a1f2ac8881121f3e29edc255a519e505861fec8001fb95947c6380`.
- F4 restore lifecycle: `09884ac202575731ad597d9fbdefbd0e7bc60ce3510f86e47943269e6ff32c74`; `ece50568092ea62531aa889c7fa5f6b944d27c18e02f456ebc34fd9aba54e00b`.
- F5 path/open identity: `74a2ee187da779d3e8b77ed70235e6154b32846d8511eb0b3be17eaa1d255cc4`; `50e7b27ff370c026cca0f7a5e4ebc19ab14e2d104b6ef00e8aae642ee06e992e`. The default-off clarification audit is `3594010984ad5c24efcaf61d1d06dfdca8c0f67628dc07d2b5897ebde50508d0`.
- F6 diagnostic completeness: `29afe6a0500072b6ec59b36b240e8db6460feeb5789169f3045e34978c3351d0`; `f37e458e8c69b5be43eb35eadfed0bdb1f56df0413bb64b6e158a750f88649cc`.
- F7 observe-only log maintenance: static-audit SHA-256 `33216242f50f9b0939fe4cd39d358f40e9cbd01390d83ea7ea2325a7573983b8`; addendum SHA-256 `c8a271b14ced6c2516fe1075d20722c4e137d824af164177cf29801502345948`.

The exact fourteen-row review-input denominator is SHA-256 `2ad1c4ddbc55593ee8ceacf74130e3168aee1c31cf302760bc2e19de6f63c546`. The pre-freeze gap audit SHA-256 `f6e34d0da0594f0ff4777ab7ec8c86aa52f043486f45b3f5a6f1d24f793383c7` remains the refusal baseline until the terminal subject, postimage denominator, and named nonzero tests are frozen. Every finding must map to immutable code and tests or remain explicitly incomplete.

## Authorization Boundary

This task may implement and test contracts, local lossless compression, VPS-local manifest/catalog interfaces, and dry-run status/doctor using synthetic fixtures only. It must not receive real VPS session/log data or perform live compression, plain retirement, log-row retirement, migration, deletion, copying, credential change, service restart, feature activation, or release publication.

The first live migration or local eviction requires a separately reviewed one-shot execution plan and explicit authorization. Automatic session deletion is permanently outside the retention architecture.

Keeping the sole durable copy on one VPS is an explicitly accepted single-failure-domain risk. No external disaster-recovery copy may be created unless a future operator directive supersedes this boundary.
