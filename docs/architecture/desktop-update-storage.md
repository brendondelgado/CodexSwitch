---
title: Desktop update storage
description: Canonical staging, validation, retention, and activation contract for ChatGPT desktop updates.
toc:
  - Desktop Update Storage
  - Implementation Status
  - Scope
  - Component Boundaries
  - Authoritative Generation
  - Appcast Cache Transaction
  - Validation Lifecycle
  - Execution And Cancellation
  - Safe Activation And Recovery
  - Retention And Recovery
  - Subprocess Contract
  - Verification Contract
cross_dependencies:
  - runtime-and-host-ownership.md
  - ../../Sources/CodexSwitch/Services/CodexDesktopAppUpdater.swift
  - ../../Sources/CodexSwitch/Services/DesktopAppcastClient.swift
  - ../../Sources/CodexSwitch/Services/DesktopArchiveVerifier.swift
  - ../../Sources/CodexSwitch/Services/DesktopUpdateDownloader.swift
  - ../../Sources/CodexSwitch/Services/DesktopBundleTrustValidator.swift
  - ../../Sources/CodexSwitch/Services/DesktopUpdateStore.swift
  - ../../Sources/CodexSwitch/Services/DesktopBundleInstaller.swift
  - ../../Sources/CodexSwitch/Services/DesktopUpdateCoordinator.swift
  - ../../Sources/CodexSwitch/Services/DesktopUpdateOperationOwnership.swift
  - ../../Sources/CodexSwitch/Services/DesktopUpdateRetention.swift
  - ../../Sources/CodexSwitch/Services/DesktopUpdateRuntimeGate.swift
  - ../../Sources/CodexSwitch/Services/DesktopUpdateScheduler.swift
  - ../../Sources/CodexSwitch/Services/DesktopRuntimeReloadClient.swift
  - ../../Sources/CodexSwitch/Services/DesktopUpdateRuntimeBindingVerifier.swift
  - ../../Tests/CodexSwitchTests/CodexDesktopAppUpdaterTests.swift
version_control:
  branch: main
  status: canonical
  last_updated: 2026-07-24
---

# Desktop Update Storage

## Implementation Status

This contract is implemented by the production updater and Settings UI.
Automatic checks may fetch appcast metadata, download a pinned payload, validate
it, and publish a staged generation while ChatGPT is running. They do not
replace the installed bundle. Automatic installation begins only at a proven
desktop host-termination boundary. The manual Settings action requests a normal
ChatGPT quit, then enters the same fail-closed install, patch, verify, and
background-relaunch transaction.

The deployed updater accepts OpenAI's current archive layout, authenticates the
official appcast payload, validates contained relative archive links, supports
the current Electron bundle seal size, and distinguishes an app-bundle runtime
from an independent CodexSwitch-prepared app-server. Focused updater, archive,
runtime, patcher, and activation tests cover these boundaries.

## Scope

This document defines storage ownership for ChatGPT desktop updates prepared and
installed by CodexSwitch on macOS. Checks and staging never replace a running
ChatGPT application. Installation owns `/Applications/ChatGPT.app` only after
the desktop host has stopped and every runtime loaded from that destination
bundle is absent.

## Component Boundaries

`CodexDesktopAppUpdater` is a thin orchestrator. Appcast HTTP and cache behavior,
archive validation and immutable extraction input, bundle trust and sealing,
descriptor-rooted manifests and retention, journal durability, bundle
installation and recovery, supervised subprocesses, and scheduling each have
focused source ownership. Shared models contain data only. The scheduler
performs no blocking filesystem scan, validation, subprocess, or installation
work on MainActor.

Every production run acquires one non-queuing in-process permit and one
nonblocking cross-process lease before discovery or recovery. Explicit typed
lifetime tokens carry that ownership through appcast/cache work, download,
archive verification, extraction, bundle trust, generation and pointer
publication, installation or recovery, rejection-ledger mutation, retention,
and final status publication. Neither recovery nor stock restoration has an
alternate lease-free entry point. Both tokens remain alive until the operation
has finished all durable mutation and bounded cleanup.

