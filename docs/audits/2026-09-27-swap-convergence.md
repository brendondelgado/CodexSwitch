---
title: September 27 swap convergence incident
description: Verified failure evidence and bounded Mac and VPS repair contract.
toc:
  - Swap Convergence Incident
  - Evidence
  - Repair Contract
  - Verification
  - Release Staging
  - Mac Activation
  - Remaining VPS Gate
cross_dependencies:
  - ../architecture/runtime-and-host-ownership.md
  - ../../Sources/CodexSwitch/Services/ExternalAuthConflictRecoveryPolicy.swift
  - ../../Sources/CodexSwitch/App/AppDelegate.swift
  - ../../Sources/CodexSwitch/Services/ProcessRunner.swift
  - ../../crates/codexswitch-cli/src/codex_update/runtime_discovery.rs
  - ../../scripts/install-macos-cli-artifact.sh
  - ../../scripts/install-linux.sh
  - ../runbooks/linux-repository-deployment.md
version_control:
  branch: codex/swap-release-evidence-20260927
  status: partial-deployment
  last_updated: 2026-09-27
---

# Swap Convergence Incident

## Evidence

At the start of this incident, the VPS ran release `7f60ba3c`; release
`73ff954d` was staged, not active.
At 04:24 UTC its daemon entered low-quota fast polling. At 04:30 it selected
another account but could not confirm runtime convergence. Mac manual requests
at 06:52 and 06:54 were rejected because the authority could not accept a
different target while that transaction remained unconfirmed.

The VPS maintenance scanner also rejects the T3 Code stdio app-server launched
with `app-server -c mcp_servers.t3-code.url=... -c ...`. It incorrectly treats
that known transport shape as an unknown Unix listener. This diagnostic defect
is verified independently; existing logs do not establish that it alone caused
every incomplete reload.

Read-only checks at approximately 07:07 found the VPS confirmed again. The Mac
confirmed its runtime at 07:08. No repair action in this investigation caused
that recovery. A previous Mac source inspection also identified a same-account
credential-refresh dead end: external handoff requires matching store/auth
credentials before the normal credential transaction can reconcile them.

A further live read-only replay found that a CLI invoked from the native Mac
app-server reports no runtime because macOS `pgrep` excludes ancestors by
default. Exact-name enumeration with ancestor inclusion immediately finds that
same PID. The GUI's independent invocation can find it, explaining why a manual
CLI diagnostic and the GUI disagree. This also affects runtime-initiated
recovery commands; it does not establish the cause of every GUI handoff error.

A separate subprocess replay established the persistent GUI handoff defect:
assigning `Process.environment = nil` on this Mac empties the child's environment,
while leaving that property unset inherits it. The shared runner unconditionally
assigned its default nil argument, stripping `HOME` from the control CLI. An
independent invocation with inherited environment confirmed the same existing
activation without any credential or auth change. This explains the GUI's
repeated immediate handoff failures independently of ancestor enumeration.

## Repair Contract

Recognize only a bounded, reviewed stdio argv grammar in the Unix-daemon
ownership scanner. Keep unknown options, explicit listener changes, and malformed
configuration arguments fail-closed. This classification does not remove the
stdio process from general reload discovery or deployment quiescence checks.

Include ancestors in both Mac discovery entrypoints and add a subprocess
fixture that runs the real enumerator from a disposable Codex-named parent.
Discovery remains read-only and every candidate still requires kernel binding.

The shared subprocess runner must leave the environment unset when callers do
not supply one. An explicit dictionary, including an empty dictionary, remains
an exact replacement, not a merge with ambient credentials. Cover all three
cases with real subprocess tests, then rerun the complete Swift suites because
this runner is shared by multiple helper workflows. The separately cancellable
desktop-updater runner has the same assignment and must obey the same contract.

A confirmed Mac activation may route a complete, strictly newer, usable
same-account auth generation directly through the existing credential transaction
instead of waiting for a cross-process handoff receipt. Require one matching
provider, matching configured/runtime identity, and no different target. Preserve
lease, durable-store, auth-readback, runtime-ACK, and transaction revalidation.
Preparing, degraded, and unrelated manual-review barriers must not be bypassed.

