---
title: Runtime and host ownership
description: Canonical Mac, VPS, activation, reload, remote-session, update, and storage contract.
toc:
  - Runtime And Host Ownership
  - Purpose
  - One Owner Per Host
  - Account Store Protocol
  - Activation Transaction
  - Runtime Reload
  - Hot-Swap Reliability Closure
  - Rust CLI Activation And Handoff
  - Mac Contract
  - VPS Contract
  - Remote Session Contract
  - Status And Repair
  - Update And Patch Contract
  - Storage Contract
  - Operational Proof
cross_dependencies:
  - ../../Sources/CodexSwitch/Models/AccountActivationState.swift
  - ../../Sources/CodexSwitch/Models/AccountManager.swift
  - ../../Sources/CodexSwitch/Services/AccountImporter.swift
  - ../../Sources/CodexSwitch/Services/AccountActivationCoordinator.swift
  - ../../Sources/CodexSwitch/Services/AccountActivationConvergence.swift
  - ../../Sources/CodexSwitch/Services/AccountActivationCredentialCommitter.swift
  - ../../Sources/CodexSwitch/Services/AccountActivationRuntimeEvidence.swift
  - ../../Sources/CodexSwitch/Services/AccountActivationRecoveryCoordinator.swift
  - ../../Sources/CodexSwitch/Services/AccountActivationTransaction.swift
  - ../../Sources/CodexSwitch/Services/AccountMutationLeaseCoordinator.swift
  - ../../Sources/CodexSwitch/Services/AccountPersistenceCoordinator.swift
  - ../../Sources/CodexSwitch/Services/KeychainStore.swift
  - ../../Sources/CodexSwitch/Services/SecureAtomicFileTransaction.swift
  - ../../Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - ../../Sources/CodexSwitch/Services/CodexVersionChecker.swift
  - ../../Sources/CodexSwitch/Services/CodexManagedRuntimeTrust.swift
  - ../../Sources/CodexSwitch/Services/CodexDesktopBridgeKeepAlive.swift
  - ../../Sources/CodexSwitch/Services/DesktopRuntimeReloadClient.swift
  - ../../Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - ../../Sources/CodexSwitch/Services/CodexDesktopAppLocator.swift
  - ../../Sources/CodexSwitch/Views/AccountCardView.swift
  - ../../Sources/CodexSwitch/Views/PopoverContentView.swift
  - ../../Sources/CodexSwitch/Views/StatusBarController.swift
  - ../../crates/codexswitch-cli/src/account_store.rs
  - ../../crates/codexswitch-cli/src/activation.rs
  - ../../crates/codexswitch-cli/src/import.rs
  - ../../crates/codexswitch-cli/src/reload.rs
  - ../../crates/codexswitch-cli/src/codex_update.rs
  - ../../scripts/codex-vps
  - ../../scripts/patch-asar.py
  - ../../scripts/test_patch_asar.py
  - macos-runtime-artifact.md
  - ../runbooks/codexswitch-hot-swap-verification.md
  - ../runbooks/linux-repository-deployment.md
version_control:
  branch: main
  status: canonical-target
  last_updated: 2026-07-23
---

# Runtime And Host Ownership

## Purpose

This contract prevents the Mac menu app, Mac CLI, VPS daemon, remote monitor, and helper scripts from racing to control the same session or account state.

## One Owner Per Host

The Mac and VPS are separate activation domains:

- The Mac coordinator owns Mac account state, `~/.codex/auth.json`, and local reload targets.
- The VPS coordinator owns VPS account state, VPS `~/.codex/auth.json`, and VPS reload targets.
- The Mac remote monitor reads VPS observations and displays them.
- `codex-vps` transports explicit operator actions to the VPS.

A connected remote session does not suppress Mac CLI protection, change the Mac active account, or cause a VPS observation to be written into Mac auth state.

Automatic Mac-to-VPS credential replication does not transfer activation
ownership. Before exporting, the Mac re-marks the replicated snapshot with the
freshly observed VPS active provider identity; if that identity is absent from
the Mac pool, sync fails closed. The VPS imports automatic bundles with
`update-bundle --preserve-active`, which independently retains its current
active provider identity. Bundle metadata may describe an active account for a
manual import, but it is never authoritative during background replication.

## Account Store Protocol

Every writer follows one protocol:

1. Open the dedicated lock without following symlinks.
2. Acquire an exclusive cross-process lock.
3. Read and decode the latest generation under the lock.
4. Validate unique stable identities and exactly one active account when non-empty.
5. Apply one mutation.
6. Write a same-directory temporary file with mode `0600`.
7. Flush, atomically replace, and verify the resulting generation.
8. Release the lock.

The containing private directory is mode `0700`. Whole-file writes outside this protocol are defects.

## Activation Transaction

Selection and activation are different phases. An activation succeeds only after the durable state and runtime agree.

The Mac invariant is simple: every active credential mutation is
configured-only until fresh runtime convergence is journaled. This includes an
account swap, active-token refresh, active-account reauthentication, first
account activation, and promotion of a target observed in an externally changed
`auth.json`. Persisting credentials is never itself runtime-current evidence.

```text
observe -> choose -> lock -> revalidate -> commit auth/store
       -> readback -> reload verified targets -> acknowledge -> publish
```

The auth commit includes access token, refresh token, identity token when present, provider account identity, and required metadata. Sending only a new access token can appear successful until the next refresh and is prohibited.

`auth.json` uses the same Swift secure-file transaction as the account store: descriptor-anchored no-follow traversal, a same-directory exclusive lock, generation recheck, unique `O_EXCL` temporary file forced to mode `0600`, complete write, file and directory `fsync`, atomic rename, and exact-byte no-follow readback. Lock acquisition is nonblocking and bounded; contention returns a distinct timeout without reading, writing, deleting, or bypassing the protected file. The readback must decode to the complete intended token set before reload begins.

The secure transaction can prove generation ownership, but the Mac activation
barrier does not roll back after an active credential mutation has durably
changed either configured file. A partial commit enters `ManualReview`; a
complete file commit enters `CommittedDegraded`. This task does not introduce a
cross-file compare-and-swap rollback protocol.

If readback fails, do not signal. If reload fails after a valid commit, retain the
committed target state. Rolling the account files back after an uncertain reload
is unsafe because a runtime may already have accepted the new credentials.

The Mac coordinator persists a token-free activation journal at
`~/.codexswitch/account-activation.json` before changing account files. Its small
explicit state machine is `Preparing`, `CommittedDegraded`, `Confirmed`, and
`ManualReview`:

- `Preparing` names the intended configured account before the account-store and
  auth commits begin.
- `CommittedDegraded` proves the files selected the target but no complete live
  runtime acknowledgement has been observed. Zero discovered runtimes, zero
  acknowledgements, partial acknowledgements, and reload uncertainty all produce
  this state.
- `Confirmed` names both the configured account and the same runtime-current
  account, with acknowledgement counts from at least one verified live local
  runtime. The record binds the proof to an activation generation, an evidence
  generation, an observation time, and a short expiry. An expired record is not
  authorization.
