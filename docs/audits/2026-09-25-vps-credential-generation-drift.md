---
title: VPS credential generation drift incident
description: Verified September 25 account-selection failure, bounded recovery gates, and automatic target-admission regression contract.
toc:
  - VPS Credential Generation Drift
  - Verified Cause
  - Current Boundaries
  - Recovery Contract
  - Regression Contract
  - Temporary Service Restoration
  - Release Verification
  - Verification Record
cross_dependencies:
  - ../architecture/quota-and-reset-policy.md
  - ../architecture/runtime-and-host-ownership.md
  - ../runbooks/linux-repository-deployment.md
  - ../../crates/codexswitch-cli/src/main.rs
  - ../../crates/codexswitch-cli/src/daemon.rs
  - ../../Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - ../plans/2026-09-24-vps-reliability-repair.md
version_control:
  branch: codex/vps-reliability-release-20260924
  status: release-staged-awaiting-client-disconnect
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

At initial inspection, the Mac had a newer complete credential generation,
expiring September 27 at 18:37:54 UTC. A read-only provider request made from the VPS with that generation
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

Do not clear authentication quarantine by hand, retire the unresolved sync hold
outside the guarded recovery procedure,
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

## Temporary Service Restoration

While native release verification ran, the approved bounded repair restored
usable VPS credentials without restarting Codex runtime PID 79174:

1. Unloaded only the Mac watchdog, preserving its plist, and gracefully quit the
   verified CodexSwitch process. Stopped only `codexswitch.service` on the VPS.
2. The recovery guard rejected group-writable `.local` and `.local/share`
   ancestors before any credential mutation. Narrowed those two signul-owned
   application directories from 0775 to 0755, preserving group read/execute.
   Original modes are recorded privately at
   `/home/signul/.codexswitch/credential-repair-directory-modes-1790342007720374680.json`.
3. Preserved private store/auth/authority/activation backups under
   `/home/signul/.codexswitch/credential-repair-ef729d2c-3285-4f0f-b86e-1b3ac13fc21d`.
4. Temporarily selected the prevalidated paid account at authority epoch 116,
   then delivered only the inactive target's complete newer credentials using
   the unchanged installed targeted-reauthentication helper. All ten other
   account records and the active auth file remained unchanged during delivery.
5. Revalidated provider quota, restored the original target at epoch 117, and
   required a real acknowledgement from unchanged runtime PID 79174. Targeted
   polling confirmed usable quota. No banked reset was redeemed.
6. Resumed the same VPS coordinator release as PID 1101286 and the unchanged Mac
   app as PID 10563. The watchdog resumed. VPS doctor reports ready, confirmed
   activation, eleven accounts, and no issues. The Mac remains on the same
   provider account with complete store/auth agreement.

The VPS now uses credential fingerprint prefix `e01655e35f9f`. On startup, the
Mac normally refreshed that account again to prefix `8e3086ab5ba9`; its newer
generation will travel through normal sync after the protocol deployment.
This temporary repair is not full-pool convergence or permanent sync recovery.

The old sync journal remains byte-for-byte unchanged, with SHA-256
`5af82d389874369df96fee89d9780373ca2b575d497cc65718c263c618013d3e`.
The installed Mac already supports durable receipt lookup and baseline compare-
and-swap, but deployed `7f60` does not. Upgrade the VPS, perform guarded legacy
retirement, clear only the matching non-authoritative preference hold, and
verify a new complete-pool import receipt before declaring sync repaired.

## Release Verification

The full native Linux and Mac contract runs `36138439681` and `36138477905`
passed before [repair PR 2](https://github.com/brendondelgado/CodexSwitch/pull/2)
merged at 14:03 UTC. Native evidence includes 88 installer fixtures, 25 runtime-
record repair fixtures, 39 legacy-recovery fixtures, CLI and integration tests,
and the executable generated-runtime contract. The Swift run passed 1,099 tests.

Merge commit `73ff954dbc68ad3013085a8a8b0af0320e592620` has the exact reviewed
`e8c40a4` tree. [Runtime build 36144987554](https://github.com/brendondelgado/CodexSwitch/actions/runs/36144987554)
was dispatched from that exact main commit with upstream Codex `0.153.2`,
commit `657a993cbee87acf52d14b758ce49dbd46d1b8eb`, and no expired-artifact reuse.
The complete build passed at 15:53 UTC. Artifact `10874066850`, attempt 1,
was downloaded directly to the VPS. The repository staging helper verified all
four hosted-workflow attestations against the exact commit, then verified the
quarantined and promoted bytes. Dry-run and stage-only installation passed.

The inactive release is
`/home/signul/.local/share/codexswitch/releases/0.1.0-73ff954dbc68ad3013085a8a8b0af0320e592620`.
Its CLI SHA-256 is
`6d6852c4607f6cd942c618db3def196f797bfd3ee18d3aaca774341aa48af59e`;
release-manifest SHA-256 is
`61cf40ed69549e5210aeb56f137419fe7b5183b53c8b3cff7d22a66ed9ee2967`.
The upstream runtime and code-mode helper reproduce the previously deployed
digests. `current` still resolves to `7f60`; activation and all automatic start
and enable flags were zero during staging.

[Maintenance PR 3](https://github.com/brendondelgado/CodexSwitch/pull/3) added
the independently reviewed, identity-bound stop-only helper and its native
Linux CI step. All checks passed before its 15:06 UTC merge as
`6b4d13b58c2a5a183444ab4ac197ab3d4292410a`. This operator-script change does not
change the already-dispatched runtime artifact identity.

The desktop app owns both the local task runner and the VPS SSH connection;
quitting it would interrupt local work. Deployment therefore requires the user
to disable only `Connect codex-vps` in Settings > Connections, followed by fresh
proof that its SSH/proxy owner exited. Desktop automation refuses to control
that app; no alternate control path or cached-state-file edit is authorized by
that refusal. Other VPS clients and restart sources require separate, bounded
quiescence. The user was asked to turn off that connection after staging passed.
No VPS runtime stop, new-release activation, or legacy-hold retirement has
happened while awaiting that action.

During the build the desktop app restarted independently of this operation.
Its replacement PID 61025 owns the local task runtime PID 61147 and SSH client
PID 61312. A fresh read-only VPS shutdown preflight found runtime PID 79174 idle;
that observation must be repeated immediately before any maintenance action.

The desktop restart refreshed local auth at 15:55 UTC to fingerprint prefix
`470176575b5e`, but the Mac account store retained `8e3086ab5ba9`. Source review
showed that the installed handoff check defers a same-account file mismatch
while the Swift journal is confirmed. No direct credential-file overwrite or
journal clearing was used. At 16:11 UTC, only CodexSwitch was gracefully
restarted after private snapshots under
`~/.codexswitch/backups/credential-source-reconcile-21276768-4f7c-4afd-9edd-e76b8b3c7549`.
Its existing newer-generation recovery adopted the observed auth, preserving
the refreshed generation. All four credential fields then matched, with a
confirmed one-of-one runtime acknowledgement. Desktop and local runtime PIDs
61025 and 61147 remained unchanged; the legacy hold hash remained unchanged.
This reconciles the current source generation, but does not fix the separate
same-account observation deferral in the installed Mac code.

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
  on September 25. Publication, full native verification, attested building, and
  inactive staging are complete; activation awaits desktop client disconnection.
- Temporary active-account credential restoration is verified above. Permanent
  protocol deployment, legacy-hold retirement, and complete-pool convergence
  remain outstanding. No reset credit or Codex-runtime restart was required for
  the temporary restoration.
