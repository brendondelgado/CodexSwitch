---
title: macOS runtime discovery
description: Fail-closed discovery and authorization contract for local Codex reload targets on macOS.
toc:
  - macOS Runtime Discovery
  - Scope
  - Discovery Contract
  - Race Handling
  - Reload Binding
  - Official Desktop Native Child
  - Artifact Validation
  - Signal Authorization
  - Status Observation
  - Deterministic Proof
cross_dependencies:
  - runtime-and-host-ownership.md
  - ../../Sources/CodexSwitch/Services/SwapEngine.swift
  - ../../Sources/CodexSwitch/Services/CLIStatusChecker.swift
  - ../../Sources/CodexSwitch/Services/CodexManagedRuntimeTrust.swift
  - ../../Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - ../../Sources/CodexSwitch/Services/DesktopRuntimeReloadClient.swift
  - ../../Sources/CodexSwitch/Services/DesktopRuntimeDiagnostics.swift
  - ../../crates/codexswitch-cli/src/reload.rs
  - ../../Tests/CodexSwitchTests/SwapEngineTests.swift
  - ../../Tests/CodexSwitchTests/DesktopRuntimeHotSwapStateTests.swift
  - ../../Tests/CodexSwitchTests/DesktopRuntimeReloadClientTests.swift
version_control:
  branch: main
  status: canonical
  last_updated: 2026-08-01
---

# macOS Runtime Discovery

## Scope

This contract defines how CodexSwitch converts a bounded macOS process snapshot
into candidate local CLI and desktop app-server reload targets. Discovery is not
authorization: no PID may be signalled until it passes the independent runtime
classifier and the kernel-backed identity checks in the runtime ownership
contract.

## Discovery Contract

CodexSwitch uses one shared bounded exact-name `/usr/bin/pgrep -l -x codex`
call to enumerate candidate PIDs because macOS has no single structured API
that enumerates both CLI and app-server processes. Local CLI discovery,
official ChatGPT native-child discovery, desktop status, and legacy WebSocket
port diagnostics must all start from this same snapshot. Full-command regular
expressions such as `pgrep -f "codex.*app-server"` are prohibited: macOS may
truncate or reshape command output, causing a live native child to disappear
from an account-swap transaction. The process-name hint emitted by `pgrep` is used
only to detect duplicate-row ambiguity and is discarded before classification.
Every accepted PID is then bound through `proc_pidinfo`, `proc_pidpath`, and a
bounded `KERN_PROCARGS2` read. Runtime discovery and immediate pre-signal
revalidation must not invoke `/bin/ps` once per process; serial subprocess
probes make account handoff latency proportional to the number of running
sessions and can outlive the interrupted turn. The snapshot boundary must:

1. Reject timeouts and exit statuses other than `0` or `1`.
2. Decode stdout as strict UTF-8; undecodable output is an unsafe failure.
3. Treat status `1` as `noMatches` only when stdout is blank. Nonblank stdout
   with status `1` is contradictory and fails closed.
4. For status `0`, accept only rows containing a positive `Int32` PID and a
   non-empty process-name hint separated by whitespace.
5. Normalize accepted rows into a typed PID snapshot so stale `pgrep` command
   text can never become classification input or reach a signal path.
6. Collapse only exact duplicate PID and process-name rows. Any repeated PID
   with a different normalized process name is ambiguous and every row for
   that PID is quarantined.
7. Mark the process-enumeration boundary unsafe when at least one valid row
   survives but any arbitrary malformed or ambiguous row was dropped. An unsafe
   enumeration makes the entire reload fail closed with
   `operationFailed = true` and zero signals, even when some independently valid
   PIDs remain.
8. Return a distinct failure when status `0` contains no unambiguous accepted
   rows. An empty successful snapshot is also a failure because it contradicts
   `pgrep` status `0`.
9. After a complete PID enumeration, preserve every PID that cannot be bound to
   a stable owner, start identity, bounded kernel argv, executable path, device,
   and inode as a typed blocker with its failure reason. A blocker is
   convergence evidence; it is never silently dropped or counted as an
   acknowledged runtime.
