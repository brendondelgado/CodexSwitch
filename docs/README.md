---
title: CodexSwitch documentation
description: Canonical wiki index and source-of-truth hierarchy for CodexSwitch.
toc:
  - CodexSwitch Documentation
  - Purpose
  - Source Of Truth
  - Architecture
  - Operations
  - Plans And Audits
  - Documentation Contract
cross_dependencies:
  - ../AGENTS.md
  - ../CLAUDE.md
  - architecture/system-overview.md
  - architecture/quota-and-reset-policy.md
  - architecture/runtime-and-host-ownership.md
  - architecture/desktop-update-storage.md
  - architecture/macos-runtime-discovery.md
  - architecture/macos-runtime-artifact.md
  - architecture/secure-drop-transport.md
version_control:
  branch: main
  status: canonical
  last_updated: 2026-07-13
---

# CodexSwitch Documentation

## Purpose

This directory is the CodexSwitch wiki. It explains both what the system does and why it is designed that way. It is intended for maintainers, Claude, Codex, incident responders, and deployment operators.

## Source Of Truth

When sources disagree, use this order:

1. Versioned architecture contracts under `docs/architecture/`.
2. Deterministic tests that exercise the contract.
3. Current source code.
4. Current repository plan and audit status.
5. Operational runbooks.
6. Deployed artifact behavior, after checking its Git provenance.
7. Logs, UI labels, comments, and historical plans.

A deployed VPS binary may be older than the repository. A UI can also be stale while the runtime has already reloaded. Treat these as distinct state layers.

## Architecture

- [System overview](architecture/system-overview.md): responsibilities, components, data flow, persistence, and boundaries.
- [Quota and reset policy](architecture/quota-and-reset-policy.md): optional windows, candidate ranking, plan priority, natural resets, and banked-reset safety.
- [Runtime and host ownership](architecture/runtime-and-host-ownership.md): Mac/VPS authority, activation transactions, hot reload, remote sessions, updates, and storage.
- [Credential bundle format](architecture/credential-bundle-format.md): authenticated versioned Mac-to-VPS credential transport and legacy-read compatibility.
- [Desktop update storage](architecture/desktop-update-storage.md): staged-generation validation, reuse, publication, retention, and install guards.
- [macOS runtime discovery](architecture/macos-runtime-discovery.md): process enumeration, identity binding, partial discovery, and fail-closed signal targeting.
- [macOS runtime artifact](architecture/macos-runtime-artifact.md): native build provenance, three-binary manifest validation, staging, and atomic activation.
- [macOS CLI launcher](architecture/macos-cli-launcher.md): prevalidated runtime routing without per-invocation binary scans or fallback ambiguity.
- [Subprocess execution](architecture/subprocess-execution.md): bounded output capture, timeout escalation, reaping, and actor-isolation rules.
- [SecureDrop transport](architecture/secure-drop-transport.md): artifact integrity, staging, extraction, deletion safety, and retention.
- [Session retention contract](architecture/session-retention-contract.md): preservation and representation of remote thread history.

## Operations

- [Hot-swap verification](runbooks/codexswitch-hot-swap-verification.md): deterministic readiness and activation checks.
- [Linux repository deployment](runbooks/linux-repository-deployment.md): immutable staged releases, activation, provenance, and rollback.
- [VPS connection resilience](runbooks/vps-connection-resilience.md): transport and service resource policy.
- [VPS thread repair](runbooks/codex-vps-thread-state-heal.md): explicit thread-state recovery; status checks never heal.
- [Runtime storage hardening](runbooks/runtime-storage-hardening-deployment.md): bounded rollout and runtime storage.
- [SIGHUP safety](sighup-safety.md): signal target verification and historical failure modes.

## Plans And Audits

- [Clean-code recovery plan](plans/2026-07-12-codexswitch-clean-code-recovery.md): ordered remediation work and verification gates.
- [Hot-swap reliability closure](plans/2026-07-21-hot-swap-reliability-closure.md): incident evidence, permanent invariants, replay gates, and controlled activation procedure.
- [Codebase audit](audits/2026-07-12-codebase-audit.md): findings, impact, and current disposition.
- [Runtime storage plan](plans/2026-07-12-runtime-storage-hardening.md): archive and storage lifecycle work.

Plans authorize repository changes only. They do not authorize live service interruption, reset redemption, destructive cleanup, or deployment activation.

## Documentation Contract

- Every Markdown document has YAML frontmatter with `toc`, `cross_dependencies`, and `version_control`.
- Architecture pages define invariants and rationale. They do not contain one-off operator transcripts.
- Runbooks contain commands, readiness checks, rollback steps, and expected evidence. They do not redefine policy.
- Audits distinguish observed defects, fixed repository behavior, staged behavior, and deployed behavior.
- Behavior changes update docs, code, and tests in the same branch.
- Historical documents are marked superseded rather than silently left as competing truth.