Persist bounded per-PID reload blockers and acknowledgement/topology counts in
activation errors. A generic incomplete-reload message alone is insufficient
incident evidence. Do not include credentials or unbounded process output.

Mac helper refusals must also report a fixed, secret-safe failure category.
Exit status alone cannot distinguish a missing environment from a busy
activation lease or a failed runtime confirmation. Never log raw helper stderr.

## Verification

Add deterministic positive and negative fixtures for both routing decisions.
Run focused tests, then the affected Swift and native Linux suites. Preserve the
dirty primary checkout and all live sessions. Deployment requires current
provenance, client quiescence, and independent post-activation checks; a passing
repository test is not evidence of live deployment.

The repaired source passed all 1,100 Swift tests in 67 suites on this Mac.
The command-line toolchain requires the installed macOS 26.5 SDK and explicit
Testing framework/library search paths. The default macOS 27 SDK is missing a
SwiftUI macro host; that initial build failure was environmental.

The focused Unix-scanner regression passed locally. A first full Rust run used
macOS's symlinked temporary-directory alias and failed lease path-identity
checks; the canonical-directory replay passed 666 tests with one ignored
subprocess helper. The added ancestor-discovery change passed 25 focused Rust
tests including its real macOS subprocess fixture. Read-only invocation of the
rebuilt CLI then discovered the live native app-server that the installed CLI
missed. It still reported a stale CLI journal and an old ACK, not readiness.

Both the clean branch (1,100 tests) and the build preserving the installed Mac
customizations (1,140 tests) passed their complete Swift suites after the
ancestor-discovery change. The preserved baseline source fingerprint is
`bb480eb37db4`, exactly matching the installed app before these repairs.
At that point, native Linux CI and deployment were not yet verified.

The new default-environment regression failed against the original runner, then
passed after the conditional assignment. All six environment fixtures cover
both runners. The final local suites passed 1,107 tests in 67 suites for the
clean branch and 1,147 in 68 suites for the customization-preserving build.
The latest complete Rust replay passed 667 unit tests (two subprocess helpers
ignored by default) and all three CLI integration tests. The local Swift toolchain
also requires its explicit `plugins/testing` macro search path when rebuilding
tests; runtime framework paths alone do not supply compiler macros.

At 08:09 UTC the installed Mac app, source fingerprint
`9d72354ea759-dirty.e3304f0e9f56`, recorded two
`CLI_ACTIVATION_HANDOFF_CONFIRMED` generations and a same-account runtime reload
completed in 1,585 ms. The existing ChatGPT PID 11872 and native Codex PID 12102
were preserved. Bundle signing verification passed. Earlier post-install
deferrals are not evidence of confirmation; only the later positive records are.

The environment correction was a separate follow-up to the runtime repair so
its long-running native Linux validation could continue unchanged. At 08:09 UTC
the VPS still ran `7f60ba3c`, and the Mac control CLI still ran `5229bc38`;
repository fixes and the installed menu-bar app did not establish those runtime
deployments. Later deployment evidence follows.

## Release Staging

Both full native Linux and Swift contract runs for `ce514f397c56` passed before
PR #4 merged as `26270ee38d1024932d4b8045370e9593cd8fe094`. The merge tree is
identical to the tested PR tree. Linux artifact run `36305852058` succeeded
against that exact main commit and upstream Codex `0.153.2`, commit
`657a993cbee87acf52d14b758ce49dbd46d1b8eb`. It reused only the independently
verified unchanged upstream runtime from run `36144987554`; the control CLI
was rebuilt from the new source.

At approximately 08:32 UTC the four-member Linux artifact passed the native
staging verifier and all four GitHub attestation checks. Stage-only installation
published release
`/home/signul/.local/share/codexswitch/releases/0.1.0-26270ee38d1024932d4b8045370e9593cd8fe094`.
The published CLI SHA-256 is
`048d4d47a4f82b042d841b3bb6e865ce2d572c12c7cebb36054b9d844af1514d`;
the artifact manifest SHA-256 is
`69fd3d3579c9547d56b719d305aa3b46382ffd1838c0d79461c9802124d5a8d6`.

