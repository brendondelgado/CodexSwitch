---
title: Hot-swap reliability closure
description: Evidence, invariants, implementation work, and activation gates required to close the Mac and VPS hot-swap incident.
toc:
  - Hot-Swap Reliability Closure
  - Incident Evidence
  - Reliability Invariants
  - Implementation Work
  - Verification Matrix
  - Activation And Rollback
cross_dependencies:
  - ../architecture/runtime-and-host-ownership.md
  - ../runbooks/codexswitch-hot-swap-verification.md
  - ../audits/2026-07-12-codebase-audit.md
  - ../../crates/codexswitch-cli/src/activation.rs
  - ../../crates/codexswitch-cli/src/readiness.rs
  - ../../crates/codexswitch-cli/src/reload.rs
  - ../../crates/codexswitch-cli/src/rate_limit_resets.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_app_server_patching.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_app_server_template.rs
  - ../../Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - ../../scripts/codex-vps
version_control:
  branch: main
  status: active
  last_updated: 2026-07-21
---

# Hot-Swap Reliability Closure

## Incident Evidence

The 2026-07-21 incident is a multi-stage convergence failure, not a quota-selection failure:

1. The VPS remote-control app-server reloaded backend auth but could not prove a completed `account/updated` frontend write.
2. The resulting degraded activation later became a durable `ManualReview` barrier after token material changed.
3. The VPS daemon rejected that barrier every polling interval, so rotation and bootstrap acknowledgement repair stopped.
4. The current systemd app-server had no process-bound version-3 acknowledgement, while readiness still accepted its start time relative to `auth.json` as green evidence.
5. The Mac remote presentation retained its previous green result after later readiness checks stopped succeeding.
6. `codex-vps --check` selected a client against one remote version observation, rebuilt its transport, then printed a second remote observation as equal without comparing it. The incident produced an `0.144.4 == 0.144.6` status line.
7. The installed Mac menu app predates the latest desktop auth ordering fix even though the managed Mac Codex launcher already selects Codex `0.144.6`.

These observations distinguish configured account state, auth-file state, running process state, and UI presentation state. None may stand in for another.

## Reliability Invariants

1. **Acknowledgement-only readiness.** Marker strings, process age, auth-file modification time, successful signal delivery, and backend auth reload are never sufficient for green. Every live account-bearing runtime must provide a current version-3 acknowledgement bound to PID, start identity, executable identity, request nonce, auth-file identity, and complete token fingerprint.
2. **Live-writer delivery proof.** A disconnected frontend that rejects enqueue is not eligible. When eligible frontend writers exist, every eligible writer must complete the transport write before acknowledgement. A headless remote-control listener may acknowledge an idle reload only when no live writer accepted delivery; historical disconnected connections cannot force a permanent degraded barrier.
3. **Durable barrier ownership.** A recognized legacy token-refresh mismatch may reconcile only when exactly one active account and the complete current store/auth token set agree. Every other `ManualReview` record requires the explicit `resolve-activation --yes` transaction. Journal deletion and manual credential rewriting are prohibited recovery methods.
4. **Observation is side-effect free.** `status`, `doctor`, auth diagnostics, and Mac remote monitoring do not create lock files, chmod state, save updater state, signal processes, redeem resets, or repair data.
5. **One remote-version snapshot.** A remote client is selected and reported against one bound app-server version observation. If transport establishment changes the observed version, readiness fails and the operator reruns the check or explicitly synchronizes the client.
6. **No stale green.** A failed, incomplete, expired, or barrier-blocked remote check invalidates prior green presentation immediately. A timestamped cached result may be displayed only as stale and never as readiness.
7. **One controlled activation.** Source, tests, artifact provenance, and replay evidence must be green before replacing a menu app or managed runtime. Activation happens once at a quiescent boundary and is followed by process-bound acknowledgement verification.
8. **Permanent regression gate.** Every change to activation, reload, discovery, frontend delivery, remote transport, or readiness runs the shared reliability suite in CI before it can be considered releasable.
9. **Evidence cannot be reminted.** A historical ACK cannot receive a fresh lease merely because it is reread. Runtime evidence retains its original acknowledgement time and concrete process binding, and topology is revalidated immediately before `Confirmed` is published.
10. **The interrupted turn proves its own handoff.** An in-turn usage or auth failure passes a turn-generated receipt nonce through `rotate-now`, verifies the exact resulting request and ACK, proves that its own `AuthManager` changed to the acknowledged fingerprint, and only then retries once.
11. **Asynchronous observations are generation-bound.** External auth and desktop status reads capture configured account, swap generation, and activation generation before suspension. A result is discarded if any of those facts changed while the read was in flight.
12. **Desktop updates prove compatibility before activation.** The exact stock bundle is patched in staging, repacked, strictly signed, and inspected for the complete marker set. A changed minified shape fails closed until a narrow semantic fixture covers it; a native-safe upstream path may be marked only after its data flow is proven.