10. After identity binding, exclude non-account-bearing Codex subprocess modes,
    including `sandbox`, `exec`, app-server, remote-client, and ephemeral
    invocations. They are neither reload targets nor blockers in the interactive
    CLI lane.

## Race Handling

A process may exit while `pgrep` is constructing output, leaving a PID-only or
otherwise incomplete row. The dropped row makes the complete candidate set
unknowable, so CodexSwitch does not signal otherwise valid survivors. This is a
safe failed operation, not a partial convergence attempt.

If every row is malformed or ambiguous, discovery fails without signalling.
Status `1` with blank output remains the only authoritative no-match result at
the process-enumeration boundary.

The initial snapshot performs one external enumeration and then uses direct
kernel reads for every candidate. Immediate revalidation repeats only those
bounded kernel reads; it does not spawn another process-table command. Once
credentials have committed, a complete PID enumeration followed by an
identity-binding failure has a different safety shape. CodexSwitch may persist
requests, signal, and collect acknowledgements for every independently verified
survivor because each signal still carries its own complete authorization.
The unbindable PID remains a typed blocker, the reload summary remains failed,
and activation remains `CommittedDegraded` until that PID exits or becomes
verifiable. Repeated transient failures use capped backoff and a saturating
attempt counter; they never become `ManualReview` because of their count. One
stale process must not prevent a healthy process from adopting
already-committed credentials.

Recovery observes a typed topology containing both verified runtimes and the
exact blocker set. The blocker set and activation generation survive every
retry and restart. A changed or empty blocker set may make a later attempt
actionable, but an unchanged set is retried only at the bounded journal cadence.
Unsafe process enumeration never authorizes confirmation. Existing ACKs for the
same credential and process binding are reused, so blocker recovery does not
reload an already-acknowledged desktop bridge.

A live CLI from an older prepared generation remains discoverable after a
runtime update. It may receive a new request only when CodexSwitch verifies the
retained generation's adjacent artifact manifest, exact runtime and helper
hashes, read-only ownership, canonical prepared-root containment, and live
device/inode identity. Trusting only the current launcher would make every
successful update strand already-running sessions. A retained runtime whose
path or manifest is absent stays a typed blocker and requires restart.

## Reload Binding

Every reload attempt is represented by one immutable typed binding. The binding
contains all authority needed to correlate one request and one response:

1. Exact PID, owner, process start seconds, and process start microseconds.
2. The executable identity independently resolved from the running process's
   mapped executable vnode after argv capture: its kernel-canonical path,
   device number, and inode. The canonical path must equal the executable path
   recorded in the process identity, while device and inode prevent a same-path
   replacement from inheriting authority.
3. The typed runtime kind.
4. The canonical absolute `auth.json` path reached without following a symlink
   in any path component, plus the positive device and inode read from that
   already-open descriptor. An atomic same-content replacement is a different
   auth identity.
5. The provider account ID plus a SHA-256 fingerprint over every non-empty
   token identity field: ID token, access token, refresh token, and account ID.
6. A cryptographically unguessable operation request nonce.
7. Binding contract version `3` and a bounded issue time.

The request artifact is encoded structured JSON containing the complete binding.
A PID-named nonce-only request file is never sufficient authority. Once created,
the binding is not recomputed or partially updated during the operation.
Version `3` is the structured request/ACK wire version. Static binary patch
markers are installation hints only and never substitute for a version-`3`
artifact or identity check.

Runtime kinds are closed authorization contracts derived by the classifier, not
labels that an ACK may select for itself:

- `official-desktop-stdio-child` is reserved for a `codex app-server`
  runtime using either the app-server's default stdio transport or one explicit
  `--listen stdio://` declaration, whose ancestry reaches the official
  OpenAI-signed ChatGPT app. It uses the strict frontend-delivery ACK
  contract; private transport is not permission to accept an idle ACK.
- `external-app-server` covers every ordinary external app-server, including a
  VPS app-server reached through SSH or a Unix socket. It remains strict and
  must prove delivery of `account/updated` to at least one initialized frontend;
  transport shape, no connected client, or zero counters never grants the
  managed bridge exception.