Cancellation probes passed into the actor-owned operation lease are explicitly
`@Sendable` and may capture only thread-safe lifetime or epoch state. This keeps
the lease boundary race-free and compile-time enforced across supported Swift 6
toolchains.

An irrevocably committed install reports installation success even when old
bundle cleanup is pending. That cleanup state is returned through the updater
and coordinator, remains journaled, and is retried by later scheduling and safe
termination work in the same coordinator run. It is never translated into an
install failure or a rollback request.

## Authoritative Generation

`~/.codexswitch/desktop-updates/staged-update.json` is the single authoritative
pointer to a complete staged generation. A generation becomes authoritative
only after its app bundle has been fully downloaded, extracted, version-checked,
and verified as an official OpenAI-signed bundle. Publishing the manifest is the
final atomic commit step.

`pending-update.json` is a separate non-authoritative pointer for at most one
fully downloaded generation whose validation was advisory/unavailable. It does
not make the bundle installable, and installation never reads it. The pending
pointer exists only to preserve immutable download bytes for reassessment so a
transient Gatekeeper condition cannot cause a download/delete loop.

The extracted bundle is the source of truth for both `CFBundleVersion` and
`CFBundleShortVersionString`. Both values must match the appcast release before
the generation can be validated or published; a mismatch rejects the download
instead of persisting the appcast label as unverified bundle metadata. When the
installed build is already newer than the appcast, status reporting uses both
version fields read from the installed bundle.

New generations use a dedicated `generation-<UUID>` directory whose bytes are
treated as immutable after publication. A manifest from
the earlier `staged/ChatGPT.app` layout remains a supported authoritative
generation so an already verified update is not discarded or downloaded again
merely because the storage schema changed. Partial directories and payloads not
selected by the manifest are never install candidates.

## Appcast Cache Transaction

Appcast bytes and HTTP validators are one atomic cache envelope. A successful
200 response is parsed before the envelope is committed, so validator state can
never describe different or malformed bytes. A 304 response is accepted only
when the envelope exists and its appcast parses. Missing or malformed cached
bytes cause the envelope and validators to be cleared, followed by one
unconditional retry in the same check. The retry is bounded to one request and
does not send stale validators.

Appcast response bodies are streamed under a 1 MiB hard limit. The client
rejects redirects whose final URL differs from the configured HTTPS appcast
URL. Archive responses are streamed into a newly created, no-follow regular
file under a 3 GiB hard limit, retained file identity, and an exact final-URL
check. Before download, the release must contain a valid
`sparkle:edSignature`; an optional `sparkle:sha256`/`sha256` digest is additional
corroboration, never a substitute for the vendor signature. Sparkle signatures
are verified over an authenticated private snapshot with Ed25519 and the OpenAI
production public key pinned in CodexSwitch. The downloader creates that
snapshot as an independent APFS clone, opens it read-only, removes its directory
entry, removes every write bit, and applies the user-immutable flag before any
archive parser or extractor receives it. Source and snapshot identity plus
mutation guards must remain stable across cloning. The pin must equal the
`SUPublicEDKey` distributed in the official ChatGPT bundle; an appcast cannot
replace it. When a digest is present, it must also match. Any declared length
must match. Verification reads only the private snapshot descriptor rather than
reopening a mutable path, and the signature is retained as the immutable staged
and rejection-ledger identity. A future OpenAI signing key rotation fails
closed until a reviewed CodexSwitch release updates the pin.
The complete ZIP record graph is then preflighted with limits of 200,000 entries,
8 GiB expanded bytes, 64 MiB central-directory bytes, and a 500:1 per-entry
compression ratio. Every central record is cross-checked with its local header,
including raw and decoded names, encoding and general-purpose flags, method,
CRC, compressed and expanded sizes, and offset. Encryption, ZIP64, data
descriptors, overlapping records, duplicate or case/Unicode/normalization
collisions, file-directory prefix conflicts, absolute paths, traversal, special
files, nonempty directory payloads, and expansion beyond those limits are
rejected before extraction starts. The official old-Unix `0x5855` extra field
is accepted only in its exact local and central forms with matching timestamp
bytes. Alternate-name, Unicode-path, UID/GID, or other semantic extra fields
are rejected so `ditto` cannot select a namespace the preflight did not inspect.
The sorted local records must cover every byte before the central directory
exactly, with no unreferenced prefix, gap, or overlap that another ZIP parser
could interpret differently. Stored UTF-8 symbolic links are accepted
only when every target is relative, remains within the archive root, resolves
to an archive entry, has no cycle, and has no archived descendant beneath the
link. Extraction passes a duplicate of the authenticated private snapshot
descriptor to `ditto` on standard input. Its identity and streaming digest are
checked before and after extraction; the mutable download pathname is never
reopened or accepted as extraction authority.