- `ManualReview` is the fail-closed state for corrupt, oversized, inconsistent,
  or unreadable journal evidence.

The journal contains local account identifiers, phase, bounded counters, retry
timing, and bounded reason codes only. It never contains access, refresh, or
identity tokens, email addresses, or raw reload payloads. It uses the shared
descriptor-anchored atomic transaction, mode `0600`, exact-byte readback, a
bounded encoded size, and a private `0700` parent. Corrupt state is preserved for
inspection and blocks mutation rather than being replaced with a guessed state.

`Preparing`, `CommittedDegraded`, and `ManualReview` are activation barriers.
While a barrier exists, automatic account swaps, reset redemption, and plan
upgrade activation are blocked. A committed degraded barrier permits a reload
retry for its same configured target, with bounded backoff and a small fixed
automatic-attempt ceiling. Automatic entry through token refresh,
reauthentication, external-auth reconciliation, or ordinary convergence retry
preserves the same target's monotonically increasing attempt count; it cannot
reset the count by returning to `Preparing`. Exhausting the ceiling enters
`ManualReview` while retaining the final discovered and acknowledged runtime
counts. The UI must present that partial convergence explicitly; it must not
collapse verified progress into a generic zero-runtime or "no swaps" state.

External-auth observation treats a concurrent file replacement, an unavailable
read, and ordinary content changes inside an opened ancestor directory as
retryable observation failures, not proof that configured credentials are
invalid. Ancestor validation binds device, inode, owner, group, mode, and the
opened path; mutable directory size and timestamps are not identity evidence.
If a prior deterministic external-auth failure already produced `ManualReview`,
a later descriptor-anchored valid read may recover only when it identifies the
same configured account and the durable account store and complete auth token
set still match. Recovery enters a fresh same-target `CommittedDegraded`
generation and requires current runtime acknowledgements before `Confirmed`;
it never clears the barrier from observation alone.

An explicit operator request may escape a valid `CommittedDegraded` barrier by
selecting another account. It may also escape `ManualReview` only when that
state was produced by the bounded automatic-retry ceiling. The request starts a
fresh `Preparing` generation for the selected target and must still commit and
read back the complete account store and `auth.json` before runtime convergence
begins. Automatic requests remain blocked, same-target clicks remain
reconciliation retries, and corrupt, unreadable, ambiguous, or inconsistent
manual-review states remain hard barriers. This escape exists so a runtime that
cannot acknowledge one configured account cannot pin the operator to that
account indefinitely.

A `durable_configuration_changed` review is a narrower recoverable case. It may
start only an explicit or one-shot launch reconciliation for the same configured
account. Before the journal leaves `ManualReview`, CodexSwitch must re-read the
account store and `auth.json` and prove the stable provider identity and complete
access, refresh, and identity token set match exactly. A mismatch preserves the
hard barrier, and this reason never permits a cross-account escape. Successful
revalidation still requires fresh identity-bound acknowledgements from every
discovered local runtime before publishing `Confirmed`.

`Confirmed` durably completes the barrier only for the lifetime of its evidence.
Do not oscillate accounts automatically.

An explicit manual cross-account switch is authorized by the operator request
plus exact durable agreement between the current account store and `auth.json`;
it does not require fresh runtime-current proof for the account being left.
Requiring that proof would make recovery impossible precisely when a runtime is
stale or cannot acknowledge. The newly selected account is still
configured-only until strict target runtime convergence succeeds.

If authorization fails before the credential mutation runs, no configured file
has changed. The coordinator must restore the prior durable activation state
under the same mutation lease instead of replacing it with a manual-review
record for the uncommitted target. On restart, a historical
`activation_file_commit_failed` record may be recovered only when the account
store and `auth.json` agree exactly on one known account; recovery produces
`CommittedDegraded`, never `Confirmed`.

Every request decision first evaluates confirmation freshness at the request
time. Expiry revokes authorization, but expiry alone is not evidence that the
runtime changed and must not persist `CommittedDegraded`, schedule convergence,
signal a runtime, or reload the desktop. Background policy first performs a
read-only runtime-evidence refresh. Successful proof renews `Confirmed` under
the same activation generation. Missing, incomplete, or transiently unavailable
proof leaves the expired `Confirmed` record fail closed and retries only the
read-only observation. It does not create an automatic reload loop.

An explicit operator request may convert an expired confirmation into the
existing same-target reconciliation or narrowly authorized cross-target escape.
A committed credential mutation or recovered interrupted commit establishes a
real `CommittedDegraded` barrier. Desktop termination and topology changes
invalidate the old observation but do not mutate credentials, so they trigger
only passive revalidation. A generic observation or validation failure
preserves the same target's monotonically increasing `retryAttempt`, including
when the failure enters `ManualReview`.

Before publishing `Confirmed`, the coordinator immediately re-reads the durable
account store and `auth.json`, proves that both still contain the same selected
target and complete token set, then rechecks the activation generation and
pending target. It also takes a fresh fail-closed verified-local-runtime snapshot
and proves that at least one expected live local runtime still reports the target
with complete evidence. A changed or unreadable durable source, missing runtime,
incomplete discovery, stale snapshot, or generation change cannot be confirmed.

Immediately before every automatic swap, plan-upgrade activation, active-token
refresh effect, reset-redemption decision, and reset POST, the owner obtains a
new verified-local-runtime snapshot. One typed permit binds that evidence to the
exact local target, activation generation, and required journal phase. A permit
issued for `Confirmed` cannot authorize a `Preparing` effect, and a permit issued
for `CommittedDegraded` cannot authorize confirmation after a same-generation
demotion to `ManualReview`. The snapshot must be complete, unexpired, and show
at least one expected live local runtime on the configured target. Failure
returns without the automatic mutation and without signalling or changing the
journal solely because observation was unavailable. Desktop termination and CLI
disappearance are handled by the same passive fresh gate. A verified durable
identity contradiction enters review, while a committed credential change
enters the normal degraded convergence contract; a transient discovery miss does
neither.

Every automatic entry point uses this one fresh gate before it selects a target
or writes `Preparing`, including quota exhaustion, plan upgrade, invalid-token,
and usage-unavailable callbacks. Passing an older gate on a downstream helper
does not authorize target selection made from stale runtime ownership.

The Mac automatic-policy evaluator is a bounded, generation-owned single
flight. Each evaluation receives a unique revocable authority with a monotonic
30-second deadline; wall-clock changes cannot extend it. The authority is
carried through runtime renewal and confirmed-evidence persistence and is
checked immediately before every reload, journal transition, reset effect, and
swap entry. When the deadline expires, CodexSwitch revokes the authority,
cancels the task, and allows the next monitor tick to retry. A late task cannot
clear a newer evaluator or authorize target selection, reset redemption,
credential writes, or a swap. An already-admitted bounded network request may
finish, but no later stage may consume it after revocation. This watchdog is a
last-resort liveness boundary; every subprocess, file lock, WebSocket request,
and acknowledgement wait inside the evaluator retains its narrower deadline.
Timeouts are logged with the trigger and lease generation so a silent stuck
percentage cannot disable future swaps.

