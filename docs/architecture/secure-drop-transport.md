---
title: SecureDrop transport
description: Canonical integrity, publication, extraction, deletion, and retention contract for Mac-to-VPS artifact transfer.
toc:
  - SecureDrop Transport
  - Scope
  - Endpoints
  - File Contract
  - Transfer Transaction
  - Directory Archives
  - Knowledge Sync
  - Audit And Retention
  - Failure Semantics
cross_dependencies:
  - ../../crates/codexswitch-cli/src/secure_drop.rs
  - ../../scripts/securedrop/cs-autopush
  - ../../scripts/securedrop/cs-autopull
  - ../../scripts/securedrop/cs-send-dir
  - ../../scripts/securedrop/cs-extract
  - ../../scripts/securedrop/knowledge-sync
  - ../audits/2026-07-12-codebase-audit.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-07-13
---

# SecureDrop Transport

## Scope

SecureDrop moves explicit artifacts between this Mac and the SIGNUL VPS. It is
not an account-state store, credential manager, session mirror, public sharing
service, or deployment activator.

OAuth tokens, raw account stores, private keys, and other secrets are excluded
unless the operator explicitly accepts the risk for one transfer. The shared
knowledge directory never carries secrets.

## Endpoints

- Mac root: `~/CodexSwitch SecureDrop`
- VPS root: `/home/signul/codexswitch-secure-files`
- Mac to VPS: Mac `outbox` to VPS `inbox`
- VPS to Mac: VPS `outbox` to Mac `inbox`
- Shared findings: `knowledge` on each host

Each root and its private working directories are real, current-owner
directories with mode `0700`. A symlink or wrong-owner endpoint fails closed.

## File Contract

Transfer inputs are regular files with conservative single-component names.
Symlinks, hard-link aliases supplied as archive members, devices, sockets,
FIFOs, traversal components, absolute archive paths, and shell-active names are
rejected.

File hashing is streamed through a fixed-size buffer from an `O_NOFOLLOW`
descriptor. The opened file's device, inode, size, modification time, and change
time must remain stable through hashing. A changed source is not published.

Manifests contain the file name, byte count, SHA-256 digest, and creation time.
They contain no token material and are written through the same locked,
generation-checked secure-file primitive used by other CodexSwitch state.

## Transfer Transaction

A successful transfer has one publication order:

1. Validate and hash the source through its opened descriptor.
2. Copy into a unique destination-side staging directory with a bounded
   transport timeout.
3. Hash the staged destination and compare it with the source digest.
4. Set private permissions and atomically rename the staged file into the final
   inbox.
5. Record a bounded append-only audit entry.
6. Remove an outbox source only after the destination digest is verified and a
   fresh source check proves the local content still matches the transferred
   bytes.

Failure before publication leaves the existing destination untouched. A digest
mismatch deletes only the verified staging path. It never deletes or replaces
the source merely because a network command returned success.

## Directory Archives

Directory transfer creates one tar archive plus an adjacent SHA-256 file. The
source walk rejects symlinks. Extraction validates the complete member table
before writing and requires exactly one safe top-level entry.

Extraction has explicit member-count and uncompressed-byte limits. It accepts
directories and regular files only, streams file contents into a private
staging directory, strips group/other permissions, and atomically publishes the
validated top-level result. The archive input itself must be a regular,
current-owner, non-symlink file.

## Knowledge Sync

Knowledge sync is for non-secret agent findings. It refuses identical local and
remote endpoints, uses one host-local lock, stages changes, and places divergent
edits in `.conflicts/` for review. It does not infer that matching paths on one
host represent two independent replicas.

## Audit And Retention

Transfer audit records are JSON Lines written under an exclusive lock with
`O_APPEND`. Each entry and active log has a size bound. Rotation is deterministic
and retains a fixed number of current-owner regular files; no append rewrites
the complete history.

Temporary transfer directories, manifests, partial files, and rotated logs all
have explicit ownership and retention. Startup cleanup may remove only artifacts
whose path, type, owner, age, and naming contract prove CodexSwitch ownership.

## Failure Semantics

- A timeout is failure, not proof that a transfer did or did not publish.
- A missing digest, changed source, wrong owner, symlink, malformed manifest, or
  ambiguous archive is a hard refusal.
- Status commands are observational and do not publish, delete, extract, or
  repair artifacts.
- Retrying is safe because publication is staged and digest-verified; cleanup
  is limited to transaction-owned temporary paths.
- No transfer action restarts Codex, ChatGPT, CodexSwitch, or a VPS service.
