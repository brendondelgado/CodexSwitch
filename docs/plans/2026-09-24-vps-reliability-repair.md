---
title: VPS reliability repair
description: Live ownership recovery and bounded verification of account rotation reliability.
toc:
  - VPS Reliability Repair
  - Scope
  - Contract And Fixtures
  - Workstreams
  - Approved Maintenance Sequence
  - Evidence
cross_dependencies:
  - ../architecture/runtime-and-host-ownership.md
  - ../runbooks/linux-repository-deployment.md
  - ../../crates/codexswitch-cli/src/codex_update/runtime_discovery.rs
  - ../../crates/codexswitch-cli/src/daemon.rs
  - ../../crates/codexswitch-cli/src/reload.rs
version_control:
  branch: codex/vps-reliability-20260924
  base_commit: 7f60ba3c691ea9bafe91df66f0b8abc266a769b6
  status: live-ownership-repaired-hardening-tested-not-deployed
  last_updated: 2026-09-24
---

# VPS Reliability Repair

## Scope

User authorized repair of VPS CodexSwitch reliability and related issues on
2026-09-24. Preserve active app-server sessions, unrelated processes, credentials,
and dirty checkouts. Do not promise absence of all future failures. Explicitly
distinguish tested behavior, live verification, and remaining external risks.

## Contract And Fixtures

Runtime discovery remains read-only and fails closed on ambiguous ownership.
An explicit stale-record repair must hold the existing startup/installation
guards, prove the recorded owner is absent, bind the single live expected runtime
to its owner, executable, start identity, arguments, and socket, then revalidate
before an atomic metadata-only correction. No restart or unverified signal is
permitted. Preserve a private rollback record and make the operation idempotent.

Regression fixtures must reject live conflicting owners, PID reuse, multiple
servers, changed release routes, symlinks, unowned paths, lock contention, and
identity changes during observation. Replay the repair in temporary fixtures
before applying the exact same tool on the VPS. Verify daemon acknowledgement
renewal and readiness after the repair, without fabricating acknowledgement data.

The exact-runtime scan must distinguish unrelated executable inodes before an
oversized command line can block discovery. Unknown executable identity remains
fail-closed; matching runtimes retain bounded arguments and full identity checks.
Replay includes oversized arguments on both unrelated and matching executables.

## Workstreams

1. Repair stale app-server ownership and prevent recurrence with deterministic
   ownership/reload tests and live readiness checks.
2. Diagnose quota/reset API timeouts and refresh/retry behavior without exposing
   credentials or consuming resets.
3. Audit storage pressure and retention; protect live sessions and private data.
4. Verify Mac/VPS account consistency and activation barriers, with no blind
   credential overwrite or manual switching merely for inspection.

## Approved Maintenance Sequence

At 16:57 UTC the user approved a brief VPS maintenance interruption and continued
agent assistance. This authorizes a coordinated runtime stop only after the
candidate release is staged and verified; it does not authorize unrelated
process termination or removal of user data. Publication and merge approval is
requested separately because the attested Linux workflow requires exact main
provenance.

1. Review the repair against current origin/main and rerun deterministic
   contracts, preserving unrelated Mac changes and existing dirty checkouts.
2. Publish only after approval, obtain an exact-main attested Linux artifact,
   verify its inventory and signatures, and stage through the canonical installer.
   The September 5 artifacts are expired, so their reuse run IDs are not valid
   inputs; do not bypass attestation or relabel the test-only build.
3. Reobserve exact process ownership and rollback provenance. Gracefully stop
   only approved managed owners, prove quiescence under the installer guards,
   activate, and restore the previously required runtime owners.
4. Verify installed provenance, real runtime acknowledgements, authority and
   credential consistency. Review the legacy receipt-less hold separately with
   a lease-held evidence adapter and private backup; never manufacture historical
   success. Require a fresh operation for complete pool convergence.

## Evidence

Initial VPS daemon is active with zero restarts, and account/auth fingerprints
agree. Runtime PID 967910 listens on the expected Unix control socket, but the
legacy PID record names absent PID 445062. Maintenance fails on this discrepancy,
and `doctor --json` reports not ready. An older real reload acknowledgement exists
but is not accepted as current proof. Recent quota calls timed out. Root disk is
95% used. The deployed release is the exact base commit above.

