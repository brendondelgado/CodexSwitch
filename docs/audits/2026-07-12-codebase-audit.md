---
title: CodexSwitch codebase audit
description: Deep Mac and VPS audit findings, remediation status, and remaining verification work.
toc:
  - CodexSwitch Codebase Audit
  - Executive Assessment
  - Severity Model
  - Critical Findings
  - High Findings
  - Structural Debt
  - Remediation Status
  - Deletion Ledger
  - Deletion Candidates
  - Verification And Deployment
cross_dependencies:
  - ../plans/2026-07-12-codexswitch-clean-code-recovery.md
  - ../architecture/system-overview.md
  - ../architecture/quota-and-reset-policy.md
  - ../architecture/runtime-and-host-ownership.md
  - ../runbooks/linux-repository-deployment.md
version_control:
  branch: main
  base_commit: 664edf6
  status: active-audit
  last_updated: 2026-07-21
---

# CodexSwitch Codebase Audit

## Executive Assessment

The reliability failures were not caused by one broken threshold. CodexSwitch accumulated multiple writers, duplicated policies, implicit repair behavior, unbounded maintenance artifacts, and weak boundaries between Mac, VPS, desktop, CLI, and optional integrations.

The repository has strong individual mechanisms, but orchestration grew faster than its contracts. The cleanup therefore prioritizes state ownership and transaction boundaries before cosmetic refactoring.

Current audit completion is approximately 96 percent. Repository remediation
and deterministic local verification are complete; full native CI and live
activation remain. No live VPS release has been activated from this audit.

## Severity Model

- Critical: can spend scarce reset inventory twice, corrupt active state, terminate live work, exhaust the host, or activate unverified code.
- High: can prevent hot-swap, misreport capacity, create repeated incidents, or make recovery nondeterministic.
- Medium: creates unnecessary coupling, dead paths, confusing ownership, or avoidable maintenance cost.
- Low: naming, documentation, and local simplification that improves future correctness.

## Critical Findings

| Finding | Impact | Repository disposition |
| --- | --- | --- |
| Reset redemption lacked durable uncertainty handling | Timeout or crash could lead to a second reset POST | Journal and reconciliation guard implemented; integration verification pending |
| External reset inventory decrements created only an in-memory propagation hold | Restarting the Mac app during stale provider quota propagation could spend another reset credit | Provider-account-keyed token-free hold persistence, launch/check restoration and pruning, and evidence-gated early clearing implemented; dedicated deterministic tests added, native execution pending |
| Swift and Rust could race whole-file account writes | Lost updates or multiple active accounts | Shared lock and validation behavior implemented; cross-language fixtures pending |
| VPS updater scanned a 1.53 GB binary with a whole-file read | Multi-gigabyte memory spike, OOM, remote disconnect | Streaming bounded marker scan implemented; constrained Rust test pending |
| Maintenance artifacts were unbounded | VPS disk reached high utilization; a non-core integration produced massive backups | Non-core integration removed from the repository; live effect ends when the verified release is activated |
| Process signalling could rely on mutable PID identity | Wrong process could receive reload or termination | Detached desktop `pkill -f` removed; stop targets now revalidate owner, executable, PID, and start time |
| Desktop patch/update paths were not one staged transaction | Broken signature, partial app, repeated repair loop | Cross-process patch lease and staged ownership hardened; full installed-app test intentionally deferred |
| Configured account and runtime-current account were represented as one state | A failed reload could leave ChatGPT consuming one account while the menu app claimed another account was active; a separately active VPS could then consume the configured account at the same time | Journaled activation and fresh runtime acknowledgement are being made mandatory before the UI or reset policy may call an account current |
| Runtime confirmation had no live lease and survived runtime exit | A stale `Confirmed` phase could authorize automatic swaps or a banked-reset POST after the runtime that earned it had disappeared | Confirmation is being bound to fresh typed runtime evidence and revalidated immediately before every automatic mutation |
| Reset redemption and account activation had separate asynchronous ownership | A reset task could pass its initial checks, suspend, then POST while a swap changed the configured target | One generation-bound account-mutation lease is being shared by activation and reset redemption, with immediate pre-effect revalidation |
| The Linux Codex updater activated a prepared binary while the managed app-server was live | The updater stopped the systemd unit, hit its stop timeout, SIGKILLed the entire live cgroup, then attempted a second daemon restart | Preparation and activation are being separated; automatic update may stage but must not replace or restart a live managed runtime |
| Same-version updater reconciliation could erase a failed activation | A replaced binary was later reported as installed even though runtime restart failed, hiding the interrupted session and leaving provenance ambiguous | Installation state is being split from activation state; same-version observation cannot promote a failed activation |
| Token-bearing Mac-to-VPS bundles use a single SHA-256 passphrase derivation | Offline guessing of a captured credential bundle is needlessly cheap despite AES-GCM encryption | Introduce a versioned, high-iteration PBKDF2-HMAC-SHA256 format in Swift and Rust while retaining read-only compatibility for existing short-lived bundles |
| VPS readiness accepted app-server start time without a process-bound reload acknowledgement | The menu app reported a current systemd app-server as hot-swap ready while its ACK was absent and the daemon was blocked by `ManualReview` | Remove start-time readiness fallback; only an explicit activation or rotation may create the first current ACK, and observers remain not ready until then |
| A disconnected initialized remote-control frontend could prevent acknowledgement indefinitely | A version probe or closed client left historical connection state, backend auth reloaded, frontend delivery proved zero writes, and activation degraded into a durable barrier | Count only successfully enqueued live writers as eligible, require all eligible writes, and permit strict headless idle proof only when no live writer accepts delivery |
| Historical ACKs could be reread and assigned a fresh runtime-evidence lease | A process that acknowledged old auth could authorize a later swap after its identity or auth changed | Retain original ACK time and process binding, use one five-minute freshness contract, and revalidate topology immediately before confirmation |
| An in-flight external-auth observation was not bound to swap generation | A delayed read could reverse a newer completed local swap | Capture configured account, swap generation, and activation generation before suspension; discard stale results |
| In-turn retry trusted a shape-valid child report instead of the turn's exact ACK | A stale control CLI could claim success while the interrupted turn still held old auth, surfacing the original usage-limit error | Pass a turn-generated receipt nonce through rotation, verify the resulting bound ACK, reload the turn-local `AuthManager`, and retry only after fingerprint agreement |