- `headless-remote-control-app-server` retains its separate, broader idle
  contract after positive topology classification. It does not inherit the
  managed bridge's exact all-zero desktop-counter exception, and SSH, Unix
  transport, or an absent frontend is not enough to classify an ordinary
  external app-server as headless remote-control.

## Official Desktop Native Child

The supported Mac desktop topology is the official OpenAI-signed ChatGPT app
spawning CodexSwitch's prepared CLI as `codex app-server`. ChatGPT builds may
either rely on the app-server's default stdio transport or pass
`--listen stdio://` explicitly. CodexSwitch publishes the prepared launcher
in `CODEX_CLI_PATH`; it does not patch, re-sign, proxy, or replace the desktop
host.

The native-child contract is:

1. The ChatGPT root has Team ID `2DC432GLL2` and a valid strict signature.
2. The app-server has no listener declaration, meaning its default stdio
   transport, or one exact `stdio://` declaration. It has no WebSocket
   listener or remote-control mode.
3. The kernel-observed parent chain reaches that ChatGPT root and contains no
   CodexSwitch launch agent, shell bridge, or unrelated app-server.
4. `CODEX_APP_SERVER_WS_URL` is absent and the legacy
   `com.codexswitch.desktop-app-server-9223` job is unloaded.
5. CodexSwitch writes a version-3 request bound to the child identity and sends
   SIGHUP only after immediate identity and ancestry revalidation.
6. The child must acknowledge the complete token fingerprint and successful
   `account/updated` frontend delivery. An idle or all-zero ACK is rejected.
7. The private stdio transport is never opened by CodexSwitch. Hot-swap proof is
   the identity-bound version-3 request/ACK path already implemented by the
   prepared CLI.
   delivery. The socket is closed only after the ACK attempt completes.
   The Swift app coordinator and Rust CLI coordinator implement this same
   initialize, full-token login, account verification, retained-writer, SIGHUP,
   ACK, and post-ACK verification transaction; neither may provide a signal-only
   shortcut for the managed bridge.

## Artifact Validation

Startup capability evidence is a prior structured request plus ACK pair. The ACK
must echo that complete request binding exactly, and its stable process,
executable, runtime, auth path/device/inode, and token fingerprint fields must
equal the current typed observation. A response ACK must echo the current
operation binding exactly, including its nonce.

Request, ACK, and auth artifacts are read through bounded no-follow descriptors.
Every path component must be a directory owned by root or the current user and
must not grant unsafe non-owner writes. Each file must be regular, owned by the
current user, mode `0600`, and within its byte limit. Symlinks, oversized files,
short reads, invalid UTF-8 or JSON, and path substitution fail closed.

Embedded issue and acknowledgement times and descriptor-backed modification
times must be finite, ordered, not stale, and not unreasonably in the future.
Fresh timestamps or mtimes are only secondary replay bounds; they never replace
an exact binding match. Wrong process start, executable, runtime kind, auth path,
auth device/inode, token fingerprint, or nonce always fails even when every
timestamp is fresh or the replacement auth file has identical bytes.

## Signal Authorization

Each PID in a complete typed snapshot is classified from current process state,
not from `pgrep` text. A signal path must:

1. Acquire per-PID admission for every sanitized preliminary PID before any
   identity-bound process, argv, executable-vnode, or auth discovery. Keep that
   admission through response ACK completion; a competing attempt may not run
   its discovery provider until ownership is released.
2. Capture one kernel-backed identity containing PID, owner, start time, and
   executable path.
3. Require the current user's ownership, then read the process's current argv
   from an owner-verified kernel process source.
4. Resolve the kernel-canonical executable path and mapped-vnode device/inode
   independently, capture process identity again, and require all identity
   reads to match before classifying argv.
5. Read the canonical no-follow auth file once, bind its descriptor-derived
   device/inode and complete token fingerprint, then form the immutable binding.