## Validation Lifecycle

Successful full validation records a format-3, descriptor-relative deterministic
closure over the entire bundle tree. Entries cover the root, directories,
regular files, and only contained relative symbolic links; absolute links,
escaping or dangling link chains, hard-link ambiguity, cycles, and special files
are rejected. Each entry seals path and type, mode, owner and group, flags,
bounded extended attributes, extended ACL semantics, link target when present,
and a streaming SHA-256 digest for regular-file content. The serialized seal is
bounded at 16 MiB, which safely covers the current Electron bundle's roughly
10,550 entries without allowing unbounded metadata. Device and inode bind the
retained live entry while the seal is computed; they are not folded into the
portable copy digest because a verified rollback copy necessarily has new
inodes. Before and after metadata plus two identical descriptor-rooted captures
prove that every retained entry stayed unchanged. Legacy format-2 partial seals
are incomplete and force fresh validation.

Every publication and activation compares a freshly computed complete seal
while the retained root and ancestor descriptors remain valid. Seal age is never
a reason to skip comparison. Periodic appcast checks must ultimately reuse a
generation only after that immediate comparison. The current implementation
suppresses per-minute deep `codesign` work and duplicate staged logging by
reusing a complete seal for a bounded interval, then recomputing streaming
content digests; closing that interval without returning to per-minute full
trust remains part of the target seal design. Installation performs full trust
again.

A missing or changed seal triggers one full validation attempt. Strict
`codesign --verify --strict` runs first. Every completed nonzero strict-
verification status is a definitive signature failure, regardless of stderr
text; it revokes the manifest and moves the owned generation to bounded
quarantine when that can be done safely. Gatekeeper assessment is not run after
strict failure. A runner timeout or cancellation is execution unavailability,
not a successful or failed strict-verification status.

Only after strict verification completes with status zero does the updater run
a separate `spctl --assess --type execute` Gatekeeper stage. The exact trimmed
assessment stderr `internal error in Code Signing subsystem` is
transient/unavailable and preserves the generation under normal retry backoff.
The same text on stdout does not weaken a nonzero rejection. An assessment that
cannot complete is likewise unavailable. Any other nonzero assessment status
is a definitive rejection and revokes the generation. Status zero passes the
assessment stage even when advisory text is present on stderr. The subsequent
signing inspection uses Security.framework and an Apple-anchored designated
requirement, with exact equality for Team ID `2DC432GLL2` and the expected
bundle identifier; human-readable command output and substring matching are
not identity evidence. Structural and version failures remain definitive
invalid results.

For a newly downloaded generation, an unavailable assessment atomically records
the unsealed pending pointer and leaves `staged-update.json` unchanged. A later
eligible check reassesses that same path before invoking any download. Full
validation success creates the seal, publishes the authoritative manifest,
removes the pending pointer, and only then permits installation. Definitive
strict, assessment, identity, structure, or version failure quarantines or
deletes the pending generation and never promotes it.