The external reset-hold store is owned by a dedicated actor. Main-actor policy
evaluation awaits that actor and then rechecks its revocable authority before
continuing, so bounded file-lock contention cannot freeze the menu-bar UI or
prevent the independent policy watchdog from expiring stale work.

Runtime renewal carries the revocable callback into the desktop JSON-RPC and
CLI signal transactions. Each login request, verification request, request-file
commit, strict reload, and signal rechecks it at the effect boundary; expiry
during an earlier wait suppresses the next effect instead of relying only on a
check after the whole reload returns.

Successful evaluator completion releases the single-flight slot but does not
prematurely revoke an already admitted decision. Its authority remains usable
only until the original monotonic deadline and only to enter the existing typed
account-mutation lease. The activation coordinator checks both authorities
inside its executor immediately before it persists `Preparing`; that durable
transition is the handoff point, after which the activation generation and
mutation lease own the bounded transaction. Cancellation revokes the policy
authority immediately. A queued task that reaches the handoff after cancellation
or deadline expiry therefore changes no account, auth, or activation file.
Authorization loss is a typed cancellation outcome, not a journal failure: it
must not persist or publish `ManualReview`. Any genuine automatic preparation
failure may enter `ManualReview` only while the same policy authority and typed
mutation lease are still current inside the coordinator's persistence lock.

Proof captured before an `await` cannot authorize a later mutation. After every
preparatory suspension point, and again immediately before the first credential
mutation, swap, active-token refresh, active reauthentication, and plan-upgrade
activation revalidate typed runtime evidence, mutation-lease ownership,
activation generation, and the durable configured target. Reset redemption
performs the same post-suspension checks plus fresh quota and the durable reset
journal immediately before the first POST byte can be submitted. A suspension
gate that expires evidence, changes generation, changes the configured target,
or loses the lease must leave credentials and reset inventory untouched.

Active reauthentication is identity preserving. It requires an exact match of
the stable provider account identifier; email equality is presentation metadata
and never permits replacement of the configured credentials by a different
provider account.

Every coordinator launch invalidates in-memory runtime permits. A persisted
`Confirmed` record remains historical durable evidence; startup performs
read-only local CLI and desktop discovery before any automatic effect and
refreshes the same generation when the proof succeeds. Startup does not turn an
unchanged account into `CommittedDegraded` or reload ChatGPT merely because the
coordinator restarted. Existing configured account and auth files with no
journal still bootstrap a durable degraded barrier before same-target
reconciliation. Missing journal state never means unblocked when a configured
account exists. Startup may identify that configured account only by an exact
observed-auth provider-identity match or by exactly one durable selected record.
A stale defaults key, array order, duplicate provider identity, multiple selected
records, or no selected record is ambiguous: clear in-memory configured intent,
publish no target, and remain fail closed for operator review.

An externally changed `auth.json` is an observation, not permission for an
unjournaled promotion. A known external target enters the same configured-only
commit and convergence path. An unknown target, a conflicting in-flight target,
or a persistence failure enters `ManualReview`. Observation has typed
`absent`, `valid`, `invalid`, and `unreadable` outcomes. Absence is normal only
when no configured auth is expected. A corrupt, symlinked, wrong-mode,
unreadable, or configured-inconsistent auth file enters `ManualReview` without
mutating credentials. VPS observations never satisfy or replace Mac runtime
evidence.

Activation and reset redemption share one typed account-mutation lease. A lease
has a monotonically increasing generation and exactly one owner. The owner holds
it through one lexical transaction scope across every suspension point. An
observer may invalidate the scope and request cancellation, but cannot release
or transfer its lease. Cancellation does not hand ownership to another mutation
until the owning scope has unwound, and release accepts only the matching owner
generation. In the Mac app, the lease coordinator owns exclusion on its actor,
while the lease-scoped activation or reset callback remains explicitly isolated
to `MainActor` for observable account and application state. Durable file and
network work still crosses into its dedicated actor or executor and returns only
verified `Sendable` results to that callback. Generic asynchronous credential
mutation boundaries require their result type to be `Sendable`; this makes every
executor crossing explicit and keeps the contract valid across supported Swift
6 toolchains. Immediately before each account-store,
auth-file, activation-journal,
or runtime effect, the owner revalidates the lease, exact target, activation
generation, and required phase. The same checks run after every preceding
suspension. Effect-owning account-store, auth-file, and journal services perform
that validation inside their own executor immediately before the write, so an
actor hop cannot separate authorization from persistence. Immediately before a
reset POST, the owner additionally revalidates
fresh verified local runtime evidence, the durable configured target, fresh
quota, and the reset-attempt journal. The reset journal is updated before final
authorization; transport receives a typed one-shot submission permit immediately
after authorization, with no intervening `await`. Activation or reset work that
loses any proof returns without mutation; a second owner can never overlap it.

Shutdown marks policy as exiting before cancellation. New and already queued
policy work checks that state before acquiring a lease or mutating credentials.
Cancelling convergence requests cooperative shutdown but does not release its
lease; only the owning task's unwind path may release it. A convergence task
suspended in runtime work therefore continues excluding reset and activation
until it has actually exited.

Generic account insertion always clears `isActive`. Generic upsert is
insertion-only for credentials and rejects both the journal-configured target
and journal-pending target. The separate configured-credential API requires a
typed permit from the matching currently owned activation lease. Model flags
cannot bypass this rule.

Importing `auth.json` traverses every ancestor from an opened trusted directory
descriptor with `O_NOFOLLOW`, opens the leaf relative to that descriptor, and
proves stable descriptor identity before and after the bounded read. Path-based
preflight checks do not establish safety. Before standardization or descriptor
open, raw paths containing NUL, relative paths, empty leaf names, or literal `.`
or `..` components are rejected. Ancestor replacement, symlink
substitution, or concurrent leaf replacement/rewrite yields `invalid` or
`unreadable` evidence and never promotes credentials.

## Runtime Reload

A reload target is identified by PID, process start time, user, an independently
resolved kernel executable path, command line, and expected capability marker.
Revalidate all identity fields immediately before signalling or sending RPC.
On macOS, `argv[0]` is classification input only; `proc_pidpath` supplies the
executable identity used for signal authorization. Missing or changed kernel
identity fails closed.

Supported reload mechanisms are ordered by runtime capability:

1. Desktop app-server JSON-RPC token reload with the complete token set and acknowledgement.
2. Verified Codex CLI/app-server SIGHUP implementation with request/ack evidence.
3. Explicit operator restart when the running version lacks a safe reload contract.

On macOS, an `external-app-server` desktop target must declare an explicit
loopback WebSocket listener in its current arguments and own that listening TCP
socket. A `codex app-server --listen stdio://` process belongs to its invoking
host harness; it is not a desktop credential owner and must not enter desktop
reload discovery. Path classification alone is insufficient because managed
Codex binaries can serve both transports from the same executable.

On Linux, both account-bearing app-server modes are reload targets: the
repository-owned WebSocket service and the built-in SSH remote daemon listening
on `unix://`. A `codex app-server proxy` process only transports a client to an
app-server and is never a credential owner or signal target. Runtime convergence
requires acknowledgements from every discovered account-bearing listener, so a
successful port-8390 reload cannot conceal a stale ChatGPT SSH daemon.