## High Findings

| Finding | Impact | Repository disposition |
| --- | --- | --- |
| Five-hour and weekly windows were mandatory fields | Weekly-only paid accounts appeared empty, exhausted, or incorrect | Optional-window model and fixtures implemented; Swift/Rust/UI migration in progress |
| Remote VPS observation could affect Mac active state | Wrong local account or suppressed Mac auto-swap | Host boundaries corrected in repository; regression tests in progress |
| `codex-vps --check` performed hidden repair/start work | Diagnosis could mutate a live incident | Status made observational; explicit start/restart/sync commands added |
| `codex-vps --check` selected and displayed different remote version observations | A transport change selected a `0.144.4` client and later printed it as equal to a `0.144.6` app-server | Bind selection, transport validation, and output to one version snapshot; fail if the post-transport observation changes |
| Failed VPS checks retained the last green Mac presentation | A blocked daemon and missing current ACK looked ready until the user noticed rotation had stopped | Invalidate green state on any failed or expired observation and display retained payload only as stale diagnostics |
| Read-only CLI status paths created locks and reconciled updater state | Diagnostics could fail in restricted environments and mutate the incident they were inspecting | Add stable no-follow observation reads and an in-memory updater report that never creates locks or saves state |
| Thread healing rewrote state opportunistically | Remote thread drift and unsafe concurrent repair | Automatic healing retired; explicit repair runbook added |
| SecureDrop archive/path validation was incomplete | Traversal, symlink, TOCTOU, or wrong-file deletion | Structured validation and rehash-before-delete added |
| Updater ownership was split | Repeated downloads, storage refill, conflicting installs | Temporary workspace ownership and cleanup added; one-owner contract documented |
| The Mac automatic CLI updater compiled a full Codex checkout in the background | A 30-minute build timeout left hundreds of megabytes of source and build output behind, then a failed cleanup allowed later checks to refill storage and pressure RAM without an operator requesting an install | Automatic Mac ticks are now metadata-only checks; only the explicit Update command may prepare, compile, install, repair launchers, or delete updater artifacts |
| Computer Use permission repair mutates TCC automatically | CodexSwitch edited the user TCC database and restarted `tccd` at launch and on a timer, outside account-switching ownership | Mutation code and its SQL tests removed; macOS remains the authority for privacy grants |
| Reload acknowledgements accumulated without retention | More than 13,000 files and continued growth | Bounded pruning added; repository tests pass, live verification pending |
| Updater stale recovery duplicated one six-hour timeout | Checking/installing could remain stuck far longer than their intended deadlines | Decision state now uses the single operation-specific freshness policy |
| Reset-bank fetch timestamps masqueraded as inventory changes | Every poll churned account persistence and UI work and could trigger VPS credential sync for telemetry-only state | Semantic inventory gating, telemetry-only context routing, five-minute background freshness, and at-most-sixty-second decision evidence for any fresh blocked quota implemented; dedicated deterministic tests added, native execution pending |
| Inactive exhausted Pro accounts polled every five seconds | A pool of exhausted Pro accounts generated continuous provider traffic, log bursts, and coalesced account-store writes even though manual-reset detection only promises one-minute freshness | Exhausted Pro polling now uses the one-minute manual-reset cadence, waking earlier only for a nearer natural reset; weekly-only regression coverage added |
| Active quota telemetry flushed on the same five-second cadence as active polling | Healthy operation could rewrite the complete account store continuously even when no user-visible quota value changed, increasing disk churn and widening cross-process write contention | Preserve immediate in-memory updates and immediate durability for user mutations, but coalesce telemetry behind a bounded write interval with an explicit shutdown flush; deterministic coordinator coverage required |
| Equal-tier reset candidates ignored cross-account credit expiration | Swift and Rust selected the oldest credit within one account but used stable account identity before expiration when choosing between Pro accounts, allowing a sooner-expiring reset to be wasted | Swift and Rust now rank eligible reset candidates by plan tier, earliest explicit future expiration, then stable identity; dedicated language and standalone replay coverage added |
| Reset-policy test helpers used quota reset dates from 2001 | Hardened stale-evidence checks correctly refused redemption, but five legacy fixtures still asserted that a reset should be spent | Test quota windows now use future reset evidence, manual-reset fixtures carry a concrete provider credit ID, and the obsolete pool-reset wrapper is removed |
| Systemd policy was fragmented across stale drop-ins | Deployed behavior could differ from repository | Repository-owned allowlist and immutable release work in progress |
| Knowledge sync could compare the same path every 15 seconds | Extreme logical read volume with no useful transfer | Same-path rejection added; deployed unit retirement pending activation gate |
| Generated Mac launchers scanned the complete Codex binary twice on every invocation | Each `codex` command performed roughly 758 MB of avoidable reads before the CLI started, adding latency and storage pressure | Both entrypoints now share one bounded router; capability validation remains at install/repair time, and deterministic focused execution tests are pending |
| The desktop patcher read the complete Codex binary once per capability helper | Repeated 379 MB allocations and reads amplified RAM and I/O pressure during patching | One bounded streaming scan now serves both capability checks through a device/inode/size/timestamp cache; all 92 patcher tests pass |
| The shared Swift subprocess runner used unbounded output buffers and an unbounded final drain | A slow or noisy helper could deadlock a pipe, retain arbitrary memory, or freeze launch when invoked from the main actor | Concurrent bounded capture and deterministic timeout/reap behavior pass an isolated saturation harness; package tests and remaining main-actor call-site migration are pending |
| SecureDrop loaded every transferred file into memory and rewrote its complete audit log for each event | Large transfers could spike Mac or VPS memory, while concurrent writers could lose audit entries and growing logs made every transfer progressively more expensive | Replace file hashing with bounded streaming and audit persistence with locked append-only writes plus bounded rotation; focused cross-process tests pending |
| `SwapLog.recentEntries` read the complete current daily log despite having no caller | A future accidental call could allocate tens of megabytes on the app process, while the dead API obscured the actual append-only logging contract | Remove the unused whole-file reader; diagnostic inspection remains an explicit operator action outside the app |
| Reset reconciliation used production `expect` assertions after local guards | A future refactor could turn stale or malformed provider evidence into a daemon crash instead of a conservative suppression result | Replace panic-based invariant recovery with explicit optional-evidence matching while preserving fail-closed reconciliation |
| Reset provider callbacks ran while orchestration owned broad store or journal locks | Slow quota, inventory, or consume requests could block status, activation, or recovery, while an interrupted callback left ambiguous lock ownership | Provider callbacks now run outside both locks; exact store generation and reset-attempt identity are revalidated before every transition, and concurrent mutation fails closed without a second consume |
| Manual redemption could trigger a later routine plan upgrade | The confirmation promised no account switch, but a timer-based hold eventually made the recovered account a proactive promotion target | Persist manual intent and suppress routine promotion until a genuine failover or explicit operator selection successfully activates the account; release that suppression durably |
| Unreadable reset journal startup failed open | The swap monitor could run with empty unresolved-attempt and manual-suppression state | Gate automatic routing and manual redemption on readable journal state and retry bounded reads without blocking app launch |
| Selected-credit natural expiry looked like successful local redemption | An expiring selected credit could disappear with a count decrement and finalize an attempt that the provider never consumed | Swift and Rust persist the selected expiration; Rust also journals the complete normalized starting credit-ID set. Absence proves consumption only while the selected credit remains future and the exact one-credit transition preserves every other starting credit |
| Request-start time was stored as reset inventory observation time | A credit expiring during a slow inventory GET could still satisfy pre-expiry reconciliation | Timestamp inventory at response completion and validate the full bank against that time |
| Unreleased manual route suppressions were ordinary terminal history | Age or count pruning could silently re-enable routine promotion without an activation | Protect only the newest unreleased successful suppression per provider until activation durably releases it |
| Natural credit expiry looked like external redemption | An ordinary expiration could create a hold and hide later urgent credits | Swift and Rust classify prior inventory at its observation time, subtract credits that naturally expired by the new observation, and reserve external holds for unexplained decrements |
| Timestamp-fresh malformed reset inventory stayed current | Expired or count-mismatched cached credits could remain visible for five minutes while redemption was disabled without a refresh | Cached freshness now requires the complete structurally valid available-credit set at the current time; invalid caches refresh immediately and present as stale until replaced |
| Provider observation commits advanced the account store without advancing `Confirmed` activation evidence | Readiness correctly rejected the now-stale confirmation, making healthy polling disable hot-swap until another convergence | Exact generation continuity now advances with every observational commit or leaves a durable fail-closed barrier; focused tests added, independent review clean, canonical CI pending |
| A rotate-now continuity store commit could precede its journal update | Journal failure or process interruption could leave a stale `Confirmed` record that reconciliation treated as complete | `Confirmed` is validated on every reconciliation and continuity uses a recoverable two-phase journal transition before store commit; focused tests added, independent review clean, canonical CI pending |
| Linux `poll` retained the global account-store lock across provider requests | A slow multi-account poll could block rotation, reset reconciliation, and daemon commits for cumulative network time | Poll now snapshots under lock, performs provider I/O unlocked, and requires exact store and activation-journal identities before commit; focused tests added, independent review clean, canonical CI pending |
| Operator `poll` and `redeem-reset` could bypass or race an unresolved activation barrier | Observation could corrupt a prepared/manual-review generation, while targeted redemption could POST after a journal-only transition that preserved the store generation | Provider work now binds exact store and activation-journal identities, revalidates each effect, preserves Confirmed continuity at commit, and holds a dedicated provider-I/O lease across the unlocked irreversible POST; focused tests added, independent review clean, canonical CI pending |
| Runtime marker inspection reopened a mutable executable path | A FIFO replacement could block indefinitely and a same-path binary update could validate a different image than the running process | Marker inspection now uses a no-follow regular descriptor bound to kernel process identity and rejects path replacement. The Linux identity regression executes a copied self-test fixture rather than an ambient utility, so its initial inode and later path replacement are deterministic; canonical CI pending |
| Activation paths accepted whitespace-only token material | Manual activation or import could publish malformed auth while other paths considered the account incomplete | One trimmed complete-token predicate now governs rotation, import, auth evidence, and readiness; focused tests added, independent review clean, canonical CI pending |
| Current-version `Confirmed` records accepted an unknown activation kind | Malformed or legacy-shaped evidence could authorize generation continuity without explicit provenance | Current confirmation now rejects unknown kind and keeps legacy evidence behind the migration barrier; focused tests added, independent review clean, canonical CI pending |