Every staged or pending path is rejected if any existing ancestor or component
is a symbolic link. Missing updater directories are created component by
component relative to no-follow directory descriptors, so rejection happens
before a descendant can be created through a symlink. Security-sensitive path
normalization is lexical only: it removes `.` and `..` syntax without resolving
an ancestor such as `/tmp` or `/var` through a symbolic link. Callers must use
the actual non-symlink namespace (for example `/private/tmp`) before a retained
descriptor chain can be established. The trusted, already-existing system
temporary root is canonicalized with `realpath` once before updater lease and
workspace children are appended; every child and later mutation still uses the
same no-follow traversal and retained-descriptor checks. The canonical result is
preserved with lexical normalization because Foundation's `standardizedFileURL`
can map `/private/var` back onto the rejected `/var` compatibility symlink.
Trust validation retains
no-follow descriptors for the bundle and its ancestors, observes rename/write
events during the trust interval, and compares complete streamed seals before
and after trust. This detects ancestor replacement, whole-bundle replace-and-
restore attempts, and mutation of helpers or resources that were not part of an
older partial seal. Size and mtime may remain diagnostic metadata, but they are
never sufficient to reuse a generation. Legacy or partial seals require full
revalidation.

A bounded rejection ledger records the release short version, immutable build
and archive SHA-256 payload identity, download URL observed at rejection, and
definitive reason class. Matching uses build plus payload SHA-256, never the
mutable URL: rotating a URL for identical bytes remains suppressed, while a
corrected payload for the same build is eligible for one fresh attempt.
Advisory/unavailable outcomes and releases without an immutable payload digest
are never suppressible ledger entries.

The app bundle is fully validated again immediately before installation. A
failed install-time validation preserves the installed application and revokes
the invalid staged generation.

## Execution And Cancellation

In-process updater acquisition is non-queuing: an occupied operation returns a
busy/deferred result instead of retaining a continuation. The operation-wide
cross-process lease is also nonblocking. A competing process returns busy at
any phase, including discovery, download, trust, publication, installation,
recovery, ledger mutation, and cleanup. No queued continuation or lease waiter
survives cancellation.

Cancellation is checked after every suspension, after each long validation or
subprocess stage, and immediately before filesystem mutation. Before the atomic
commit boundary cancellation leaves the destination untouched and the staged
generation reusable. Once commit begins, cancellation is deferred until the
transaction has either committed completely or rolled back completely; it may
not interrupt the destination between those outcomes.

Generation-directory publication and the pending pointer form one completion
boundary. Cancellation observed after the generation rename is deferred until
the pointer is durably published or the unreferenced generation is removed by
non-cancellable cleanup. Repeated cancellation cannot accumulate refillable
orphan generations.

Each scheduler run owns an epoch and task identity. That token is atomically
checked by storage at every generation, manifest, pending-pointer, rejection-
ledger, journal, cleanup-pointer, and final-status publication boundary.
`stop` invalidates the epoch before cancelling its tasks, and a finishing task
clears a slot only when both values still match. Stale work performs bounded
non-cancellable cleanup of its own unreferenced artifact and cannot publish or
erase replacement work.

Epoch publication serialization permits same-thread reentrant current-state
validation. Cancellation probes may validate the operation lifetime while a
mutation boundary already owns the epoch lock; that nested validation must not
deadlock the background updater or block the MainActor coordinator. Invalidation
from another thread remains serialized behind the complete publication
boundary.

## Safe Activation And Recovery

Staging never changes `/Applications/ChatGPT.app`. A periodic or launch check
may download and stage while the desktop is live, but it never installs as a
polling side effect. Automatic installation begins only after the coordinator
observes a desktop app-termination boundary. Explicit manual installation is
also allowed. Both paths wait for the desktop host and every app-server
executable loaded from the installed app bundle to stop, then check that
condition again immediately before destination mutation. An independent
CodexSwitch-prepared app-server is not loaded from the destination bundle, does
not block replacement, and is never terminated by the updater. If a
destination-owning runtime has restarted or probe evidence is truncated,
successful-but-ambiguous, or unavailable, the valid staged generation remains
authoritative for a later safe boundary. Runtime ownership is classified from
the kernel-resolved executable path for each live PID, not from mutable argv
text or a symlink used to launch the process.

