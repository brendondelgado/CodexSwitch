---
title: macOS runtime discovery
description: Fail-closed discovery and authorization contract for local Codex reload targets on macOS.
toc:
  - macOS Runtime Discovery
  - Scope
  - Discovery Contract
  - Race Handling
  - Reload Binding
  - Desktop Transport Bridge
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
  - ../../Tests/CodexSwitchTests/SwapEngineTests.swift
  - ../../Tests/CodexSwitchTests/DesktopRuntimeHotSwapStateTests.swift
  - ../../Tests/CodexSwitchTests/DesktopRuntimeReloadClientTests.swift
version_control:
  branch: main
  status: canonical
  last_updated: 2026-07-25
---

# macOS Runtime Discovery

## Scope

This contract defines how CodexSwitch converts a bounded macOS process snapshot
into candidate local CLI and desktop app-server reload targets. Discovery is not
authorization: no PID may be signalled until it passes the independent runtime
classifier and the kernel-backed identity checks in the runtime ownership
contract.

## Discovery Contract

CodexSwitch currently uses bounded `/usr/bin/pgrep` calls to enumerate candidate
PIDs because the repository has no structured API that covers both CLI and
app-server process enumeration. The command text emitted by `pgrep` is used only
to detect duplicate-row ambiguity and is discarded before classification. The
snapshot boundary must:

1. Reject timeouts and exit statuses other than `0` or `1`.
2. Decode stdout as strict UTF-8; undecodable output is an unsafe failure.
3. Treat status `1` as `noMatches` only when stdout is blank. Nonblank stdout
   with status `1` is contradictory and fails closed.
4. For status `0`, accept only rows containing a positive `Int32` PID and a
   non-empty command line separated by whitespace.
5. Normalize accepted rows into a typed PID snapshot so stale `pgrep` command
   text can never become classification input or reach a signal path.
6. Collapse only exact duplicate PID and full-command rows. Arguments affect
   runtime classification, so any repeated PID with a different normalized
   command line is ambiguous and every row for that PID is quarantined.
7. Mark the process-enumeration boundary unsafe when at least one valid row
   survives but any arbitrary malformed or ambiguous row was dropped. An unsafe
   enumeration makes the entire reload fail closed with
   `operationFailed = true` and zero signals, even when some independently valid
   PIDs remain.
8. Return a distinct failure when status `0` contains no unambiguous accepted
   rows. An empty successful snapshot is also a failure because it contradicts
   `pgrep` status `0`.
9. After a complete PID enumeration, preserve every PID that cannot be bound to
   a stable owner, start identity, argv, executable path, device, and inode as a
   typed blocker with its failure reason. A blocker is convergence evidence; it
   is never silently dropped or counted as an acknowledged runtime.

## Race Handling

A process may exit while `pgrep` is constructing output, leaving a PID-only or
otherwise incomplete row. The dropped row makes the complete candidate set
unknowable, so CodexSwitch does not signal otherwise valid survivors. This is a
safe failed operation, not a partial convergence attempt.

If every row is malformed or ambiguous, discovery fails without signalling.
Status `1` with blank output remains the only authoritative no-match result at
the process-enumeration boundary.

Once credentials have committed, a complete PID enumeration followed by an
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

- `managed-desktop-bridge` is reserved for the repository-managed Mac bridge
  whose loopback listener is proven to use port `9223` and whose process and
  listener identities satisfy the complete binding and revalidation contract.
  Only this runtime kind may use the exact all-zero desktop idle branch.
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

## Desktop Transport Bridge

Current ChatGPT desktop builds launch their private local app-server over stdio.
That child has no independently connectable endpoint, so CodexSwitch cannot
perform an externally verified account reload against it.

CodexSwitch owns one local `managed-desktop-bridge` at
`ws://127.0.0.1:9223`. A launch agent keeps one patched Codex app-server
listening there and publishes `CODEX_APP_SERVER_WS_URL` so ChatGPT uses the same
runtime. The bridge uses the normal OpenAI app-server transport; it is not a
Headroom or provider proxy.

The bridge contract is:

1. Exactly one current-user app-server owns port `9223`.
2. ChatGPT connects to that listener instead of spawning a private stdio child.
3. Stale private app-server children are conflicting runtimes, not fallback
   endpoints. Runtime discovery fails closed until the conflict exits.
4. Each new WebSocket connection sends `initialize` before any account RPC.
5. App-server responses may use either the legacy JSON-RPC envelope with
   `jsonrpc: "2.0"` or the current envelope containing only `id` plus
   `result`/`error`. An explicit non-2.0 `jsonrpc` value remains invalid.
6. A successful account RPC is still followed by the version-3 SIGHUP
   request/ACK proof bound to `managed-desktop-bridge`. When at least one
   initialized frontend exists, the bridge remains strict and every eligible
   frontend must complete the `account/updated` transport write. When the
   launchd-kept bridge has exactly zero initialized frontends, it may instead
   acknowledge that its backend auth cache is current and that a future
   frontend will initialize against that cache, but every required frontend
   writer and delivery counter must be present and exactly zero. Missing
   counters, mixed values, or any nonzero value are not an exact all-zero idle
   ACK. This shape does not claim that ChatGPT was notified. The bridge never
   weakens process, socket-owner, auth file, or token-fingerprint validation.