The repository-owned `--remote-control --listen ws://...` mode uses the distinct
`headless-remote-control-app-server` runtime kind and
`codexswitch-hotswap-headless-idle-v1` capability marker. When one or more
initialized frontends are present, the transport first attempts to enqueue the
notification. A disconnected connection that rejects enqueue is historical
state, not an eligible writer. The acknowledgement reports internally
consistent initialized, successfully enqueued eligible, disconnected, and
completed-write counts. When any eligible writer exists, every eligible writer
must complete the underlying `account/updated` transport write. When no live
writer accepts delivery, the headless listener may instead report an explicit
idle-listener acknowledgement, including any initialized-but-disconnected
historical connection count. That idle proof is runtime convergence, not
notification of a live client: it is valid only after the same bound auth reload
and cache fingerprint checks, and the next client initializes against that
reloaded auth manager. Desktop and other `external-app-server` runtimes remain
strict and cannot use idle proof. A timeout from an eligible writer, a partial
write set, contradictory counts, missing capability marker, or runtime-kind
mismatch remains degraded.

Successful signal delivery is recorded separately from verified acknowledgement.
The runtime reloads backend auth before it attempts frontend delivery, so an
unacknowledged target may already have changed. Import rollback must perform and
verify compensating convergence after any delivered signal; failure to prove the
restored runtime enters `ManualReview` instead of claiming a safe rollback.

The desktop reload client owns one admitted transaction: JSON-RPC submission,
identity readback, and its strict acknowledgement all use the same discovery and
admission. AppDelegate never follows that result with an independent desktop
signal. Failed, unsupported, unverified, zero-listener, or partial JSON-RPC ends
that desktop attempt as degraded; a later signal cannot override it or turn it
into runtime-current evidence.

The desktop renderer compatibility callback is part of that transaction. Its
auth-cache invalidator must be declared in the same module scope as the callback,
must not throw or leave a rejected promise unhandled, and must update auth state
without unmounting the provider or replacing the renderer. An auth notification
must not reload the window or discard an in-progress composer draft. Desktop
patch readiness therefore requires a versioned auth-cache marker that proves this
scope contract; the historical unversioned `_invalidateAccountQueries` marker is
not sufficient evidence and must be upgraded before activation.

`account/login/start` may emit a transient status notification with no auth
method before the same transaction's `account/read` completes. Multiple status
notifications can overlap, and their reads can finish out of order. Every status
notification therefore advances a renderer-local auth generation. A read may
commit state only while its captured generation is still current; stale reads
must preserve the current state regardless of their result. Cache invalidation
is coalesced across hook subscribers for one short broadcast window so a single
status event cannot fan out into redundant account reads.

When the renderer already has authenticated state, a null status notification
must retain that state, cancel any older confirmation, and schedule a bounded
logout confirmation. A later authenticated notification cancels the pending
logout and starts the current-generation account read immediately. Only a null
read from the still-current confirmation generation may invoke logout handling,
clear the loaded desktop token, or replace application routes. An authenticated
current-generation read atomically replaces the prior account state. Auth-cache
generation V3 plus auth-transition generation V2 prove the scope-safe,
subscriber-coalesced invalidator, latest-generation-wins ordering, and confirmed
logout behavior.

The version-3 reload nonce is an opaque cross-language correlation identifier.
Swift and Rust writers may encode it differently, so readers validate that it
is bounded printable ASCII and rely on the complete process, executable, auth
file, runtime-kind, and acknowledgement binding for identity. A reader must not
reject an otherwise exact binding because the nonce does not use its own local
generator's serialization.

Broad `pkill`, name-only matching, and signalling a newly initialized process are prohibited.

`auth.json` readback proves file configuration, not runtime-current identity.
The Mac may publish runtime-current only when at least one expected live runtime
acknowledges the complete target and every discovered target acknowledges. No
runtime is an explicit configured-only degraded result, never confirmation.

## Hot-Swap Reliability Closure

Hot-swap readiness is acknowledgement-only. A process start after `auth.json`,
a matching executable marker, an auth-file modification time, or successful
signal delivery may explain state, but none can replace a current version-3
acknowledgement. An explicit activation or rotation creates that first
acknowledgement; observation and daemon polling never signal a runtime merely
to renew readiness. Until an explicit convergence attempt succeeds, the
runtime is not ready.

The automatic policy loop must finish a side-effect-free actionability preflight
before requesting fresh runtime authorization. A routine tick with no reset
redemption, reset-inventory refresh, plan upgrade, or account-swap candidate
exits before desktop JSON-RPC, SIGHUP, or CLI reload. Reporting an exhausted
pool with no ready candidate does not require runtime renewal. This keeps the
ten-second evidence lease from becoming a ten-second desktop auth loop. The
same no-op path still clears expired recovery state and stale manual overrides,
and marks a healthy pool recovered.

Remote presentation is a timestamped observation, not durable truth. A failed
probe, a durable activation barrier, a missing acknowledgement, or freshness
expiry invalidates a prior green result immediately. The UI may retain the last
payload for diagnosis only when it is visibly stale and cannot contribute to
pooled readiness or account-current claims.

Observation commands do not acquire create-if-missing mutation locks, repair
file modes, save updater reconciliation, signal processes, or change account
state. They use no-follow, owner-checked, bounded, stable reads and report an
unknown result when those reads cannot be proven.

Remote client selection and status reporting bind to one app-server version
snapshot. If transport establishment changes the observed server version, the
check fails instead of selecting against one version and printing another as an
equality. Client synchronization remains an explicit command.

Runtime evidence retains the acknowledgement's original timestamp and concrete
process binding. Reading an old ACK never creates a new lease. Immediately
before publishing `Confirmed`, the coordinator re-enumerates expected runtimes
and proves that every bound PID, start identity, executable identity, auth-file
identity, and acknowledgement remains current and that no new account-bearing
runtime appeared.

An asynchronous external-auth observation captures the configured account,
swap generation, and activation generation before suspension. If any captured
fact changes before the observation is applied, the result is stale and has no
state effect.

An injected turn does not trust a child process's success JSON by itself. It
generates a receipt nonce, passes it through the exact rotation transaction,
verifies the resulting request and ACK binding, reloads its own `AuthManager`
from the acknowledged path, compares the complete fingerprint, and only then
retries the interrupted operation once.

## Rust CLI Activation And Handoff

The Rust coordinator uses distinct durable outcomes for file convergence and
runtime convergence. `Confirmed` means at least one expected live runtime was
signalled and returned an acknowledgement bound to its PID/start identity, the
exact configured auth path, the request nonce, and the complete token
fingerprint. An empty reload summary, a skipped reload, or zero discovered
targets can never produce `Confirmed`. A deliberate operator-only offline
operation may produce `FileOnly`; daemon and automatic rotation paths reject
that outcome as an incomplete hot swap. An unresolved prior `FileOnly` barrier
must fail before quota polling, reset redemption, replacement selection, or a
new activation report. Offline mode may create `FileOnly` only for the current
request; it does not waive convergence of an older barrier.