This one staging invocation retained six releases with a 10 GiB release
retention bound to preserve all five pre-existing releases. No existing release
was removed. The active and previous links, public CLI target, and digest of
all user systemd unit files matched their pre-staging snapshots. Runtime PIDs
79174 and 2036657, daemon PID 1101286, and the T3 parent PID 769277 retained
their process identities. Every activation, enablement, and start flag was zero.
The VPS still runs `7f60ba3c`: connected desktop and T3 clients must quiesce
before activation or legacy credential-sync retirement can proceed.

The exact-main macOS runtime artifact build is run `36305853246`. Its older
downloadable base artifact had expired, so this was a full native build, not an
unattested replacement of the installed control CLI. That run completed
successfully before the Mac activation below.

Both full native Linux and Swift runs for the environment follow-up
`370599d47d6f` also passed. PR #5 merged at 09:10 UTC as
`d6601b275c1a9a13c016be38ca44091146007a3e`, with a tree identical to its tested
head. Its changes are confined to Swift implementation, Swift tests, and docs.
The Rust crates, Cargo inputs, runtime workflows, and runtime installer scripts
are identical to `26270ee38d10`, so the two runtime artifacts include all current
control-plane fixes.

## Mac Activation

The Mac runtime installer completed successfully at approximately 09:17 UTC
from a clean local main checkout pinned to the artifact's exact source commit.
It verified all four GitHub build attestations, native signatures, architecture,
manifest members, runtime contracts, and the installed route readback.
The artifact manifest SHA-256 is
`93455c0c40498516bd9cd8968f3f5911657cc7e17e53bab7f1cd0f568fb37194`;
the installed control CLI SHA-256 is
`47024f9e12620cb92f89b5cc73282b3f961d5118db348c36f94df4a1ae5a2dbe`.
The installed CLI reports git `26270ee38d1024932d4b8045370e9593cd8fe094`.
The updater reports `installed`, upstream version `0.153.2`, that exact manifest
digest, no pending transaction, and no error. In-memory before/after comparison
confirmed unchanged credential inventory and unchanged auth-file content.

Before activation, all four existing prepared runtime generations, the control
CLI, three launch routes, and updater metadata were copied to
`~/.local/share/codexswitch/backups/swap-repair-20260927`. Runtime copies passed
a recursive byte comparison; each saved launch route and CLI matched its source
digest. No account tokens were included. Normal installer retention removed one
expired managed `0.149.0` generation, whose matching backup remains available.
The new generation is
`prepared-codex/0.153.2/2c4fca26a50047529e77799ea55bb278`.

Only the menu-bar app was then gracefully relaunched with its watchdog held and
restored. At 09:19:04 UTC its normal pool-authority path started a same-account
reload and completed in 1,461 ms. It recorded
`CLI_ACTIVATION_HANDOFF_CONFIRMED` for generation
`D1BD2501-5261-4D21-8626-C0BFBAD673EE`. An independent invocation of the installed
CLI from inside the existing native Codex process reported `ready: true`,
`activationState: confirmed`, a clear activation barrier, one fresh runtime ACK,
11 accounts, three ready candidates, and no issues. Computer Use lineage also
reported ready. The app signature remained valid.

ChatGPT PID 11872 and native Codex PID 12102 retained their original start times
and executable identities throughout. CodexSwitch is now PID 229, with watchdog
PID 249. The existing native runtime still executes its protected earlier
`e9344a147ea24306a8df8ec38ddcee39` generation; no current chat was restarted to
enter the new prepared runtime. The repaired control CLI is already installed
at its normal path and discovered that ancestor process correctly.

## Remaining VPS Gate

The 09:19 UTC recheck still found VPS release `7f60ba3c` active, with unchanged
runtime and daemon identities. Release `26270ee38d10` is staged only. The user
has not yet confirmed that desktop VPS and T3 activity are idle and disconnected.
Do not treat the Mac's positive reload result as VPS activation evidence.

After explicit client quiescence, use the documented positive process/lease
observations, bounded graceful stop, attested activation, and post-activation
checks. Preserve the existing service boot policy and independent SIGNUL jobs.
The original unresolved legacy credential-sync journal must remain intact until
the new VPS release is active and the guarded review/apply workflow obtains its
required local and remote leases and stable repeated observations. Then verify
normal full-pool synchronization and its durable receipt. Neither the legacy
journal retirement nor VPS activation occurred during this repair.