The updater itself never calls `NSRunningApplication.terminate`. The Settings
controller may request a normal quit of the desktop host after an explicit
Install action. Stock restoration and update installation still return a
waiting/deferred result while a destination-owning runtime is externally
observed as active, with no destination mutation or force-quit.

The Settings UI exposes the same coordinator rather than a second updater. It
reports installed, latest, and staged builds. Check and Prepare downloads,
authenticates, extracts, and validates the latest official stock release.
Install Update requests a normal host quit and then uses the existing
termination transaction; it never force-quits or bypasses the runtime gate. A
committed update is never relaunched directly: CodexSwitch first applies the
current ASAR and bundled-CLI compatibility patch, verifies the required patch
markers and the re-signed bundle, and only then relaunches ChatGPT. Patch
failure leaves ChatGPT stopped and reports a repair failure instead of
launching a stock build that cannot hot swap.

macOS may deny mutation inside `/Applications` until CodexSwitch has App
Management permission. Settings exposes that state, opens Privacy & Security,
and provides an explicit retry that clears only CodexSwitch's permission and
attempt backoff markers. The retry does not weaken signing, runtime, archive, or
installation validation.

The activation intent is persisted before patch restoration starts and binds
the exact destination path, short version, and bundle build. A targetless
legacy intent or a different installed build cannot satisfy it. The intent is
cleared only after that exact installed bundle independently passes the
complete patch marker set, strict code-sign validation, bundled runtime
readiness, a stable relaunch, and a fresh same-account auth reload acknowledged
by every discovered desktop runtime. At least one acknowledged app-server
endpoint must also have an established loopback connection from a running
process whose kernel executable identity belongs to the exact installed target
bundle. The verifier matches the complete client/server TCP tuple against
`ESTABLISHED` sockets owned by both processes, proves the acknowledged runtime
still owns the listener, and sandwiches the socket inspection between exact
owner, start-time, executable-path, argument, and executable-vnode identity
checks. This binding permits an independent CodexSwitch-prepared app-server
while preventing a listener handoff, PID reuse, or an unrelated prepared or
developer server from satisfying activation before the updated ChatGPT host is
connected. A reusable
acknowledgement from before the app replacement is not activation evidence. An
interruption resumes that activation on the next CodexSwitch launch or the next
ChatGPT termination boundary. OpenAI's legacy plugin path and the current
`cua_node` Computer Use path are both recognized without re-signing either
preserved helper.

The destination replacement uses a prepared incoming bundle on the destination
volume and an atomic same-directory swap (`renameatx_np` with `RENAME_SWAP`) when
a destination exists. A concurrent launcher therefore observes either the old
complete bundle or the new complete bundle, never an absent or partially copied
destination. A post-probe launch does not turn the transaction into a check-
then-move race.