A typed `CommittedDegraded` barrier continues bounded observational quota GETs
for the active account and a small set of due inactive accounts. This exception
may update provider-derived quota, plan, subscription, and runtime-usability
telemetry only. It receives no token-refresh,
reset-redemption, auth-write, reload, or target-selection capability, and the
barrier continues to block every account mutation until runtime convergence is
confirmed. `FileOnly`, `ManualReview`, corrupt journal, and unreadable-state
failures do not receive this observational exception.

Activation ownership is bound to the stable provider account identifier, while
the token fingerprint proves one observed credential generation. A normal token
refresh may replace the complete access, refresh, and identity token set without
changing the provider account. A fingerprint change alone must therefore never
turn a file-converged activation into `ManualReview`: when exactly one active
store record still names the journal target and `auth.json` exactly matches that
record's complete current token set, the coordinator advances the journal to
that current fingerprint and retries verified runtime convergence.

Legacy `ManualReview` records created solely by the former degraded-token-set
mismatch are eligible for the same repair only when their version, rotation
kind, bounded reason, stable target identity, single active record, and exact
store/auth token match all agree. The coordinator first converges that durable
target, then performs any newly requested cross-target activation. Every other
manual-review reason remains a hard mutation barrier and receives no reload or
credential write. This migration never labels file agreement as runtime
confirmation. Missing version or kind fields decode as unknown legacy evidence,
not as v3 rotation evidence, and are never eligible for automatic repair.
When a daemon tick rejects an activation barrier, the outer daemon loop remains
side-effect free: it performs no quota network calls, reset effects, auth writes,
or runtime reloads for that tick.
On macOS, a newly started repository-owned desktop bridge may establish its
first ACK during an explicit desktop activation only after CodexSwitch verifies
the canonical `9223` listener, launchd PID, generated bridge files, exact
managed-launcher route embedded in the bridge script, expected runtime and
helper hashes, and the running executable vnode. The local and Homebrew CLI
forwarding wrappers remain part of CLI route verification, not desktop bridge
authorization. This narrow bootstrap is not status evidence: activation remains
degraded until the runtime returns the normal identity-bound ACK and proves at
least one completed desktop frontend write.
The current managed local CLI may establish its first ACK under the same
artifact and running-vnode proof, using the CLI-specific v3 acknowledgement
shape. Exact-name preliminary discovery prevents unrelated command lines from
making the CLI batch incomplete. A historical process lacking the v3 CLI
contract remains a restart-required runtime and is never reported current. Its
presence does not erase successful desktop or current-CLI acknowledgements from
the activation journal or status presentation.
An exact still-running historical CLI that previously returned a valid v3 ACK
may use that prior request/ACK pair as capability proof for a later auth
fingerprint. The proof remains bound to the same PID, process start time, owner,
runtime kind, executable path, executable vnode, canonical auth path, auth
filesystem device, request nonce, and valid CLI ACK shape; it authorizes only a
new verified request and signal, never current account evidence by itself.
Before replacing that process's request, CodexSwitch persists the validated
proof as a private identity-bound capability receipt. The receipt remains valid
for at most 30 days and only while that exact process-start and executable-vnode
identity is still live; PID reuse, executable replacement, auth-root change, or
device change rejects it. When both a receipt and a newer valid request/ACK pair
exist, CodexSwitch must atomically roll the receipt forward to the newer proof
before replacing the request; a failed rollover blocks the new signal. This
bounded receipt lets a transient failed signal be retried without destroying the
freshest historical proof. A missing, malformed, stale, or identity-mismatched
capability proof remains restart-required.

Runtime acknowledgements are cumulative within one configured-account
convergence attempt. Before sending JSON-RPC or SIGHUP, the coordinator checks
whether each exact live binding already has a valid ACK for the requested
provider account and current complete token fingerprint. Already-current targets
count as acknowledged and are not signalled again. Desktop reuse is per PID: a
partial retry sends JSON-RPC only to desktop runtimes missing that exact target
ACK, while strict convergence still counts both reused and newly acknowledged
PIDs. Each desktop PID's verified JSON-RPC result is followed immediately by its
strict identity-bound ACK before the coordinator advances to the next PID. A
later PID failure therefore leaves earlier successful PIDs durable and reusable.
Logs distinguish reused evidence from a newly sent SIGHUP. A retry targets only
missing runtimes, so one unsupported or unacknowledged historical CLI cannot
cause repeated desktop auth notifications, window refreshes, or composer loss
in a runtime that already converged.
After that process exits, a throttled topology-change check may re-arm the
exhausted same-target convergence once without relaunching CodexSwitch. The
check is observational; the subsequent mutation path still performs full route,
hash, vnode, request, signal, and ACK verification.
App launch must preserve a same-target `automatic_retry_limit_reached` journal
as durable manual review. Relaunching CodexSwitch, reinstalling the menu app, or
finishing bridge installation is not new runtime evidence and must not reset the
retry budget or send desktop JSON-RPC. Only an explicit manual retry, verified
external-auth recovery, or a newly observed fully managed runtime topology may
re-arm convergence; an unchanged failing topology remains paused.
The VPS daemon may hold the account-store lock only for a bounded read,
generation revalidation, journal transition, or atomic commit. Provider quota
requests, reset-inventory requests, token refresh, process discovery, signals,
frontend delivery, and runtime acknowledgement waits all run without that
lock. After any unlocked wait, the daemon reacquires the lock and requires the
same store generation plus the same activation target and token fingerprint
before committing. A `FileOnly` or `CommittedDegraded` result schedules runtime
convergence no sooner than 60 seconds later; it never immediately reacquires the
store lock in a retry loop. Normal daemon polling has no missing-ACK bootstrap
scheduler and never signals a runtime merely to refresh readiness evidence.

Provider-derived quota, plan, subscription, reset-inventory, and runtime-blocker
updates are generation-bearing account-store commits. When the current
activation is `Confirmed`, each such commit must advance confirmation to the
new exact store generation without changing its target or token fingerprint,
or leave a durable barrier that blocks readiness. Reconciliation must validate
even a nominally `Confirmed` record against the current store generation before
the daemon performs provider I/O or mutation. A crash or journal failure between
the store commit and continuity publication therefore fails closed on the next
tick instead of silently running with stale confirmation.
Operator `poll` and targeted `redeem-reset` commands perform this activation
barrier reconciliation before their first provider callback. A staged
`Confirmed` generation transition is finalized under the store lock first;
`Prepared`, `ManualReview`, `FileOnly`, `CommittedDegraded`, malformed, or
otherwise unresolved evidence blocks quota GETs, reset inventory GETs, and the
irreversible reset POST. The resulting guard binds both the store generation and
the activation-journal file identity and is revalidated before every callback
and commit. The reset POST additionally holds a dedicated nonblocking
provider-I/O lease; every activation-journal write must acquire the same lease
or fail closed. Account-store and reset-journal locks remain released during
the network callback, while the lease prevents a new activation from entering
`Prepared` between final validation and the first POST byte.

