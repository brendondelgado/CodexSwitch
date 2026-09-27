---
title: September 27 swap convergence incident
description: Verified failure evidence and bounded Mac and VPS repair contract.
toc:
  - Swap Convergence Incident
  - Evidence
  - Repair Contract
  - Verification
cross_dependencies:
  - ../architecture/runtime-and-host-ownership.md
  - ../../Sources/CodexSwitch/Services/ExternalAuthConflictRecoveryPolicy.swift
  - ../../Sources/CodexSwitch/App/AppDelegate.swift
  - ../../Sources/CodexSwitch/Services/ProcessRunner.swift
  - ../../crates/codexswitch-cli/src/codex_update/runtime_discovery.rs
version_control:
  branch: codex/helper-environment-20260927
  status: implementation
  last_updated: 2026-09-27
---

# Swap Convergence Incident

## Evidence

The VPS still runs release `7f60ba3c`; release `73ff954d` is staged, not active.
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
Native Linux CI and deployment are not yet verified.

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

The environment correction is a separate follow-up to the runtime repair so
its long-running native Linux validation can continue unchanged. The VPS still
runs `7f60ba3c`, and the Mac control CLI still runs `5229bc38`; repository fixes
and the installed menu-bar app do not establish those runtime deployments.