6. Establish capability from complete startup request and ACK evidence matching
   the current observation. First-ACK bootstrap for an
   `official-desktop-stdio-child` additionally requires a fresh ancestry walk
   to a top-level `/Applications/*.app` ChatGPT executable with OpenAI Team ID
   `2DC432GLL2`, the
   exact stdio invocation, and the running executable vnode. Executable markers
   or path modification time alone are never running-image proof.
7. Persist the complete structured request binding, then sandwich two equal
   argv reads between exact process-identity reads and reclassify the runtime
   kind while revalidating the executable vnode, auth path/device/inode,
   account ID, and token fingerprint immediately before SIGHUP.
8. Signal every fully authorized target before waiting, then await all response
   ACKs against one aggregate monotonic deadline.
9. Before accepting an ACK, repeat the identity-sandwiched equal-argv proof and
   runtime-kind classification together with the same executable vnode,
   no-follow auth path/device/inode, account ID, and complete-token fingerprint
   both before and after artifact parsing.

Capability evidence collected before a PID identity change never authorizes the
replacement process. A stock process whose executable path is replaced by a
patched file remains unsupported because on-disk path state is not running-image
evidence.

The native-child bootstrap closes the first-start dependency without opening
the private stdio transport. It is mutation-path only and still requires the
normal strict post-signal ACK with matching auth fingerprints and completed
frontend delivery. It never authorizes arbitrary app-servers or local
interactive CLI processes.

Local CLI preliminary discovery uses the exact process name `codex`; it must not
use a broad full-command-line match that admits CodexSwitch, ChatGPT,
`codex-code-mode-host`, build tools, or short-lived commands whose paths merely
contain the word `codex`. Kernel identity and argv still perform final runtime
classification.

A current managed interactive CLI may also establish its first ACK during an
explicit activation. This bootstrap requires the exact managed-launcher route,
expected runtime and helper hashes, current-user ownership, read-only artifact
files, and equality between the verified runtime file vnode and the running
executable vnode. The normal v3 request, SIGHUP, and CLI-shaped ACK remain
mandatory. Historical or unverified runtimes are not eligible; they require one
exit and resume into the current managed runtime.

When a historical CLI blocks convergence, each due same-target attempt observes
the exact local CLI topology off the main actor. The attempt counter never
resets because topology changed; it saturates while `nextRetryAt` uses the
capped retry interval. A stable failing topology therefore cannot create an
unbounded busy loop. A valid legacy
`automatic_retry_limit_reached` journal is migrated on load to the same
activation generation with its typed blockers and counts intact. App launch
alone does not authorize confirmation or an immediate desktop JSON-RPC send.

Desktop JSON-RPC mutation participates in that same admitted operation. PID
admission is acquired before typed runtime or listening-port discovery. Each
WebSocket endpoint is bound to one exact PID/start/owner/executable-vnode/argv
runtime identity, and both that complete runtime identity and the current
listening-socket owner are revalidated immediately before every send. Port reuse
or identity drift suppresses the send. A failed or unverified JSON-RPC phase
cannot enter the strict signal phase. Admission remains held while all verified
desktop targets are signalled and until the single aggregate strict ACK deadline
completes; the JSON-RPC and strict reload phases cannot be separate competing
operations.

The structured request write has its own final currentness boundary. While the
request-file lock is held, the writer reads the locked generation, revalidates
the complete immutable binding, and only then calls atomic replace. Drift after
the earlier capability proof leaves the prior request bytes unchanged and cannot
reach SIGHUP.

## Status Observation

Readiness status consumes typed observational snapshots containing complete
process, executable-vnode, argv-classified runtime, auth-path, account-ID, and
token-fingerprint identities. There is no reachable PID-only capability, ACK,
or string-process-list readiness API. A timeout, malformed process row, argv or
identity race, insecure auth file, or incomplete observation makes readiness
fail closed; status never upgrades surviving PIDs from an incomplete snapshot.
CLI account matching uses the account ID from that same no-follow auth evidence,
never a second raw `auth.json` read.