Current-version activation evidence requires an explicit non-unknown activation
kind. Access, refresh, and identity tokens are complete only when each remains
non-empty after trimming whitespace; activation, import, auth writes, and runtime
evidence all enforce the same definition.

After every runtime acknowledgement, the coordinator re-reads the locked store
generation and complete auth token fingerprint before writing `Confirmed`. A
change during reload remains `CommittedDegraded`. Import and replacement-store
operations pass through the same prior-barrier convergence before parsing can
lead to any store or auth mutation.

In-runtime usage-limit and authentication-failure rotation uses the same
external reload protocol as every other Rust activation. The injected runtime
obtains its already verified auth binding, passes that exact path to
`codexswitch-cli`, and never substitutes `~/.codex/auth.json`. The CLI keeps the
activation pending while it sends the path-and-fingerprint reload request and
waits for the runtime acknowledgement. The turn retries only after the CLI
reports verified convergence and the turn's `AuthManager` independently reloads
that same path and proves the reported complete fingerprint. Before the injected
turn uses an ACK-sourced path, it reopens the bounded ACK and matching request
without following symlinks, proves freshness, runtime kind, request nonce,
current process start identity, and the current on-disk complete fingerprint.
Stale PID artifacts or a changed auth file disable rotation.

On Linux, marker and executable inspection opens the kernel-resolved process
executable without following a mutable user path, requires a regular file, and
binds marker evidence to the opened descriptor's device and inode. FIFO,
symlink, replacement, or unavailable `/proc/<pid>/exe` evidence fails closed;
bounded byte scanning is not a substitute for a nonblocking regular-file open.

Bundle import is preparation followed by runtime convergence, with the two
phases explicitly separated when deployment requires the runtime to be idle.
Parsing, expiry checking, account validation, and candidate selection do not
write the store. Under the account-store lock, an idle import records the exact
pre-import store and auth rollback state, commits and verifies the replacement
files, and durably publishes an `Import`/`FileOnly` activation barrier. It does
not attempt reload and does not treat zero runtime targets as a reason to claim
success or roll back a valid file-only preparation. After the managed runtime
starts, the coordinator must reconcile that same barrier with the canonical v3
request/ACK exchange before advancing it to `Confirmed`; failed or absent ACK
evidence leaves the activation degraded. A write or crash-recovery failure
restores only state still owned by that activation generation. If either store
or auth has changed concurrently, rollback preserves the newer state and leaves
a durable `ManualReview` record instead of overwriting it.

`codexswitch-cli import` and `update-bundle` default to live convergence. A
repository deployment that has positively proved the runtime idle must pass
`--offline-file-only`; this flag changes only the new import's handoff and never
waives convergence of a pre-existing activation barrier.

Background cross-host replication must pass `update-bundle --preserve-active`.
The command merges credential changes into the VPS pool while retaining the
VPS coordinator's active provider identity, then converges that same identity
through the normal activation barrier. An incoming bundle cannot select the VPS
active account merely because another host marked it active.

The Rust account-store implementation anchors traversal at a trusted root and
opens every component with `openat` plus `O_NOFOLLOW`. Lock, store, and temporary
descriptors must be regular files owned by the current uid with mode `0600`;
the private parent is mode `0700`. Creation is repaired through descriptor
`fchmod`, committed inode identity is checked after rename, and file plus parent
directory are fsynced before generation/readback proof. The same lock is proven
across processes, not only threads.

Every Rust subprocess has a deadline and bounded streaming capture that drains
both pipes concurrently, kills and reaps on timeout, and never allocates beyond
its per-stream cap. `ps`, `systemctl`, and both injected rotation subprocesses
are included. Direct signals revalidate PID, uid, kernel executable,
command line, and start identity immediately before delivery and while checking
the ACK. A systemd restart is allowed only for the exact repository-owned unit,
after fragment verification, and must pass a bounded post-restart active check.

Rust update source trees, prepared generations, update logs, reload requests,
and ACK files have hard count, age, and byte limits. Cleanup is bounded, does
not follow symlinks, and protects the state-selected generation plus current and
rollback candidates. Directory enumeration is bounded while scanning by entry,
elapsed-time, and retained-memory budgets. ACK and request sizes are checked on
opened no-follow descriptors before allocation or JSON decoding.

The reset-attempt journal uses the same descriptor-anchored secure-file
transaction as `accounts.json` and `auth.json`. Every mutation carries the
generation returned by its locked read, commits with generation CAS, fsyncs and
reopens the committed inode, then proves exact-byte readback. A generation race
does not discard uncertain attempts; it fails closed with durable manual-review
evidence.

## Mac Contract

The observable account model remains `MainActor` isolated. Durable account and auth file operations execute on serial background actors or executors. Imports, activation changes, explicit deletion, security-state changes, and reset state transitions persist immediately and await durable proof before reporting success. Telemetry updates the in-memory model immediately, but whole-store telemetry persistence is coalesced behind a fixed one-minute minimum cadence. Poll results that differ only in `lastRefreshed`, quota `fetchedAt`, or reset-bank `fetchedAt` are suppressed; the latest freshness snapshot is written as a heartbeat no more than once every five minutes. A newer durable user or security mutation cancels and supersedes every older queued telemetry revision, so stale telemetry can never overwrite that durable revision. Only a successful save advances the persisted comparison baseline, leaving failed telemetry saves retryable. Explicit application-shutdown persistence is forced and bypasses telemetry suppression and cadence while retaining revision ordering.

Detached workers capture only immutable `Sendable` inputs. They return their
result through a dedicated `MainActor`-isolated completion method instead of
capturing `AppDelegate` inside a `MainActor.run` closure. The background work
therefore remains off the UI actor while the state mutation has one explicit
actor boundary on every supported Swift 6 toolchain.

- The menu app presents local account state and read-only VPS state separately.
- The ChatGPT desktop and CodexSwitch share one patched local app-server on
  `ws://127.0.0.1:9223`. CodexSwitch keeps that bridge alive and publishes
  `CODEX_APP_SERVER_WS_URL` before ChatGPT starts. Private stdio app-server
  children are not part of the supported steady state because they cannot
  accept CodexSwitch's externally verified reload request.
- Every fresh desktop bridge connection completes the app-server `initialize`
  handshake before account mutation or verification. Current app-server
  responses may omit the optional `jsonrpc` member; identity verification and
  the strict SIGHUP acknowledgement remain mandatory.
- Provider quota is shared, but runtime ownership is host-specific. Every account
  card presents simultaneous `Mac Configured`, `Mac Runtime`, and `VPS Runtime`
  fields, including when the configured and runtime-current Mac identities are
  the same. One account may be `Mac Runtime Current` while another is
  `VPS Runtime Current`. VPS current is
  derived only from a fresh, successful remote account-state observation whose
  explicit `isActive` record carries a bounded non-secret stable provider account
  identifier that exactly matches the local record and independently agrees with
  the readiness snapshot's provider identifier. Email is display metadata only.
  Duplicate local provider identifiers, duplicate active remote identifiers, or
  readiness identity A plus account-state identity B is contradictory and remains
  unknown through integration; neither source may overwrite the other. Duplicate
  emails can never mark two cards current. Quota movement never proves VPS
  ownership. Missing, stale, contradictory, or disconnected remote evidence is
  labeled unknown or disconnected and never receives Mac-current green styling.