## Structural Debt

- Swift and Rust duplicate quota, scoring, readiness, and reset policy.
- `AppDelegate`, `LinuxDevboxMonitor`, Rust daemon/update code, and `codex-vps` have accumulated orchestration responsibilities.
- CLI entry points and daemon loops sometimes duplicate the same rotation sequence.
- Remote scripts cross typed boundaries with embedded shell or Python state manipulation.
- Historical desktop patching paths remain larger than the current supported contract requires.
- Optional third-party authentication was coupled into normal import, swap, rotation, daemon, and TUI paths.
- Several older docs describe implementation history as if it were current architecture.

## Remediation Status

Implemented or substantially implemented in the repository:

- Canonical optional quota-window model and weekly-only fixtures.
- Durable reset-attempt journal and duplicate-spend suppression.
- Persistent external-reset propagation holds keyed by provider account identity without token storage.
- Semantic reset-bank persistence/UI gating, bounded background freshness, and decision-fresh any-account escalation.
- Locked, validated account-store writes.
- Host-local Mac/VPS authority separation.
- Read-only remote status behavior.
- Explicit thread repair and validated thread identifiers.
- SecureDrop archive and deletion hardening.
- Desktop patch lease and updater workspace retention.
- Streaming binary marker inspection.
- Bounded runtime acknowledgement cleanup.
- Removal of automatic TCC database mutation and `tccd` termination from the normal app lifecycle.
- Removal of Hermes source, commands, tests, and automatic call sites from CodexSwitch; the separate product and its data remain untouched.
- Removal of obsolete Rust marker/ack APIs and the former interactive Linux TUI; supported operations remain explicit headless subcommands.
- Removal of the unused Rust `orchestrate_pool_reset` wrapper; production and tests use the observation-aware pool coordinator directly.
- Operation-specific updater recovery wired through one decision helper.
- Automatic Mac CLI update ticks reduced to metadata-only checks; builds, installs,
  launcher repair, retention, and artifact deletion require an explicit Update command.
