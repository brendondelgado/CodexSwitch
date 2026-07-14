---
title: Claude repository guide
description: Entry point for Claude and other coding agents working in CodexSwitch.
toc:
  - Claude Repository Guide
  - Read This First
  - Documentation Routing
  - Non-negotiable Rules
  - Current Migration State
  - Working Method
cross_dependencies:
  - AGENTS.md
  - docs/README.md
  - docs/architecture/system-overview.md
  - docs/architecture/quota-and-reset-policy.md
  - docs/architecture/runtime-and-host-ownership.md
  - docs/architecture/secure-drop-transport.md
  - docs/plans/2026-07-12-codexswitch-clean-code-recovery.md
version_control:
  branch: main
  status: canonical
  last_updated: 2026-07-12
---

# Claude Repository Guide

## Read This First

CodexSwitch is a multi-account Codex quota and runtime coordinator for a Mac and a Linux VPS. Its core job is deliberately narrow:

1. Observe account quota and reset inventory.
2. Select an eligible account according to one policy.
3. Commit a complete account activation transaction on the local host.
4. Reload verified Codex runtimes without interrupting unrelated processes.
5. Report state without mutating it.

Start with [the documentation index](docs/README.md). Do not derive architecture from one old runbook, UI label, deployed binary, or comment.

## Documentation Routing

| Question | Canonical source |
| --- | --- |
| What owns each responsibility? | `docs/architecture/system-overview.md` |
| How are quota windows, candidates, and banked resets handled? | `docs/architecture/quota-and-reset-policy.md` |
| How do Mac, VPS, remote sessions, reloads, and updates interact? | `docs/architecture/runtime-and-host-ownership.md` |
| How are artifacts transferred safely between the Mac and VPS? | `docs/architecture/secure-drop-transport.md` |
| What is currently being cleaned up? | `docs/plans/2026-07-12-codexswitch-clean-code-recovery.md` |
| What defects were found and what remains? | `docs/audits/2026-07-12-codebase-audit.md` |
| How is hot-swap verified? | `docs/runbooks/codexswitch-hot-swap-verification.md` |
| How is a VPS release deployed or rolled back? | `docs/runbooks/linux-repository-deployment.md` |

## Non-negotiable Rules

- Preserve live work. Do not kill, restart, replace, patch, deploy, redeem a reset, or delete state merely to inspect it.
- One coordinator owns account mutation per host. Remote VPS state must never silently become Mac local state.
- Missing quota windows are absent capabilities. Never manufacture a five-hour value when the API exposes only weekly usage.
- Status and diagnostics are read-only. Healing and activation are explicit commands.
- Persist and reconcile a reset attempt before another reset can be redeemed.
- Signals require verified PID, start time, owner, and executable identity immediately before delivery.
- Every storage producer has semantic change detection, a retention bound, and safe startup cleanup.
- Hermes is not a CodexSwitch responsibility. The repository integration was removed; do not add source, commands, token sync, service control, tests, or documentation that couples it back to CodexSwitch.
- Do not run large Rust builds in the repository on the Mac. Use a temporary target directory, one build job, and reduced priority.
- Repository changes follow DOCUMENT -> IMPLEMENT -> TEST -> VERIFY -> MERGE.

## Current Migration State

The repository is moving from duplicated Swift/Rust policy and opportunistic scripts to explicit contracts. During this transition:

- Canonical architecture documents describe the target invariant.
- The audit identifies current violations and their remediation status.
- Runbooks describe procedures, not product policy.
- Tests are the executable proof for behavior already implemented.
- A live VPS deployment can lag the repository until a staged idle activation is approved and verified.

Never claim a repository fix is active on the VPS until the deployed artifact reports matching provenance and the post-activation checks pass.

## Working Method

1. Read frontmatter and route to the smallest relevant document.
2. Confirm repository state and live-process ownership before mutation.
3. Update the canonical document when behavior changes.
4. Add deterministic contract tests before widening rollout.
5. Test locally with bounded resources.
6. Stage deployments separately from activation.
7. Record observed evidence, remaining risk, and rollback state.