- `AccountManager` exposes `configuredAccount` and `runtimeCurrentAccount` with
  distinct meanings. It has no `activeAccount` alias. Generic inactive-account
  upserts cannot alter configured credentials; configured token mutations require
  a journaled activation lease.
- Account cards, status-bar tooltips, popover labels, green rings, and current
  styling receive runtime-current identity explicitly. Configured quota may still
  drive a status ring, but until activation is freshly confirmed its label is
  `Configured`, never `Current`.
- On launch, a degraded Mac activation journal restores its same-target barrier
  before polling can select another account. Consistent committed files resume
  bounded convergence retries. Missing targets or inconsistent/corrupt evidence
  enter manual review without changing account files.
- The popover identifies the host scope as Mac local and shows a concise
  degraded/restart-required status while the activation barrier is present.
- Local quota exhaustion can activate another local account even while a VPS connection is open.
- Launch schedules the synchronous keep-alive installer on a detached utility
  task; watchdog setup and its bounded subprocesses never block the main actor.
- Desktop browser-partition repair is diagnostic and narrowly scoped. Back up before recreation and never move it while the app is running.
- Desktop update checks may download, verify, and stage without interrupting a
  live app. They never replace the installed bundle as a polling side effect.
- App updates use one owner and a staged, verified transaction. Automatic
  installation is entered only at a proven app-termination boundary; an
  explicit manual install is also allowed and uses the same fail-closed runtime
  gate.
- The previous official desktop bundle is freshly trust-validated before its
  rollback identity is captured; preservation revalidates the moved source and
  validates the private copy before capturing that copy's identity. Recovery and
  rollback remain rooted in retained directory descriptors through a post-swap
  destination binding check. A same-inode mutation in that window swaps the
  recorded roots back and defers with its journal intact. The newest rollback
  pointer is not authoritative until its file and retained update-root directory
  are both durably synchronized, and ancestor replacement cannot redirect it.
- Fast mode, model labels, and picker contents are runtime/UI compatibility concerns; they must not be inferred from quota state.

## VPS Contract

- One Rust coordinator owns automatic VPS account activation.
- The CLI and daemon share domain functions; they do not implement independent rotation policies.
- The port-8390 WebSocket service and the built-in SSH `unix://` app-server are
  separate account-bearing runtimes. Both participate in discovery and verified
  reload whenever they are running; `app-server proxy` helpers never do. The
  port-8390 remote-control service may use the explicit headless idle proof. The
  SSH daemon remains a strict external app-server and must prove frontend
  delivery whenever it is retained as a live account-bearing runtime.
- Service status is readable without starting the service.
- Remote usage aggregation preserves the model identity supplied by runtime
  evidence. Missing model evidence is reported as `unknown`; it is never
  replaced with a guessed current model. Long-context accounting is selected
  from explicit model capability metadata (including a conservative family
  rule for newly versioned GPT-5 models), not a closed list of release names.
  Session and log bytes remain on the VPS: the Mac receives only bounded
  per-model aggregate counts and non-secret provenance fields.
- Releases are immutable directories with source Git SHA, build version, and build epoch.
- `$HOME/.local/bin/codex` is a release-neutral CodexSwitch launcher. It
  acquires the shared runtime/install lock, verifies that `current` names a
  managed release with the full hot-swap marker manifest, the activation-bound
  manifest digest, and the exact executable runtime file identities, then
  executes `current/patched-codex/codex`. Launcher publication brackets a full
  release hash validation with identical runtime snapshots, proving those
  identities describe the validated bytes. It must never pin the legacy
  mutable `patched-codex` directory or one immutable release path. First-time
  launcher publication is post-commit: a failed activation cannot leave a new
  launcher pointing through a rolled-back or absent `current` link. The one
  accepted legacy pointer is an absolute link to a direct child of the managed
  `releases` directory; the next activation normalizes it to the relative form.
- Build and preparation use bounded memory and storage away from live runtime paths.
- Activation occurs only through the deployment runbook after readiness and idle checks.

## Remote Session Contract

`codex-vps` provides a short, reliable operator path while preserving explicit behavior:

- `--check` observes transport, authentication, service health, and version provenance.
- Mac-to-VPS observation commands run as one shell-quoted `/bin/sh -c` child
  inside the execution-marker envelope. The envelope never appends grouping
  syntax directly to a command body, because doing so can corrupt heredoc
  terminators and hide an otherwise successful command's completion marker.
- Status and help do not install packages, start services, create tunnels unnecessarily, or rewrite thread state.
- Thread UUIDs are validated before network or persistence use.
- Automatic thread healing is retired; repair is an explicit lease-backed operation.
- Tunnel ownership is verified before termination or replacement.
- Connection loss does not authorize app-server restart if health and ownership are unknown.
- ChatGPT's SSH version probe, daemon bootstrap, and `app-server proxy` command
  all resolve `codex` through the release-neutral public launcher. A successful
  release activation therefore advances the built-in SSH daemon and the
  port-8390 service to the same `current` runtime.

## Status And Repair

Observational commands may read files, APIs, process metadata, health endpoints, and logs. They may not:

- mutate auth or account state;
- redeem resets;
- install dependencies;
- start, stop, or restart services;
- patch applications;
- delete stale data;
- rewrite thread catalogs.

Repairs are named commands with prerequisites, dry-run evidence where practical, and postcondition checks. This separation makes diagnostics safe during active work.

Runtime discovery classifies the kernel executable as well as the command line.
ChatGPT framework helpers, renderers, services, and crash reporters are never
interactive Codex CLI sessions even when an argument or bundle path happens to
end in `Codex`. They cannot make readiness fail or become signal targets.

A version-3 rotation record carrying the recognized legacy degraded-token
mismatch may be superseded when the account store has exactly one active known
account and `auth.json` matches that account's complete token set. Recovery
rebinds the record to that exact account, performs and verifies a runtime reload,
then handles any newly requested cross-account activation. Other manual-review
reasons remain blocked.

The configured Mac account is listed first in the menu. Candidate ranking is
shown separately as "Next up"; it must not move an inactive candidate above the
configured account and imply that list order is activation state.
Configured-only state uses warning styling. Runtime-current emphasis is
reserved for a fresh `Confirmed` activation record.

## Update And Patch Contract

Every update or desktop patch follows:

1. Discover and download into an owner-marked temporary workspace.
2. Verify expected version, manifest, archive shape, and signature inputs.
3. Prepare the complete staged artifact.
4. Apply compatibility changes once under a cross-process lease.
5. Sign the complete staged artifact with an approved identity and minimal valid entitlements.
6. Verify signature, patch markers, provenance, and launch readiness.
7. Activate atomically only when live-session policy permits.
8. Keep bounded rollback material and clean stale owned workspaces.