`SwapEngine.localRuntimeEvidenceSnapshot(runtimeKind:)` is the read-only policy
boundary for account activation and status. It returns verified live runtime
observations paired with their complete startup acknowledgements. It does not
write a request, delete an artifact, signal a process, or bootstrap capability.
If any candidate cannot be observed and revalidated, including a fresh argv
runtime classification, before and after startup-ACK acceptance, the snapshot
is marked incomplete and exposes zero runtime evidence.
Consumers must treat that state as unavailable, never as an empty healthy runtime
set or permission to continue automatic swap/reset policy.

`DesktopPatchManager` derives desktop hot-swap readiness from this same typed
snapshot. An incomplete snapshot or a complete snapshot with no verified desktop
runtime is `unknown`; only a non-empty, complete snapshot is `ready`. Ordinary
readiness is read-only: it performs no artifact deletion, filesystem mutation,
or PID liveness probe. Retention, if introduced, must be an explicit
binding-aware maintenance operation serialized under the same PID admission.
An `official-desktop-stdio-child` must prove delivery to an initialized
frontend. Zero-frontend and idle-listener acknowledgements are invalid.

Desktop `account/read` JSON-RPC verification is diagnostic and cannot replace
the identity-bound request/ACK proof. A `.reloaded` result requires at least one
explicit target identity to match: normalized email or canonical account ID.
App-server ACK accounting is exact:
`skippedFrontendCount + eligibleFrontendCount + rejectedFrontendCount`
must equal `initializedFrontendCount`, and `frontendWriteCount` must equal the
eligible count. Initialized frontends that are intentionally skipped remain
part of the total and do not invalidate an otherwise complete delivery proof.
The ChatGPT-owned stdio frontend remains connected through SIGHUP, so the
strict ACK proves backend convergence and a completed outbound transport write.
An ordinary `external-app-server`, including a VPS target reached through SSH
or a Unix socket, always requires positive completed frontend delivery and may
not use an idle-listener shape. The retired Mac bridge wire kind may decode in
historical artifacts but can never classify a live runtime or authorize a
signal.
A positively classified `headless-remote-control-app-server` keeps its broader
idle-listener policy because it has no desktop renderer contract; that separate
policy may account for disconnected historical connections and is not the
managed bridge's exact all-zero exception.
Interactive CLI ACKs carry no frontend accounting values. Canonical serializers
omit all four keys; decoders also treat explicit JSON `null` as no value for
backward-compatible parsing.
Account IDs are non-empty printable ASCII without whitespace and compare as
exact UTF-8 bytes; they are never trimmed or case-folded. The target account ID
is validated before endpoint discovery or token transmission. Invalid IDs, case
changes, surrounding whitespace, or conflicting ID aliases fail. Any provided
identity mismatch fails, and a matching plan tier without email or account ID
never proves target convergence.

## Deterministic Proof

Focused tests cover mixed valid and malformed rows, all-malformed snapshots,
status `0` and `1` semantics, invalid UTF-8, whitespace normalization, exact
duplicates, argument-level duplicate ambiguity, zero-signal incomplete CLI and
desktop reloads, identity-bound argv capture, structured request persistence,
stale starts, future and stale artifacts, wrong auth paths, account-ID and
token-fingerprint drift, mutually matching nonce replay, canonical executable
path/device/inode drift, argv/runtime-kind drift immediately before signaling
and during evidence acceptance, auth same-content inode replacement, aggregate
ACK deadlines, socket-owner/port reuse, locked-write drift, and identity changes
during capability proof. Desktop transaction tests prove that the shared
connection-completion path invokes strict reload before its transport-release
callback. The installed canary confirms the same ordering with the real
native stdio path. Runtime-kind tests prove that only an
official-ChatGPT-owned exact stdio child can use
`official-desktop-stdio-child`, that idle or mixed counters fail, that ordinary
`external-app-server` targets including VPS SSH/Unix
topologies require positive frontend delivery, and that
`headless-remote-control-app-server` uses only its separately classified idle
contract. Concurrent batch tests also prove that a competing desktop discovery
provider cannot run until the first attempt releases PID admission after strict
ACK completion. All tests use typed snapshots and injected process, argv,
executable-vnode, socket, file, clock, ACK, and signal seams; there is no
environment-enabled live reload test.