A single bounded descriptor-rooted format-4 journal records prepared, swapped,
validating, rollback, committed, and cleanup-pending phases with contained paths
and immutable bundle identities for incoming, destination, and previous bundle.
Each bundle identity combines the retained root device/inode, a deterministic
portable full-tree content digest, and a live descendant binding over device,
inode, link count, size, mtime, and ctime. Root timestamps are excluded from the
live binding because the atomic same-parent swap legitimately changes them;
root device/inode remains mandatory. Recovery rechecks the bound identity before
classifying transaction layout, so same-inode child mutation and replace/restore
ABA cannot turn stale evidence into rollback or cleanup authority. Portable
identity is used only to prove an independently created rollback copy has the
same complete content and metadata.
Recovery opens the previous bundle relative to the retained destination-parent
descriptor and keeps that bundle-root descriptor alive through the final
identity comparison, atomic rollback syscall, and post-swap destination binding
check. A path-based rescan is never rollback authority. An adversarial child
mutation between initial recovery classification and either retained check,
including same-inode mutate-and-restore ABA immediately after the swap,
invalidates the full-tree identity. When both recorded roots still match, the
installer swaps them back, synchronizes the parent, preserves the journal, and
defers; substituted roots are never swapped speculatively.
The incoming name is tied to the transaction identifier. Journal files and
every affected parent directory are durably synchronized around rename and
swap operations. Before the committed record is fsynced, any validation failure
must deterministically swap the old bundle back even if the desktop runtime has
started. Once the committed record and parent directory are fsynced, commit is
irrevocable: later cancellation or cleanup failure never rolls back the new
bundle. Instead the bounded journal and old artifact remain as cleanup-only
recovery state.

Startup recovery runs only inside the same full-operation permit and lease and
resolves at most one contained journal by identity. Before every recovery
mutation it independently proves both desktop host and account-bearing app-
server stopped; active or unavailable runtime evidence defers without forcing
termination. A committed journal performs cleanup only. Journal destinations
must exactly equal an injected allowed application path, normally
`/Applications/ChatGPT.app` or `/Applications/Codex.app`, and sources must be
contained by the exact injected update root. Manifest `appPath` values are
resolved relative to that retained no-follow root and cannot escape it. Bounded
`openat(O_NOFOLLOW)` reads and removals act relative to retained directory
descriptors. Malformed, oversized, substituted, or out-of-bound journals defer
and preserve files for explicit review.

The MainActor coordinator only schedules updater work. Startup scans and
removals, periodic staging maintenance, and safe-quit installation filesystem
work run through one serialized background actor. Results return to the
MainActor for state updates and aggregate logging; coordinator startup never
waits synchronously for cleanup.

## Retention And Recovery

Cleanup recognizes only exact CodexSwitch-owned names. It protects the manifest
selected generation regardless of age while that update is still pending.
It also protects the generation selected by a well-formed pending pointer while
assessment is unavailable; malformed pointers conservatively protect possible
generations for explicit recovery instead of guessing ownership.

After a verified install commit, CodexSwitch preserves exactly one format-2 authoritative
rollback generation: the newest previous installed bundle, paired with immutable
version and full-tree content identity metadata. The previous installed bundle
is freshly validated through the official trust pipeline before its transaction
identity is captured. The moved source is revalidated before preservation, and
its private rollback copy is independently subjected to the same official
validation before that copy's identity is captured. Retained descriptors prove
that the validated roots are the roots subsequently compared and published.
After the private staging directory is moved to its published generation name,
the installer must acquire a new retained descriptor chain from that published
path before the final identity comparison and pointer commit. A retained bundle
whose ancestor path names the former staging location is not publication
authority, even when its open file descriptors still reference the same inodes.

Publishing a newer rollback generation retains one descriptor chain from the
update root through the generation directory and bundle root, writes a unique
no-follow temporary pointer relative to that root, synchronizes the pointer
file, atomically renames it over the pointer, and synchronizes the update-root
directory. Every ancestor-to-child binding in that retained chain is rechecked
before publication, so moving the update root and installing a replacement path
cannot redirect the transaction. The pointer is read back through the same
retained root. Only after
all of those steps and the final retained-bundle comparison succeed may the
former rollback generation be deleted through that root descriptor. The former
generation is itself retained before publication and retirement requires that
the same generation-directory binding still occupies its recorded name;
substitution preserves both trees for review. Failure at
the post-file-sync, post-rename, or post-directory-sync checkpoints preserves
both generations for deterministic recovery. Interrupted rollback copies and
superseded full bundles are temporary artifacts bounded independently by count,
age, and aggregate bytes; cleanup never removes the one authoritative rollback
generation merely because it is old.
Non-authoritative `.staging-*`, `.previous-*`, `generation-*`, and
`.quarantine-*` directories are bounded by scan count, removal count, age,
retained count, and retained bytes. The current retention implementation uses
descriptor-relative `readdir` with a hard top-level budget before sorting and
fails closed without mutation when the budget is exceeded; a persistent
deterministic cursor remains a target improvement. Only exact UUID/numeric
ownership formats are eligible. Identity is rechecked before bounded no-follow
deletion; prefix lookalikes, special files, escaping links, paths outside the
retained update root, and trees exceeding inspection budgets are preserved for
explicit review. Production retention candidate deletion does not use broad
`removeItem` recursion.

