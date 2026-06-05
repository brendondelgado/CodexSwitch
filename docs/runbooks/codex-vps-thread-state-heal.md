---
toc:
  - Codex VPS Thread State Heal
cross_dependencies:
  - scripts/codex-vps
  - ~/.codex/state_5.sqlite
  - ~/.codex/session_index.jsonl
  - ~/.codex/goals_1.sqlite
version_control:
  status: uncommitted
  last_updated: 2026-06-01
---

# Codex VPS Thread State Heal

`codex-vps` repairs a default or resumed VPS thread before listing or connecting when the persistent thread row is incomplete.

The guard covers the failure mode where `threads.rollout_path` points at a missing `.jsonl` while the real rollout exists as `.jsonl.gz`, or where `title`, `cwd`, `source`, `thread_source`, `preview`, or `first_user_message` are blank even though `session_meta` and `session_index.jsonl` still have the source-of-truth values.

Before mutating `~/.codex/state_5.sqlite`, the guard creates a SQLite backup named `state_5.sqlite.bak-codex-vps-heal-<timestamp>`. It then materializes the missing `.jsonl` from `.jsonl.gz` and restores metadata from the rollout `session_meta` plus the latest matching `session_index.jsonl` entry.

This prevents the app-server thread list from dropping or blanking a still-active long-running thread after refresh.