- Automatic desktop patching now defers while a detached app-server may own live work; explicit repair uses individually verified PIDs and `SIGTERM`.
- Removal of the unused whole-file `SwapLog.recentEntries` helper; production logging remains bounded append-only output with startup retention.
- Removal of production panic assertions from reset reconciliation; missing evidence now remains an explicit fail-closed state.
- Removal of the hard-disabled stock CLI repair probe that still loaded the complete vendor binary during every desktop patch check; supported bundled-CLI capability checks remain unchanged.

Still in integration or verification:

- Complete weekly-only migration across Swift UI/policy and Rust callers.
- Shared Swift/Rust policy fixture parity.
- Single activation coordinator per host.
- Full process identity revalidation at every signal call site.
- Immutable VPS release and systemd ownership deployment.
- Final constrained test suite and clean diff review.

## Deletion Ledger

The audit removes 11 tracked files totaling 2,712 lines. These are deliberate
ownership reductions, not blanket cleanup:

| Removed files | Why removed | Current owner or replacement |
| --- | --- | --- |
| `CodexDesktopAppPatcher.swift`, `CodexInstallLocator.swift`, `CodexPatchState.swift` | Dormant desktop-patch stack duplicated app discovery, patch state, and live-process mutation. Keeping both stacks allowed competing patch owners. | `CodexDesktopAppLocator`, `DesktopPatchManager`, `CodexDesktopAppUpdater`, and the tested `scripts/patch-asar.py` transaction. |
| `ComputerUsePermissionRepair.swift` and its test | Directly mutated the user TCC database and restarted `tccd`, which is unsafe and outside account-switch ownership. | macOS privacy controls. CodexSwitch may report plugin/signature diagnostics but does not claim authoritative privacy-grant state. |
| `HermesTarget.swift`, `hermes.rs`, and their tests | Cross-product integration wrote Codex tokens/configuration into `~/.hermes` and could restart Hermes during CodexSwitch operations. Hermes must remain independent. | No replacement inside CodexSwitch. Hermes itself, its data, and its processes are untouched. |
| `tui.rs` | The interactive Rust wrapper was coupled to Hermes and duplicated explicit operational commands. | Headless `status`, `doctor`, and `daemon` commands. |
| `OnboardingView.swift` | No production call site instantiated it; empty-account setup already exists in the live popover. | `PopoverContentView` account setup flow. |
| `SingleFlightGate.swift` | Had no production caller; only its own test referenced it. | Operation-specific coordinators and transaction locks. |