Legacy `manual-<numeric-build>` directories are recognized as CodexSwitch
desktop-update artifacts. They are removed only when non-authoritative and
obsolete or past the legacy retention age, subject to the same bounded and
symlink-safe inspection. Unrelated files and directories are never touched.

Interrupted publication is recovered by retaining the current manifest target,
then cleaning or quarantining only proven non-authoritative generations. Cleanup
reports aggregate counts and bytes and does not log every retained generation.

## Subprocess Contract

All updater commands and runtime probes use one updater-owned supervised runner
with a dedicated process group, concurrent nonblocking stdout/stderr drains,
fixed byte, read-count, and drain-time budgets, explicit timeout, and bounded
terminate/kill escalation. The runner closes all inherited pipe descriptors and
retains child and descendant ownership until the process group is reaped; it
never dispatches an unbounded or detached `waitUntilExit`. Saturation and a
surviving descendant therefore fail closed without leaking output memory or
process ownership. Cancellation is reported distinctly from timeout, command
rejection, or an explicit unreaped inconsistency.

## Verification Contract

Deterministic focused tests must use temporary roots, local child processes, and
injected HTTP, runtime, validation, launch, clock, and crash probes. Fixtures
must not target the live home directory or an application under `/Applications`.
Required evidence includes cross-process collisions held at every operation
phase; nested, mismatched, and double permit completion; stale scheduler tasks
at real publication boundaries; committed cleanup failure without rollback;
prepared, swapped, rollback, and cleanup-only journal recovery; runtime-gated
recovery; descriptor substitution; same-inode child mutation and complete-tree
ABA during recovery; immutable rollback replacement and bounded temporary
full-bundle retention; fresh official-trust validation of both the installed
rollback source and its private copy; complete directory, regular-file, relative
symlink, ownership, mode, flags, extended-attribute, and ACL identity changes;
mutation after recovery classification but before the atomic rollback; and
same-inode mutation immediately after the atomic rollback with deterministic
swap-back; rollback-pointer faults after file synchronization, after rename,
and after parent-directory synchronization, with both generations retained and
pointer selection matching the completed durability boundary; update-root
replacement immediately before pointer rename, with the replacement untouched;
former-generation substitution after durable publication, with both the
displaced original and replacement preserved;
valid ZIPs with real local headers plus every hostile ZIP class defined above;
same-inode same-size archive mutation; crash durability; appcast and archive
bounds; stock restore through pending/reassessment/rejection; malformed cache,
ledger, and journal behavior; exact trust command and Security identity stage
ordering; continuous subprocess output and surviving descendants; and bounded
retention name and cursor behavior. The focused test source includes
deterministic temporary-root cases for the transaction slice, including
real child-process lease collisions during download, publication, installation,
and recovery, repeated payload reuse, URL rotation and corrected payloads,
committed cleanup retry through production updater/coordinator entry points,
runtime-gated recovery, and bounded retention.

Trust-stage cases are injected pipeline tests, not end-to-end system tests. They
prove stage ordering and classification through strict verification,
Gatekeeper assessment, and exact OpenAI identity evidence; they do not execute
the host Security.framework or Gatekeeper services. HTTP/cache cases exercise
the production client logic with injected transport and temporary filesystem
state. Live activation additionally requires installed-version, patch-marker,
strict-signing, relaunch, and process-stability evidence.