At 15:57 UTC, the reviewed repair tool quarantined legacy record PID 445062 after
proving live runtime PID 2523043, its Unix socket peer, release inode, start identity,
and process topology under the four existing ownership guards. The original record
is preserved at
`/home/signul/.codexswitch/backups/runtime-ownership/legacy-pid-445062-1790265462644522426.json`.
The exact tool passed 25 deterministic tests on both Mac and Linux. No runtime
restart or direct signal was performed. The next natural daemon rotation switched
to shopszn17 and received a real reload acknowledgement from unchanged PID 2523043;
`doctor --json` reported `ready=true`, `activationState=confirmed`, no activation
barrier, and no issues. One eligible spare candidate remained at that observation.
This establishes runtime recovery, not complete Mac/VPS credential convergence.

At 16:29 UTC the separate Mac recovery worktree passed 289 Swift tests in 12
suites and installed source `3d0c3adfcb9e-dirty.bb480eb37db4` through its guarded
installer. Mac authority adoption then completed against the existing desktop
app-server with a real acknowledgement. Both hosts selected shopszn17, and all
Mac auth-file token fields matched its active account store. The old September 9
receipt-less sync hold remains preserved. Complete pool syncing is not claimed.

No new VPS release was activated. The tested receipt/backoff/discovery hardening
requires the normal quiescent installer window; active user work was preserved.

The final local Rust unit suite passed 655 tests, with zero failures and one
ignored test (183.65 seconds). This includes receipt-ledger interruption and
binding tests, reset cooldown boundaries, HTTP error classification, and bounded
process discovery.

The reviewed repair was integrated locally onto current origin/main
`3bf50c3f1382c8dfa304346e6ffbff1543b9cb5b`; only documentation dates required
conflict resolution, and the Rust source is identical to the reviewed repair.
The 16 Linux artifact workflow tests passed on the Mac. A separate deployment
contract exposed an obsolete assertion pinning a runbook's update date to
September 4 even though current main changed it to September 6. The assertion
now checks the required ISO date field while retaining every behavioral check.
The full Linux installer suite was interrupted on the Mac during its first
activation fixture; no Linux activation pass is claimed from that run, and its
temporary subprocesses were verified exited. Full installer replay remains a
native Linux CI gate.

Existing main CI run `34290121605` completed all 88 installer fixtures in
2312.835 seconds with two failures. The date assertion above was one; the other
was dry-run fixture contamination. Artifact setup invokes a mock controller that
creates the tool log before dry-run begins. A focused replay proved its 152-byte
log remained identical and the install root remained absent. The test now
compares the complete before/after log state instead of requiring nonexistent
setup output; the installer and non-Git-source safety checks are unchanged.

The isolated Linux replay passed 20 focused tests, including both production-path
import fixtures, all six ledger fixtures, three discovery fixtures, and eight
reset/status regressions. The first attempt refused permissive temporary-root
permissions; unchanged source passed with `umask 077`. The network/process-isolated
sandbox hid production credentials and enforced one compiler job, CPU 100%,
memory 2 GiB, tasks 128, and low IO priority. Its 358 MiB target was released;
the test-only source and reports retained about 5 MiB. Archive SHA-256:
`fe84946a296fbcfd98a82673ce851ab01353f0ea8c2fe0da67ccf6504d7e11b2`.
The report is
`/tmp/codexswitch-reliability-test-aqdd31na/reports/verification-result.json`.
At 16:17 UTC, live readiness remained confirmed with zero issues. This test
artifact has unknown build provenance and is not an installable release.

The independent host audit found a kernel OOM kill of prior runtime PID 967910 at
15:43:28 UTC; replacement PID 2523043 started four seconds later. A Python job had
23.42 GiB resident memory and 2.06 GiB swap at that incident. Its exact workload
was not proven. At 15:58 UTC, memory pressure had cleared, with about 22 GiB
available. No unrelated processes were stopped and no user data was deleted.
Concurrent workloads later changed free disk space; the Linux test runner observed
42.1 GiB available at completion. That change is not attributed to this repair.