## Implementation Work

- Remove app-server start-time fallback from Rust readiness classification.
- Make frontend delivery count only successfully enqueued live connections, require complete delivery to all eligible writers, and encode strict idle-listener evidence.
- Preserve exact legacy-barrier reconciliation and the explicit generic manual-review resolver, with fault-injection tests proving journal bytes survive every failed resolution.
- Make updater and credential observations read-only without weakening no-follow, ownership, mode, size, and stable-read validation.
- Bind `codex-vps` version selection and reporting to one snapshot and add a transport-change regression fixture.
- Invalidate Mac VPS readiness on command failure, missing acknowledgement, manual-review barriers, and freshness expiry.
- Bind external-auth observations to swap and activation generations, preserve typed partial desktop counts, and revalidate concrete runtime topology before confirmation.
- Use one five-minute acknowledgement freshness boundary across runtime, daemon, readiness, and injected-turn validation. Only an explicit activation or rotation may mint fresh reload evidence; observers never signal a runtime merely to renew readiness, and expired evidence is reported as not ready.
- Bind an injected turn to the exact control executable, receipt nonce, post-rotation ACK, and independently reloaded turn-local `AuthManager`.
- Persist the Rust reset attempt's selected-credit expiration and complete
  normalized starting credit-ID set. Disappearance proves a local redemption
  only for the exact selected, still-unexpired credit and an exact one-credit
  transition that preserves every other starting credit; natural expiry and a
  different or multiple removed credit remain unresolved without another POST.
  Inventory observations are timestamped only after the complete response is
  read, oversized identifiers fail before journaling, and a post-save sentinel
  or missing exact-attempt readback cancels submission before provider I/O.
- Add a CI reliability workflow covering Swift tests, Rust contract tests, Python and shell harnesses, patch generation, and workflow linting.
- Exercise the exact latest desktop bundle in staging and keep compact fixtures for every changed upstream semantic shape; never learn compatibility by mutating the live app.
- Build the Mac app and managed runtime from the exact reviewed commit, with attestations and manifests checked before activation.

## Verification Matrix

| Scenario | Required result |
| --- | --- |
| Marker-only app-server with no ACK | Not ready |
| App-server started after `auth.json`, no ACK | Not ready |
| Headless listener with zero live eligible writers | ACK may prove idle readiness |
| Disconnected historical frontend rejects enqueue | Excluded from eligible writer count |
| Two eligible writers, one completed write | No ACK |
| Every eligible writer completes | ACK contains exact counts and binding |
| Recognized legacy mismatch with exact store/auth agreement | Reconcile same target, then require ACK |
| Generic manual review | No automatic mutation; explicit resolver only |
| Remote version changes while transport is established | Check fails; never prints equality |
| Remote check fails after a green result | Presentation becomes not ready/stale immediately |
| Read-only diagnostics on a non-writable store | No lock or state file is created or changed |
| Usage limit during a Codex turn | One verified rotation, exact AuthManager reload, one transparent retry |
| Historical ACK is reread | Original evidence time remains; no fresh lease is minted |
| Runtime exits or appears after ACK | Final topology revalidation blocks confirmation |
| External auth read returns after a newer swap | Stale observation is discarded without changing account state |
| Child rotation report lacks the turn receipt nonce | Original turn is not retried |
| Selected banked reset expires before reconciliation | Attempt remains unresolved; no second POST |
| A different credit or more than one credit disappears | Attempt remains unresolved and the unexplained change is not attributed locally |
| Credit expires while inventory GET is in flight | Response-completion time classifies natural expiry; no consumption proof or external hold |
| Provider supplies an oversized credit identifier | Inventory is not redeemable; no reset attempt or POST |
| Latest desktop minified shape is unknown or ambiguous | Staged patch fails before repack; live app is untouched |
| Latest desktop already implements the safe data flow | Narrow proof adds the compatibility marker without changing behavior |

## Activation And Rollback

1. Merge reviewed docs, source, and deterministic tests to `main`.
2. Build provenance-locked Mac app and runtime artifacts from that exact commit.
3. Stage artifacts without changing live process ownership.
4. At one approved quiescent boundary, activate the VPS release and Mac menu app. Do not repeatedly quit or foreground ChatGPT for probing.
5. Reconcile the existing VPS barrier through the supported transaction. Do not delete it.
6. Require a fresh acknowledgement for every discovered Mac and VPS account-bearing runtime, a `Confirmed` activation record, matching store/auth fingerprints, and no daemon barrier errors over an observation interval.
7. Roll back the immutable release pointer or app bundle if any activation check fails. Preserve the activation journal and diagnostic evidence.
