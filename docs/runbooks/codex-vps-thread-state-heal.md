---
title: Codex VPS thread state repair
description: Explicit recovery procedure for incomplete VPS thread metadata; automatic repair from connection commands is intentionally disabled.
toc:
  - Intent
  - Current behavior
  - Repair contract
  - Verification
cross_dependencies:
  - scripts/codex-vps
  - ~/.codex/state_5.sqlite
  - ~/.codex/session_index.jsonl
  - ~/.codex/goals_1.sqlite
  - docs/plans/2026-07-12-codexswitch-clean-code-recovery.md
version_control:
  status: uncommitted
  last_updated: 2026-07-12
---

# Codex VPS Thread State Repair

## Intent

Recover a thread whose persistent metadata is incomplete without allowing normal connection, list, status, or resume commands to mutate live Codex state.

## Current Behavior

Automatic thread-state healing is disabled. `codex-vps list`, `use`, `resume`, `old`, `--check`, and normal connection paths are observational or perform only their named session action. They do not decompress rollouts, write `state_5.sqlite`, or rewrite thread metadata.

This replaces the former implicit guard that could race the app-server and overwrite a concurrently updated rollout. Canonical UUID validation also occurs before a thread identifier can reach remote shell, persistence, or RPC boundaries.

## Repair Contract

Thread repair must be an explicit maintenance command implemented behind a single-writer lease. Before any mutation it must:

1. Prove the target app-server is stopped or holds a cooperative maintenance lease.
2. Validate the thread ID as a canonical UUID.
3. Record the source database generation and rollout identity.
4. Create and verify a SQLite backup outside the active database path.
5. Stage recovered rollout and metadata files without replacing live files.
6. Commit only when the source generation is unchanged.
7. Abort without mutation when any identity, generation, or integrity check fails.

The repair implementation must use synthetic SQLite and rollout fixtures before it is allowed against a live VPS. Until that lease-backed command exists, recovery remains a manual, separately authorized operation.

## Verification

Automated tests must prove that ordinary `codex-vps` commands never invoke thread repair, malformed or shell-active thread IDs are rejected before network access, and a simulated concurrent database generation change prevents repair commit.