Two updaters must never own the same app. Background automatic update checks may
download and stage a verified full bundle, but cannot replace the installed app
or report an installation outcome. Automatic installation occurs only after a
proven desktop app-termination boundary and is re-gated immediately before
mutation. An explicit manual install is also allowed through the same gate.
Status checks cannot trigger repair or installation.

When CodexSwitch locally re-signs the desktop bundle, the patched main process
must disable the bundle's native updater before it initializes. User-defaults
ownership remains defense in depth, but it is not sufficient because the desktop
app may rewrite those defaults during startup. After CodexSwitch installs and
patches an update, its automatic relaunch must use background activation and must
not take keyboard focus from the user's current app.

After that patch and signature verification succeed while the desktop is
stopped, the patcher may remove only the exact
`~/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/PersistentDownloads`
contents. It must reject a linked or foreign-owned cache root and must not scan
or remove unrelated application caches. This cleanup prevents failed native
updater downloads from accumulating after CodexSwitch assumes update ownership.

The desktop patch toolchain must bundle a lockfile-pinned ASAR package in the
CodexSwitch app and support both legacy CommonJS `asar` and modern ESM
`@electron/asar` layouts for extract, pack, and Electron header-integrity
hashing. Tool discovery is bounded to an explicit override, the bundled tool,
the CodexSwitch-owned tool root, and existing npm execution caches; normal patch
retries must not invoke `npx`, download another package, or create a new
unbounded cache. Each candidate CLI must be paired with an executable Node
runtime that satisfies its minimum version; the pinned `@electron/asar` `4.2.0`
tool requires Node `22.12.0` or newer. A missing compatible tool/runtime pair is
a visible blocked state, not permission to loop on background downloads.

Renderer patch markers identify behavior generations, not merely function names.
The patcher must migrate a recognized unsafe generation in the staged artifact,
and both the patch manager and installed-app locator must reject that generation
until the current versioned marker is present. Re-running the current patch is
idempotent and must not add duplicate callbacks, timers, or helper declarations.
Remote-recents compatibility uses native conversation callbacks for immediate
updates. Its recovery timer is a missed-notification fallback only: it performs
no extra injected refresh at mount, preserves the native startup refresh, runs
no more often than once per 60 seconds, and is cancelled when the owning effect
unmounts.

Ordinary recent-thread listing must use the app-server state database rather
than scanning rollout JSONL files. The desktop compatibility patch forces
`useStateDbOnly` only in the sidebar's `listRecentThreads` request; archive,
search, hydration, and repair paths keep their upstream behavior. The indexed
loading marker is required readiness evidence, and the patch must fail closed
when the current method shape is missing or ambiguous.

The authenticated desktop must never remain on its startup logo after the
bounded post-login Statsig bootstrap fails. That failure path uses one
synchronously initialized cached/default client and mounts the application
immediately; normal refresh may continue after mount. It must not enter the
upstream asynchronous identity/client fallback, whose network completion is
not bounded. The versioned fail-open marker and the actual failed-bootstrap
branch replacement are both required readiness evidence. A missing or
ambiguous bootstrap shape fails the compatibility patch closed.

Rollback trust is not inherited from an earlier installed-app observation. The
transaction validates the previous bundle through the official trust pipeline,
captures a format-3 seal over its complete descriptor-rooted tree, revalidates
the moved source, and independently validates the private rollback copy before
capturing that copy's identity. Recovery retains the old bundle root through its
pre-swap full-tree comparison, atomic swap, and post-swap destination binding
comparison. If the latter detects mutation and both recorded roots still match,
the roots are swapped back and synchronized; otherwise recovery performs no
speculative rename. Its format-4 journal binds descendant device/inode and
change-time state in addition to portable content, so a changed child,
same-inode ABA, symlink, metadata record, extended attribute, or ACL defers
recovery without replacing the destination. A format-2 rollback pointer
is published and the former generation retired only through one retained update-
root and ancestor descriptor chain, after atomic pointer rename plus pointer-file
and parent-directory `fsync`. The former generation is retained before
publication and retired only while its original directory binding remains
current; substitution is preserved rather than removed.

Updater subprocesses launched from a GUI process receive an explicit canonical
`HOME` derived from the current user's home directory. They must not depend on
LaunchServices, Finder, or another GUI launcher preserving shell environment
variables. Build jobs remain capped even when the inherited environment is
empty.

The normal update failure backoff must not strand a Mac that has no complete
hot-swap runtime. Missing-runtime repair uses a bounded five-minute attempt and
failure cadence while still allowing only one updater task at a time. A failed
repair therefore recovers promptly after an environment or transient build
problem without creating a tight retry loop.

The macOS CLI installer activates the exact attempt-ID generation recorded in
`preparedBinaryPath`; it never guesses a legacy `<version>/codex` location or
selects a stock runtime. The prepared `codex`, `codex-code-mode-host`, and
`codexswitch-cli` set is validated, signed, and then treated as immutable. One managed launcher under
the CodexSwitch data directory is the atomic pointer to that generation. The
user and Homebrew entrypoints are static bridges to that managed launcher, so a
later runtime update changes one small pointer file rather than rewriting every
shell route. Launcher execution performs bounded structural checks only;
content hashes, version probes, and marker scans remain activation and status
work, never per-command startup work.

The first bridge repair is a journaled transaction. Staged launcher files and
same-directory backups are synchronized before publication, each destination
is verified after rename, and interrupted work is reconciled before another
installation begins. The previous verified generation remains protected as the
single rollback candidate. Publishing a new launcher does not mutate or signal
an already running CLI process; one explicit exit and resume is required after
the control plane and runtime pair are activated, because credential reload
cannot replace the executable image of the current process.

Runtime capability probes read the executable header once and scan the binary
for required contract markers in bounded chunks. They do not load the complete
Codex executable into memory or rescan the whole file once per marker.

Generated source patches are crate-complete: when injected Rust references add
an upstream dependency, the patch transaction also adds that dependency to the
manifest of every affected crate idempotently, including both `codex-login` and
`codex-app-server` when secure file opens inject `libc` flags. A patched source tree is never considered
prepared until the current stable tag compiles both the CLI and its required
`codex-code-mode-host` companion.

## Storage Contract

All CodexSwitch-created storage has:

- an owner marker or exact safe naming contract;
- semantic change detection before creating a backup;
- a maximum count, age, and total-size policy;
- bounded directory scans and streaming content inspection;
- symlink and special-file rejection where paths cross trust boundaries;
- startup cleanup that touches only proven CodexSwitch artifacts;
- logs that report cleanup counts and bytes without printing secrets.

Large downloads and binaries are streamed. Reading a multi-gigabyte executable into memory is prohibited. Build targets and archives do not live indefinitely on a space-constrained Mac.

## Operational Proof

A hot-swap claim requires all of:

1. Store generation advanced once.
2. Active account and auth readback agree.
3. Complete token hash matches the selected account.
4. The intended runtime target accepted the reload.
5. The prior process identity was not confused with a reused PID.
6. A new request succeeds without exiting and resuming the session.
7. No unrelated process or remote host state changed.

A deployment claim additionally requires source provenance, service readiness, post-activation resource checks, and a tested rollback pointer.