7. During an explicit account activation, CodexSwitch keeps the initialized
   `account/read` verification WebSocket open until the strict SIGHUP
   request/ACK operation finishes. That control connection is an eligible
   frontend writer and must complete the `account/updated` transport write.
   Closing it after verification but before SIGHUP is forbidden because the
   app-server may still account for the initialized connection while its writer
   is already gone, producing a timing-dependent rejected or incomplete
   delivery. The socket is closed only after the ACK attempt completes.

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
   the current observation. The one exception is first-ACK bootstrap during an
   explicit desktop activation for the repository-owned
   `managed-desktop-bridge` on port `9223`: its launchd PID, generated
   bridge files, the exact managed launcher embedded in those bridge files,
   expected runtime/helper hashes, and the running executable vnode must all
   match before CodexSwitch may write one request and send one signal. The
   independent local and Homebrew CLI forwarding wrappers are validated for CLI
   routing, but are not an admission dependency for this desktop-only bridge.
   Executable markers or path modification time alone are never running-image
   proof.
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

The managed `9223` bootstrap closes the otherwise circular first-start
dependency: a newly launched app-server cannot have an identity-bound ACK until
it has received its first identity-bound request. Bootstrap is mutation-path
only, applies to the exact launchd-owned `managed-desktop-bridge` PID and socket,
and still requires the normal post-signal ACK with matching auth fingerprints.
If an initialized frontend exists, the ACK also requires every eligible
frontend write. If the initialized count is exactly zero, the ACK must instead
carry the exact all-zero idle-listener shape. It never makes readiness green by
itself and does not authorize arbitrary app-servers or local interactive CLI
processes.

Desktop bootstrap derives its runtime route from the fixed managed-launcher path
inside the byte-verified bridge script. Requiring agreement from unrelated CLI
forwarding wrappers would let a stale or unreadable interactive shell route
block an otherwise valid desktop reload, even though launchd never executes
those wrappers.

The Swift verifier must reproduce the Rust-generated launcher bytes exactly.
Indentation uses real tab bytes; a Swift raw-string sequence such as `\t` is a
literal backslash plus `t` and must never be used as the expected grammar.
Regression coverage must assert both successful route parsing and the absence
of literal `\t` prefixes in the generated fixture.

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
An exact zero-frontend `managed-desktop-bridge` idle ACK is valid activation
evidence for the dormant backend but is not active desktop readiness. Status
remains non-ready until a later ACK proves delivery to an initialized frontend.
Likewise, the managed bridge's listening port alone never means the ChatGPT host
is running or connected.

Desktop `account/read` JSON-RPC verification is diagnostic and cannot replace
the identity-bound request/ACK proof. A `.reloaded` result requires at least one
explicit target identity to match: normalized email or canonical account ID.
App-server ACK accounting is exact:
`skippedFrontendCount + eligibleFrontendCount + rejectedFrontendCount`
must equal `initializedFrontendCount`, and `frontendWriteCount` must equal the
eligible count. Initialized frontends that are intentionally skipped remain
part of the total and do not invalidate an otherwise complete delivery proof.
The desktop activation client keeps its verified control connection live
through SIGHUP, so a normal explicit managed-bridge reload proves positive
delivery even when the ChatGPT renderer is not connected. The exact all-zero
managed-bridge shape remains a bootstrap contract for a truly dormant listener;
it is not a workaround for closing the control socket too early.
That control write proves backend convergence and a working outbound transport;
it does not by itself prove that a separate ChatGPT renderer consumed the
notification or refreshed its UI. Renderer-current status still requires the
renderer to remain an eligible writer plus the desktop compatibility evidence
defined by the installed-app contract.
An ordinary `external-app-server`, including a VPS target reached through SSH
or a Unix socket, always requires positive completed frontend delivery and may
not use an idle-listener shape. Only the identity-bound repository-managed
`managed-desktop-bridge` on loopback port `9223` may use the exact all-zero
shape, and only when all four frontend counts and `frontendWriteCount` are
present and exactly zero. Any initialized, skipped, eligible, or rejected
frontend makes that shape invalid and restores the completed-write requirement.
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
URLSession WebSocket. Runtime-kind tests prove that only the
identity-verified repository-managed loopback listener on port `9223` can use a
`managed-desktop-bridge` exact all-zero idle ACK, that missing or mixed counters
fail, that ordinary `external-app-server` targets including VPS SSH/Unix
topologies require positive frontend delivery, and that
`headless-remote-control-app-server` uses only its separately classified idle
contract. Concurrent batch tests also prove that a competing desktop discovery
provider cannot run until the first attempt releases PID admission after strict
ACK completion. All tests use typed snapshots and injected process, argv,
executable-vnode, socket, file, clock, ACK, and signal seams; there is no
environment-enabled live reload test.
