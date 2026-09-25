---
title: VPS credential generation drift incident
description: Verified September 25 account-selection failure, bounded recovery gates, and automatic target-admission regression contract.
toc:
  - VPS Credential Generation Drift
  - Verified Cause
  - Current Boundaries
  - Recovery Contract
  - Regression Contract
  - Verification Record
cross_dependencies:
  - ../architecture/quota-and-reset-policy.md
  - ../architecture/runtime-and-host-ownership.md
  - ../runbooks/linux-repository-deployment.md
  - ../../crates/codexswitch-cli/src/main.rs
  - ../../crates/codexswitch-cli/src/daemon.rs
  - ../../Sources/CodexSwitch/Services/LinuxDevboxReauthentication.swift
  - ../../scripts/test_targeted_reauthentication.py
version_control:
  branch: codex/vps-reliability-release-20260924
  status: prevention-tested-live-repair-pending
  last_updated: 2026-09-25
---

# VPS Credential Generation Drift

## Verified Cause

The deployed release is `7f60ba3c691ea9bafe91df66f0b8abc266a769b6`.
At 12:02 UTC on September 25, VPS authority epoch 115 selected provider
`df3c3241-56e1-4dfb-b6aa-dd0f6e3286a1` for `quotaExhausted`. Store, auth,
and the runtime acknowledgement agreed on that selection, but they agreed on
expired credentials. A reload acknowledgement proves delivery, not provider
acceptance or available quota.

The VPS token expired September 23 at 15:30:46 UTC. At 15:25:52.963 UTC that
day, the daemon attempted proactive refresh. At 15:25:53.102 UTC the provider
returned HTTP 401 with `refresh_token_reused`. The resulting authentication
quarantine lasts until October 23. Retrying that same refresh token is not a
credential repair. The logs do not identify which client consumed it first.

The Mac has a newer complete credential generation, expiring September 27 at
18:37:54 UTC. A read-only provider request made from the VPS with that generation
succeeded and confirmed usable weekly quota. Thus lack of account capacity is
not the primary incident cause.

Two failures combined:

1. The unresolved, receipt-less September 9 credential-sync operation continued
   to hold back automatic delivery of the newer generation.
2. The deployed automatic pool-target request path accepted a Mac-selected
   provider identity without validating that provider's VPS-owned credentials,
   runtime quarantine, quota freshness, or automatic-plan eligibility.

The request reason and timing match the Mac's automatic swap path, but the
exact authority request UUID is absent from Mac logs. Caller attribution is
therefore strongly supported, not independently proven.

## Current Boundaries

The existing targeted reauthentication service only changes inactive remote
accounts. Its active-target refusal must remain intact because it does not
perform runtime activation. A single-account `update-bundle` is not a safe
substitute: deployed merge semantics replace pool membership.

Do not clear authentication quarantine by hand, retire the unresolved sync hold,
retry a reused refresh token, spend reset credits, or claim that repository
changes are deployed. Automatic reset spending remains disabled.

## Recovery Contract

The supported bounded workaround requires an explicitly accepted maintenance
window. Keep Codex processes running, but do not promise uninterrupted VPS
turns while the temporary account has exhausted quota.

1. Validate the complete newer credentials and usable quota from the VPS.
2. Verify the temporary paid account has complete, unblocked, unexpired
   credentials. Preserve private recovery evidence and the old sync-hold hash.
3. Pause only account coordinators, including the Mac relaunch watchdog; leave
   Codex runtimes and unrelated services alone. Confirm no old importer remains.
   A Mac relaunch can resume staged updater recovery, so prove that startup is
   safe before using quit/relaunch as the pause mechanism. Process suspension
   alone does not drain already-dispatched SSH mutations.
4. Request a temporary target with a fresh UUID and expected authority epoch.
   Require stable authority and confirmed runtime delivery.
5. Deliver the newer generation through the unchanged targeted reauthentication
   service over authenticated SSH stdin. Require the locked inactive-target
   check and independently verify all other accounts and pool order are retained.
6. Revalidate usable target quota, then request the original target using a new
   UUID and fresh epoch. Any uncertain result requires observation, not a blind
   retry or unconditional rollback.
7. Require matching store, auth, and runtime credential fingerprints, a fresh
   runtime acknowledgement, usable observed quota, and ready diagnostics.
8. Resume only the coordinators paused by this operation, with unchanged policy.
   Recheck live convergence and the unchanged legacy hold.

## Regression Contract

Automatic admission must reject VPS-expired, near-expiry, incomplete,
quarantined, denied, exhausted, stale, unknown, and excluded-plan targets before
authority/auth/reload effects. Explicit manual selection semantics stay separate.

Validate request identity before reconciliation. An idempotent acknowledgement
of an already-completed decision must not authorize new activation effects for
an unfinished decision that has since become ineligible. Revalidate account
generation before committing credentials; concurrent replacement must not be
overwritten or reported as successful convergence.

## Verification Record

- Provider validation from the VPS passed with the newer Mac generation.
- A separate provider observation reported allowed weekly quota, 4% used.
- Existing targeted reauthentication fixtures: 24 passed on September 25.
- Automatic admission: 12 focused fixtures passed; the full macOS CLI suite
  passed 665 tests with one ignored, plus three integration tests passed.
- Independent review found no remaining P1/P2 issues after tightening replay
  eligibility. The direct admission-to-lock timing race is not a dedicated
  fixture; existing store-generation checks protect concurrent replacement.
- `git diff --check` passed. Added Rust code is format-clean; whole-file
  formatting still reports six unchanged baseline issues.
- The user authorized repairing the blocked sync and deploying required patches
  on September 25. Publication, native Linux release verification, and activation
  are proceeding through the existing provenance and runtime-safety gates.
- Live credential repair has not started. No coordinator pause, reset redemption, import, quarantine
  removal, release activation, or runtime restart has occurred in this repair.