Reference checks must remain green before merge: no deleted production symbol,
Hermes mutation command, or `codexswitch-cli tui` call site may remain.

## Deletion Candidates

Delete or extract code only after call-site proof and tests:

- Dormant ASAR patch branches and obsolete compatibility markers.
- Duplicate CLI/daemon rotation orchestration.
- Obsolete thread-healing implementation.
- Stale systemd fragments not owned by the repository manifest.
- Historical updater ownership paths superseded by the staged transaction.
- Duplicate quota DTOs and five-hour-specific helpers after optional-window migration.

## Verification And Deployment

Repository completion requires:

1. Python and shell tests for scripts and transport. Current results: 127
   patcher tests, 24 `codex-vps` Python tests, the shell transport replay, six
   Linux artifact tests, six Linux build-workflow tests, five Mac build-script
   tests, and 73 Linux resource-policy tests pass.
2. Swift syntax checks and the standalone banked-reset replay pass. The full
   native Swift package suite is assigned to the permanent macOS CI gate.
3. Rust formatting passes without creating a local `target/`. The full locked
   Rust contract suite and generated-turn execution are assigned to the
   permanent single-job Linux CI gate so this Mac does not perform the build.
4. Cross-language fixtures for quota and selection parity.
5. Diff review for secrets, dead branches, frontmatter, and accidental generated files.
6. A read-only live health/provenance check.

VPS activation is a separate stage. It requires an immutable artifact, matching Git provenance, idle/readiness approval, resource baselines, verified hot-swap, and an immediate rollback pointer. Repository tests alone do not prove the live VPS is updated.
