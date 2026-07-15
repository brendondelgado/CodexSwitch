---
title: Linux repository deployment
description: Reproducible staging, quiescent activation, bounded runtime observation, and rollback for CodexSwitch Linux releases.
toc:
  - Linux Repository Deployment
  - Scope
  - Release Contract
  - Build Provenance
  - Path And Storage Bounds
  - Runtime Artifact
  - Runtime Convergence Contract
  - Patched Codex Updater Safety
  - Preparation Failure Containment
  - Stage
  - Systemd Ownership
  - Exact Systemd Payload
  - Systemd Conflict Gate
  - Knowledge Sync
  - Reader-First Quota Migration
  - Activate
  - Idle Import Handoff
  - Activation Recovery
  - Verification
  - Rollback
cross_dependencies:
  - ../../scripts/install-linux.sh
  - ../../scripts/lib/observe-managed-systemd.py
  - ../../scripts/lib/observe-managed-daemon.py
  - ../../scripts/lib/install-linux-common.sh
  - ../../scripts/lib/install-linux-storage.sh
  - ../../scripts/lib/install-linux-release.sh
  - ../../scripts/lib/install-linux-activation-journal.sh
  - ../../scripts/lib/install-linux-systemd-policy.sh
  - ../../scripts/lib/install-linux-import-transaction.sh
  - ../../scripts/lib/install-linux-systemd-transaction.sh
  - ../../scripts/lib/install-linux-activation.sh
  - ../../scripts/manifests/linux-systemd-contract.tsv
  - ../../scripts/test_linux_resource_policy.py
  - ../../crates/codexswitch-cli/systemd/codexswitch.service
  - ../../crates/codexswitch-cli/systemd/codexswitch.service.d/10-maintenance-resources.conf
  - ../../crates/codexswitch-cli/systemd/signul-codex-app-server.service
  - ../../crates/codexswitch-cli/systemd/signul-codex-app-server.service.d/10-runtime-resources.conf
  - ../../crates/codexswitch-cli/src/codex_update.rs
  - ../../crates/codexswitch-cli/src/codex_update/state.rs
  - ../../crates/codexswitch-cli/src/codex_update/transaction.rs
  - ../../crates/codexswitch-cli/src/codex_update/preparation.rs
  - ../../crates/codexswitch-cli/src/codex_update/retention.rs
  - ../../crates/codexswitch-cli/src/codex_update/runtime_discovery.rs
  - ../../crates/codexswitch-cli/src/codex_update/generated_systemd.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_patching.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_checkout.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_app_server_template.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_turn_template.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_app_server_patching.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_auth_patching.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_websocket_patching.rs
  - ../../crates/codexswitch-cli/src/codex_update/source_patch_helpers.rs
  - ../../crates/codexswitch-cli/src/codex_update/tests.rs
  - ../../crates/codexswitch-cli/src/bounded_command.rs
  - ../../crates/codexswitch-cli/src/patched_codex.rs
  - ../../crates/codexswitch-cli/src/activation.rs
  - ../../crates/codexswitch-cli/src/main.rs
  - ../../crates/codexswitch-cli/src/daemon.rs
  - ../../Tests/Fixtures/RuntimeConvergence/reload-contract-v3.json
  - ../architecture/runtime-and-host-ownership.md
version_control:
  branch: main
  base_commit: 664edf6201fcd7dcdc299084392e3dad510ec9d7
  status: local_uncommitted
  last_updated: 2026-07-13
---

# Linux Repository Deployment

## Scope

This runbook covers repository-owned installation of `codexswitch-cli`, its
immutable patched-Codex runtime, and user systemd definitions. It does not
authorize access to, mutation of, or restart on the live SIGNUL VPS. Run
fixtures locally; stage and activate a real release only in separately approved
operator windows.

Staging and activation are separate transactions. Staging may fetch, build,
publish, and validate one immutable release. It must not change `current`,
`previous`, the public CLI, user systemd state, imported account data, boot
policy, or running processes. Activation has one quiescent commit point for
unit bytes, pointers, optional account import, and optional enablement. It never
stops or restarts a runtime. A separately requested start is allowed only after
that transaction has committed, its journal and private snapshot have been
durably removed, both pre-commit runtime observations were positively inactive,
and the install guards have been released.

## Release Contract

The default layout is:

```text
~/.local/share/codexswitch/
  source/                              # reusable Git source cache
  releases/<cli-version>-<git-sha>/
    codexswitch-cli
    patched-codex/
      codex
      codex-code-mode-host
    systemd/
    release-manifest.tsv
  current -> releases/<cli-version>-<git-sha>
  previous -> releases/<prior-cli-version>-<prior-git-sha>
~/.local/bin/codexswitch-cli -> ~/.local/share/codexswitch/current/codexswitch-cli
```

The public executable always resolves through `current`; activation never
retargets it directly to a release. Every release is named by package version
plus full Git SHA. Reuse is allowed only when the directory name, manifest,
binary versions, source provenance, systemd digests, runtime digests, and patch
marker contract all match.

The build root defaults outside all live paths at
`${XDG_CACHE_HOME:-$HOME/.cache}/codexswitch/build`. The installer rejects a
build root containing `..`, any canonical overlap or nesting with install,
source, binary, systemd, or runtime-input paths, and overlap reached through a
symlink alias.

## Build Provenance

The requested full SHA must be exactly 40 or 64 lowercase hexadecimal
characters and an ancestor of one explicitly approved fetched origin ref. No
uppercase normalization or intermediate 41-63-character form is accepted. The
default is `refs/remotes/origin/main`; override it only with a reviewed
`refs/remotes/origin/...` ref:

```bash
export CODEXSWITCH_GIT_SHA=<full-git-sha>
export CODEXSWITCH_APPROVED_ORIGIN_REF=refs/remotes/origin/main
```

The build runs from a clean detached Git worktree, not a `.git`-less archive.
The installer obtains the package version from Cargo metadata and uses the
commit timestamp as `SOURCE_DATE_EPOCH`. The resulting CLI must report exactly:

```text
codexswitch-cli <package-version> (git <first-12-sha>, built <commit-epoch>)
```

Any `unknown`, `dirty`, version, SHA, or epoch mismatch rejects publication.
Cargo uses one job, positive niceness, idle IO scheduling, and a
`CARGO_TARGET_DIR` below the canonical build root.

## Path And Storage Bounds

The installer independently canonicalizes and rejects aliases for
`releases/`, `cargo-target/`, `worktrees/`, `stage/`, every per-run worktree and
stage path, the shared Cargo target, and the same-filesystem release publish
temporary path. It applies the same check to every nested release directory,
including `patched-codex/`, `systemd/`, and both drop-in directories. A derived
path must remain under its declared root and may not be a symlink or resolve
through a symlink into a live path.

Build execution runs in a transient user systemd scope with explicit
`MemoryHigh`, `MemoryMax`, and `MemorySwapMax`, in addition to one Cargo job,
niceness, and idle IO. Before building, the installer checks available bytes
and current build-root use. It rechecks build-root and staged-release maximums
before publication. The repository Cargo build has a hard 30-minute deadline
and runs in both a named user scope and a dedicated process group under a
subreaping owner. Timeout or an unexpectedly surviving writer kills the whole
scope and process group, reaps descendants, and records local reap proof before
cleanup may remove the shared Cargo target or worktree. If reap proof cannot be
established, those artifacts and the build lock remain in place for manual
review instead of racing a surviving writer. Scope observation is typed as
active, inactive, or unknown; only an exact successful `ActiveState=inactive`
observation can authorize durable reap proof. Query failures, timeouts,
malformed output, and every other state fail closed as unknown. The shared Cargo
target is removed on exit, including failed builds, only after that proof.

Owned build and release retention is bounded by count, age, and total bytes.
Cleanup follows no symlinks and removes only correctly named owner-marked
artifacts. It never deletes the active `current`, rollback `previous`, current
candidate, in-progress build stage, or in-progress publish directory. If
protected artifacts alone exceed a bound, installation fails rather than
deleting them.

Every runtime, release, manifest, and transaction walk enforces deterministic
entry, nesting-depth, byte, and individual-state-file limits while enumerating.
One global entry budget covers each retention inventory, including root,
version, generation, and nested-tree entries. The `max + 1` entry fails before
any deletion or replacement. Eligible artifacts are ordered by `(mtime,
canonical path)` so equal timestamps have a stable result. The installer does
not first materialize an unbounded path or line list. Manifest and transaction
state are read through bounded no-follow descriptors.

Before retention examines any release, both `current` and `previous` must be
absent or exact relative `releases/<version>-<full-sha>` links whose canonical
targets are validated immutable releases below `releases/`. Absolute targets,
extra path components, aliases, and links through symlinked release directories
fail closed before any candidate is removed. Every runtime-input and release
tree is recursively restricted to regular files and real directories. A nested
symlink or special file rejects staging/reuse; cleanup validates the complete
tree before changing a mode and never follows a link while making an owned tree
removable.

Runtime plus VPS-local archive inventory is also bounded by count, oldest age,
and total bytes. The installer reads only filesystem metadata and advisory
lease state beneath the configured runtime root. It never deletes session or
archive files: exceeding any bound fails closed, reports the number of actively
leased objects, and leaves every object untouched. Systemd transaction
snapshots have independent count, age, and byte bounds; only proven abandoned
installer-owned snapshots are eligible for conservative cleanup.

## Runtime Artifact

Each release contains an immutable copy of the patched Codex runtime. Supply a
reviewed input directory and provenance for a new release:

```bash
export CODEXSWITCH_CODEX_RUNTIME_DIR=<directory-containing-codex-and-codex-code-mode-host>
export CODEXSWITCH_CODEX_VERSION=<expected-codex-version>
export CODEXSWITCH_CODEX_SOURCE_SHA=<full-upstream-source-sha>
```

The installer requires regular executable `codex` and
`codex-code-mode-host` files, an exact `codex-cli <version>` response, app-server
help readiness, SHA-256 digests, and the complete current hot-swap marker
contract, including `codex-runtime-storage-leases-v1`. Provenance and both
digests are recorded in `release-manifest.tsv` and rechecked before activation
or any separately requested post-commit start.

The app-server unit executes the immutable runtime through `current` with
`features.local_thread_store_compression=true`. The feature is admitted only
for a lease-capable runtime; active writers retain their lease, and only
inactive stable rollouts enter bounded lossless compression.

## Runtime Convergence Contract

Newly generated local CLI and external app-server runtimes accept only the
canonical convergence v3 request at
`~/.codexswitch/hotswap-request/<pid>.json`. The request has one nested
`binding` containing contract version 3, exact process and kernel executable
identities, runtime kind, exact auth-file identity, stable provider account ID,
complete token fingerprint, request nonce, and issuance generation timestamp.
Generated runtimes do not read the former `<pid>.nonce` request or any flat v1
shape.

An acknowledgement at `hotswap-ack/<pid>.json` repeats the exact binding and
adds acknowledgement time, loaded and active complete-token fingerprints,
frontend delivery evidence, auth generation, and runtime-specific reconnect
readiness. A mismatch in PID/start identity, executable path/device/inode,
auth path/device/inode, provider account ID, nonce, or fingerprint suppresses
the acknowledgement. Status and readiness evidence identifies the provider
account by its stable non-secret account ID; email alone is not runtime
authority. The cross-language fixture is
`Tests/Fixtures/RuntimeConvergence/reload-contract-v3.json`; Rust generation and
decoding and Swift decoding must use that same file.

## Patched Codex Updater Safety

The patched-Codex updater separates metadata discovery, source preparation,
binary installation, and runtime activation. Its automatic policy is explicit
per host platform:

| Platform | Automatic work allowed | Automatic work prohibited |
| --- | --- | --- |
| macOS | Stable-channel metadata checks | Source checkout, build, preparation, binary installation, and runtime activation |
| Linux | Stable-channel metadata checks and one-job bounded preparation | Binary installation and runtime activation |
| Other | Stable-channel metadata checks | Source checkout, build, preparation, binary installation, and runtime activation |

Explicit operator preparation remains available on every supported platform.
Automatic Linux preparation may publish a validated `ReadyToInstall`
generation, but no automatic path consumes that generation. Repeated daemon
ticks leave it staged instead of spawning an install loop.

`install-prepared-codex` is an explicit offline file operation. Immediately
before replacing either runtime binary, it observes both managed runtime
owners:

- the exact `signul-codex-app-server.service` user unit; and
- the managed app-server daemon, using its exact PID, socket, and reservation
  lock artifacts plus exact executable and command-line process identity.

Each observation is typed as active, inactive, or unknown. The shell installer
delegates bounded observation to the repository-owned
`scripts/lib/observe-managed-*.py` helpers and retains guard lifetime, journal
sequencing, and commit orchestration. Active and unknown observations both
block replacement. Inactive requires positive, complete evidence. The systemd
observation binds `ActiveState=inactive` to the exact
loaded fragment and exact `ExecStart` provenance, including the shared
runtime/install guard command. Exit 4/not-found, `failed`, command error,
timeout, malformed output, unloaded or drifted fragments, and drifted
`ExecStart` are unknown. Daemon probes bind the PID start identity, process
device/inode, canonical executable path, and exact argv to the managed runtime;
a hardlink alias, spoofed argv, PID reuse, or identity change is unknown. The
PID, socket, and reservation artifacts must all be absent or positively
inactive. A missing installed executable, malformed or unreadable artifact,
failed probe, or incomplete scan is unknown rather than inactive. The updater
does not use broad process-name matching, and every probe has bounded work,
deadlines, and output.
A blocked install leaves the validated generation `ReadyToInstall` and reports
which owner must be stopped or which observation must be repaired before the
same command is retried.

An inactive snapshot alone does not authorize replacement. On Linux the
installer first copies the prepared runtime and code-mode host to unique temp
files in the final runtime directory. It then acquires, in this order:

1. an exclusive `%h/.local/share/codexswitch/runtime-start-install.lock`; and
2. exclusive ownership of
   `$CODEX_HOME/app-server-daemon/app-server.pid.lock`.

The repository systemd unit executes the foreground app-server under a shared,
no-fork `flock` on `runtime-start-install.lock` and exclusive ownership of
`app-server.pid.lock`. Codex's managed daemon start path owns that same
reservation. Therefore the two runtime owners cannot start together, a start
that wins either lock blocks installation, and a start arriving after the
installer owns both locks waits until commit is complete. With both locks
continuously held, the installer re-observes systemd, PID, socket, reservation,
and exact process identity. It renames the pre-staged files only if that final
observation is inactive, and it releases neither lock between observation and
rename.

After both owners are proven inactive, installation performs one recoverable
two-file transaction. Before the first rename it durably journals the old and
new runtime/helper identities, hashes, expected version, transaction id, and
rollback files. It records each helper rename, runtime rename, runtime version
and helper readback, updater-state commit, and cleanup step. After both renames,
the runtime parent directory must fsync successfully before updater state can
become committed; a file or parent-directory fsync error is fatal and leaves
the journal recoverable. Recovery under the same two continuously held guards
either verifies the committed new pair or restores the complete old pair; it
never accepts a mixed generation. Final updater state is fsynced before the
journal is removed, so interruption at every rename, durability, readback,
state, cleanup, or finalization checkpoint remains replayable. Installation
does not run `systemctl`, restart
the app-server daemon, or choose between two runtime owners. `Installed`
therefore means the expected files were installed offline; it does not mean a
running process reloaded them.

File observation is not activation evidence. Seeing the requested version on
disk must not promote an unresolved same-version `Installing` record or any
prior `Failed` record to `Installed`, clear preparation/install failure fields,
or erase its error. Resolve the failure through an explicit inactive install or
operator review.

Updater state stores typed metadata, preparation, installation, and activation
failure truth separately from transient `Checking`, `Preparing`, or
`Installing` operation status. The record includes its error, version,
transaction id when applicable, failed preparation/install versions, and retry
deadlines. `Installing` is preceded by a durable interruption/transaction
record. Metadata failure never replaces an older unresolved failure. Install
success clears only the matching installation transaction; it cannot clear an
activation, preparation, or unrelated installation failure. Every mutating
installed-file reconciliation runs under `codex-update.lock`. After a crash or
concurrent status request, replay restores the unresolved `Failed` view instead
of inferring successful activation from a same-version file.

Automatic metadata discovery is separate from artifact maintenance. A
metadata-only check may update registry/version state, but it does not run
source/prepared-generation retention, stale-preparation cleanup, pending-target
cleanup, or deletion. Those mutations are limited to explicit preparation and
maintenance paths. A missing state file produces a pure default without
inspecting or executing an installed runtime. Existing state is opened through
a bounded no-follow regular-file descriptor, and registry response bytes are
bounded before JSON decoding, including chunked responses.

## Preparation Failure Containment

The updater must account for the preparation failure observed at
`2026-07-13T21:10:34Z`:

```text
CODEX_AUTO_UPDATE status=failed backoff_hours=6 reason=also failed to clean updater build target after preparation failure: failed to remove build target /Users/brendondelgado/.local/share/codexswitch/codex-source-stable-0.144.3/codex-rs/target: Directory not empty (os error 66): failed to build Codex ... subprocess exceeded its 1800s deadline
```

Automatic macOS work is metadata-only, so it never enters that local build
path. Explicit source preparation has a 30-minute maximum and one Cargo job.
The bounded child must replace its shell with the resource-limited Cargo
command and run in a dedicated process group. Timeout termination kills and
reaps that group, including compiler descendants that can write `target`; no
descendant may continue refilling storage after the updater reports failure.
Target cleanup treats an already-absent tree as success and
retries a transient `Directory not empty` result a small bounded number of
times. A persistent failure remains recorded as pending cleanup and is retried
only by a preparation or maintenance operation, never by a metadata tick or
detached cleanup task.

The same incident window repeatedly logged
`DESKTOP_UPDATE_STAGED version=5211 reason=periodic` from the legacy desktop
updater. The CLI updater does not modify that unrelated desktop path, but its
owned rule is strict: a validated staged generation is keyed by version and
runtime provenance and is reused. Periodic ticks perform zero payload copies
while that generation remains `ReadyToInstall`; they neither create duplicate
generation directories nor refill a cleaned build target.

Generated Mac launchers keep local and remote provenance separate. A local
invocation executes one canonical, non-symlink runtime/helper pair whose exact
SHA-256 values were captured only after the complete hot-swap marker contract
validated. Missing, replaced, stock, partially patched, or helper-mismatched
bytes fail closed with the updater status/repair command; the launcher never
falls through to Homebrew, npm, the desktop bundle, or the synced remote
client. `--remote` delegates only to `codex-vps --remote-client`, which owns the
version-matched synced client path.

## Stage

Choose one reviewed commit and runtime artifact, then dry-run and stage:

```bash
export CODEXSWITCH_GIT_SHA=<full-git-sha>
export CODEXSWITCH_APPROVED_ORIGIN_REF=refs/remotes/origin/main
export CODEXSWITCH_INSTALL_ROOT="$HOME/.local/share/codexswitch"
export CODEXSWITCH_BUILD_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/codexswitch/build"
export CODEXSWITCH_CODEX_RUNTIME_DIR=<reviewed-runtime-directory>
export CODEXSWITCH_CODEX_VERSION=<version>
export CODEXSWITCH_CODEX_SOURCE_SHA=<full-source-sha>

CODEXSWITCH_DRY_RUN=1 scripts/install-linux.sh
scripts/install-linux.sh
```

The second command publishes and validates only. Confirm that `current`,
`previous`, the public CLI target, and systemd files did not change. Do not
raise build concurrency on a live remote-session host; move the build to an
idle window or compatible builder.

## Systemd Ownership

The release owns these complete definitions:

- `codexswitch.service`
- `codexswitch.service.d/10-maintenance-resources.conf`
- `signul-codex-app-server.service`
- `signul-codex-app-server.service.d/10-runtime-resources.conf`

The managed namespace converges to this exact four-file state. Unknown
drop-ins always block. Explicit conflict approval can authorize removal only of
the named legacy `env.conf`, `limits.conf`, `oom.conf`, and
`remote-control.conf` artifacts inside the activation transaction. Known obsolete
CodexSwitch daemon, app-server, and knowledge-sync units must be inactive and
are removed transactionally. Unrelated user units remain untouched.
Obsolete enablement links are part of that namespace, including knowledge-sync
links beneath `default.target.wants/` and `timers.target.wants/`. Their exact
prior symlink targets or absence are journaled and restored on rollback.
Activation also clears pre-existing enablement links for the two target units;
only the explicit enable flags may recreate them after the exact payload has
verified.

Aliases or relationship artifacts using any unit type or dependency directory
are part of the conflict surface. CodexSwitch-named `.socket`, `.path`, timer,
target, service alias, `.wants`, `.requires`, `.upholds`, or other relationship
entry must be either an exact transaction-owned artifact or a blocker. Empty
and global generator/vendor drop-ins are blockers too; absence of directives
does not make an external source acceptable.

Both persistent services have enforceable cgroup ceilings. The maintenance
daemon uses `MemoryHigh=4G`, `MemoryMax=6G`, and `MemorySwapMax=2G`. The
session-bearing app-server keeps `MemoryLow=512M` protection while applying
`MemoryHigh=12G`, `MemoryMax=14G`, and `MemorySwapMax=2G`. Activation verifies
the merged values rather than trusting only the checked-in drop-ins. After
`daemon-reload`, activation also requires `systemctl --user show` to report the
effective numeric `MemoryMax` and `MemorySwapMax` values for both units.

The app-server's merged stop policy must be exactly `KillSignal=SIGINT`,
`KillMode=mixed`, `TimeoutStopSec=120`, and `SendSIGKILL=no`. A graceful-stop
timeout is a failed, operator-owned recovery condition: systemd must not force
terminate the cgroup, and the installer must not retry, stop, restart, or mutate
pointers around it. Inspect the retained process and journal during an approved
maintenance window before taking a separately authorized action.

## Exact Systemd Payload

The release manifest names the complete systemd payload. It contains exactly
four regular files and their SHA-256 digests:

- `codexswitch.service`
- `codexswitch.service.d/10-maintenance-resources.conf`
- `signul-codex-app-server.service`
- `signul-codex-app-server.service.d/10-runtime-resources.conf`

Missing files, symlinks, extra files, extra directories, wildcard matches, or
an unmanifested payload reject the release. Activation installs only these
four exact paths; it never discovers install candidates with a wildcard.

## Systemd Conflict Gate

Activation snapshots the previous managed-unit namespace, stages all four
replacement files on the systemd directory's filesystem, installs the exact
target, runs `daemon-reload`, then inspects `systemctl --user cat` for both
merged units before moving pointers.
The source headers, effective `FragmentPath`, and effective `DropInPaths` must
name only the repository-owned unit and one expected drop-in below the user
systemd directory. Effective forward, reverse, ordering, propagation, trigger,
alias, and install relationship properties are queried with `systemctl show`;
unexpected relationships fail even when no textual directive appears in
`systemctl cat`.
The conflict gate treats every execution and identity directive, environment
or credential input, CPU/NUMA control, memory/OOM control, IO/block-IO control,
task or resource limit, timeout/restart/watchdog/start-limit control, and
security/sandbox/capability/network-path restriction as owned behavior.
Every systemd dependency, ordering, and lifecycle-propagation family is owned.
This includes `Requires*`, `Wants*`, `Requisite*`, `BindsTo`, `PartOf`,
`Upholds`, `Conflicts`, `Before`, `After`, `OnFailure*`, `OnSuccess*`,
`Propagates*`, `*PropagatedFrom`, `JoinsNamespaceOf`, mount dependencies,
default-dependency controls, isolation controls, and manual start/stop
refusals. Only dependencies present in the exact four-file payload may appear.
Every merged directive is classified: unknown sections, unknown keys, empty
resets, and values without an exact manifest expectation are conflicts.
Any unknown managed drop-in blocks activation and cannot be approved away;
only the explicit legacy artifact allowlist is removable.
Either target service, the managed app-server daemon, or any known
legacy/conflicting unit being active always blocks and cannot be approved away.
Unknown activity also blocks. Every service activity probe must return the
single positive-inactive result: `systemctl --user is-active` exits `3`, writes
exactly `inactive`, and writes no diagnostic output. Exit `0`, every other exit
status, `failed`, `unknown`, malformed or mixed output, and command failure all
block. Quiesce the unit through its owner before activation;
the bounded systemd observer accepts `inactive` only when the exact managed
fragment and `ExecStart` match and `MainPID` is exactly zero.
The one first-install exception is a positively absent managed unit. A missing
fragment is inactive only when `lstat` reports `ENOENT` and one complete,
successful `systemctl show` response reports `LoadState=not-found`,
`ActiveState=inactive`, an empty `FragmentPath`, an empty `ExecStart`, and
`MainPID=0`. A missing fragment paired with any loaded, failed, partial,
malformed, nonzero-PID, or command-error response is unknown and blocks before
mutation. Once the fragment exists, the normal exact fragment and `ExecStart`
contract always applies.
The daemon observer has the matching first-install exception only while the
validated `current` pointer is absent. In that mode an absent runtime may be
inactive only after the reservation lock is obtainable, PID and socket
artifacts are absent, and a bounded owner-only process scan finds no exact
managed runtime argv. An exact managed argv is active even if its executable
has since disappeared. Any owned process whose `argv[0]` names that absent
managed runtime but whose remaining arguments differ is unknown, never
unrelated. Without that explicit first-install mode, a missing runtime remains
unknown.

After the initial positive-inactive observations and acquisition of both
runtime guards, activation writes one token-bound condition drop-in for every
target and known legacy unit beneath the user manager's high-priority runtime
control directory. The condition is false while the exact activation lock
exists. Activation then runs `daemon-reload`, proves every barrier appears in
the unit's effective `DropInPaths`, and repeats all activity observations before
the first journaled mutation. A late start is therefore skipped by systemd; a
start that won before the barrier is active is caught by the second observation.
The barriers stay loaded through rollback or commit and journal cleanup. They
are removed, followed by another successful `daemon-reload`, only while both
runtime guards remain held. Barrier creation never stops, restarts, enables, or
disables a unit. An active or unknown unit still blocks.

Each barrier contains the activation-lock PID/start identity/token and has one
exact repository-owned pathname and byte representation. Existing, linked,
malformed, foreign-token, partially installed, or manager-invisible barriers
block for manual review. A crash may leave a valid barrier in place as a
fail-safe start inhibition; it is never guessed away by an unrelated run.

The installer never stops an active session on the operator's behalf. An
unrecognized CodexSwitch- or Codex-app-server-named unit file also blocks; it is
never silently adopted or deleted.

An operator may proceed only after reviewing the exact merged output and
explicitly accepting the conflict:

```bash
CODEXSWITCH_ACTIVATE=1 \
CODEXSWITCH_APPROVE_SYSTEMD_CONFLICTS=1 \
scripts/install-linux.sh
```

This approval removes explicitly recognized on-disk managed artifacts
transactionally and does not authorize a restart or any merged directive
conflict. Every dependency, ordering, mount-coupling, and propagation directive
always fails closed when it differs from the manifest, even when approval is
set. `daemon-reload`, merged-unit verification, or effective-resource
verification failure rolls back the prior unit bytes, symlink targets, and
absences before any pointer movement.

## Knowledge Sync

No knowledge-sync systemd unit or timer is installed. The current VPS-side
command has no distinct remote mirror endpoint: pointing both endpoints at
`/home/signul/codexswitch-secure-files/knowledge` is a rejected same-path
no-op. A replacement needs a separately reviewed two-endpoint contract,
conflict handling, and a cadence measured in minutes.

Activation refuses an active obsolete knowledge-sync service or timer and
removes the inactive exact pair as part of the managed transaction. The target
never preserves or republishes those obsolete units. Unrelated timers are not
eligible for cleanup.

## Reader-First Quota Migration

Treat quota persistence changes as expand-and-contract migration:

1. Inventory every reader, including daemon, CLI/status, Mac mirror, and
   operational scripts.
2. Stage a release that accepts existing and new representations while writers
   continue emitting the existing format.
3. Activate readers one at a time after fixture proof for both formats.
4. Enable a new writer only after every reader is compatible and a backup plus
   rollback checkpoint exists.
5. Retire old-format reading only in a later release after fleet and stored
   data convergence.

Publication and activation do not authorize a quota writer migration.

## Activate

Activation is explicit and serialized by a repository-owned activation lock:

```bash
CODEXSWITCH_ACTIVATE=1 scripts/install-linux.sh
```

Before pointer movement, activation validates the candidate, existing
`current`, existing `previous`, permanent public CLI link contract, merged
systemd state, and patched-runtime readiness. It snapshots every managed unit
entry, recording both present bytes and exact absence, stages replacements on
the same filesystem, and writes and fsyncs an activation journal containing
that snapshot plus the exact old `current`, `previous`, and public-link state
before changing units or pointers. When import is requested, the same private
transaction snapshots exact bytes, mode, and absence for the configured account
store, its lock file, and Codex auth file. Existing activations atomically
replace only `current`; the permanent public CLI follows it without retargeting.
First activation creates the public link as part of the same recoverable
transaction. Only after `current` and the public invariant verify does
activation record the old current as the new rollback pointer.

Before any unit or pointer mutation, activation performs bounded typed
observations of the exact loaded systemd owner and managed daemon. It then
acquires both the exclusive runtime/install guard and exclusive daemon
reservation guard, repeats every observation, and rejects anything except
positive inactivity. The two guards remain continuously held through unit and
pointer commit, state and journal fsync, snapshot cleanup, and journal removal.
A concurrent systemd or daemon start that wins a guard causes zero pointer,
unit, start, stop, or restart actions. A start arriving after activation owns
the guards waits until the committed transaction has completed cleanup.

The installer does not open either guard with shell redirection. A dedicated
holder opens each final component relative to an already opened parent using
`O_NOFOLLOW`, proves it is one regular file, acquires the advisory lock, and
reports the descriptor's device/inode identity. The holder retains both
descriptors and continuously checks the absolute path against those identities.
Activation repeats that proof after systemd replacement and immediately before
transaction commit. A symlink, unlink, parent replacement, or same-name inode
replacement fails closed and drives the normal journal rollback; a different
inode can never be accepted as the guard held for the transaction.

An activation invocation acquires the activation lock and completes any
pending journal recovery before it validates release pointers or runs release
retention. A stale journal can therefore never be treated as a malformed
pointer state or allow retention to inspect half-activated pointers.

The journal and systemd snapshot remain durable while requested enable and
file-only import preparation actions run. Enablement-created `.wants` links are
managed snapshot entries. A failed enable or later action restores their exact
old targets or absence. Import runs last while both runtime owners are proven
inactive; it may commit and verify account/auth files only through an explicit
offline `FileOnly` activation path. It must not attempt runtime reload, convert
zero targets into success, or publish `Confirmed`. Any preparation failure
restores the exact pre-import account/auth/lock state. Only then is the
deployment committed phase fsynced, the snapshot cleaned, and the journal
removed while both runtime guards remain held.

The activation lock itself is a complete owner record (PID, process-start
identity when available, and random token). Build locks use the same
PID/start-identity/nonce proof and are reclaimed only after all fields validate
and that exact owner is dead. They are never reclaimed from a dead PID alone.
The activation lock is fsynced as a same-directory
candidate and published with an atomic no-replace hard link while a short
filesystem mutex serializes publication and stale-owner reclamation. A crash
cannot publish an ownerless lock, and abandoned pre-publication candidates are
removed only while that mutex is held. If an owner dies before the activation
journal exists, the next activation can prove the owner is gone, remove only
its exact PID-owned partial systemd snapshot, and acquire a fresh lock. An
ownerless or live-owner lock is never reclaimed.

Each systemd transaction also carries a random generation and an HMAC owner
manifest bound to its exact directory, PID/start identity, activation token,
and installer-owned key. Retention deletes only snapshots whose strict owner
manifest and signature validate. A directory that merely matches the name or
contains `state.tsv` is not owned; missing or invalid evidence remains in place
and blocks automatic cleanup for manual review.

## Activation Recovery

Any ordinary unit, reload, verification, pointer, enable, or import failure
restores the previous managed units, boot links, import files, and all three
historical pointer states from the journal, including prior absences and the
pre-existing `previous`. Recovery never changes runtime activity. A process
crash may leave the journal and activation lock on disk. The next explicit
activation detects a dead lock owner, acquires the activation lock and both
runtime guards, obtains a second positive inactive observation, validates every
recorded managed target, restores and reloads the old unit state, fsyncs the
managed directories, restores import files, removes the journal, and then
starts a fresh transaction. If either owner is active or unknown, recovery
leaves every unit, pointer, snapshot, and journal untouched for manual review.

Recovery itself is restartable. If recovery is interrupted, the journal stays
present and the next activation retries from the same old state. Fault fixtures
cover post-lock/pre-journal crashes, partial snapshot crashes, first activation,
after-current, after-previous, crash recovery, enable failures,
enablement-link restoration, inactive-service preservation, import-state
restoration, concurrent start attempts, and rollback to a prior release.

Before the first recovery mutation, the installer validates the complete
journal, old public target, all pointer targets, every systemd state row and
snapshot entry, import state and generation receipt, and every bounded regular
snapshot file. Restore copies use no-follow descriptors and recheck opened
inode identity; a malformed or linked recovery payload leaves units, pointers,
imports, and the journal untouched.

Enable actions are independent and require activation in the same invocation:

```bash
CODEXSWITCH_ACTIVATE=1 CODEXSWITCH_ENABLE_DAEMON=1 scripts/install-linux.sh
CODEXSWITCH_ACTIVATE=1 CODEXSWITCH_ENABLE_APP_SERVER=1 scripts/install-linux.sh
```

A one-shot post-commit start must be named explicitly and is valid only for a
unit proved inactive by both pre-commit observations:

```bash
CODEXSWITCH_ACTIVATE=1 CODEXSWITCH_START_DAEMON=1 scripts/install-linux.sh
CODEXSWITCH_ACTIVATE=1 CODEXSWITCH_START_APP_SERVER=1 scripts/install-linux.sh
```

Every invocation above must retain the reviewed
`CODEXSWITCH_GIT_SHA=<full-40-or-64-character-sha>`, approved origin ref, and
runtime provenance from staging. An encrypted account import is also an
activation action and requires an immutable bundle digest. The installer passes
the anchored bundle to `codexswitch-cli import --offline-file-only`; the command
must return only after durably publishing an `Import`/`FileOnly` barrier. A
file-only preparation without requested starts is reported as pending runtime
convergence, never as a converged import:

```bash
CODEXSWITCH_ACTIVATE=1 \
CODEXSWITCH_IMPORT_BUNDLE=<reviewed-bundle.csbundle> \
CODEXSWITCH_IMPORT_BUNDLE_SHA256=<full-64-character-sha256> \
scripts/install-linux.sh
```

To complete the import in one installer invocation, explicitly request both the
managed app-server target and the daemon that reconciles its barrier:

```bash
CODEXSWITCH_ACTIVATE=1 \
CODEXSWITCH_IMPORT_BUNDLE=<reviewed-bundle.csbundle> \
CODEXSWITCH_IMPORT_BUNDLE_SHA256=<full-64-character-sha256> \
CODEXSWITCH_START_APP_SERVER=1 \
CODEXSWITCH_START_DAEMON=1 \
scripts/install-linux.sh
```

Direct CLI import/update commands, direct `systemctl enable`/`restart`, public
binary copying, and mutable runtime installers bypass this transaction and are
not deployment procedures. Runtime-building helpers may prepare an input
artifact only.

Enable changes boot policy without starting a unit. The installer rejects the
obsolete `CODEXSWITCH_RESTART_DAEMON` and `CODEXSWITCH_RESTART_APP_SERVER`
flags. A reviewed invocation may instead request one post-commit `start` of a
unit that both observations proved inactive. That start is outside the
activation journal, occurs only after guard release, and is never attempted
after an active, unknown, failed, interrupted, or rolled-back commit. It does
not stop or restart any owner and cannot roll back an already committed offline
release. Readiness verification remains an operator observation, not a commit
mutation.

## Idle Import Handoff

Idle import is a two-step operation, not one in-process reload transaction:

1. During quiescent activation, prepare and verify account/auth files through
   an explicit offline file-only import. The durable activation record remains
   `Import`/`FileOnly` and retains its target identity, complete fingerprint,
   and owned generations.
2. After a separately requested service start, reconcile that exact barrier
   against a live managed runtime. Only a matching convergence-v3 ACK may
   publish `Confirmed`; absent, partial, stale, or mismatched evidence remains
   degraded and blocks normal mutation.

The installer pins the immutable identity of the just-created barrier before
committing its own activation journal. When both post-commit starts are
requested, it starts the managed app-server before the daemon, then waits for
that exact `Import` barrier to become `Confirmed`. A different target,
generation, fingerprint, kind, or prior-account identity is not convergence.
Timeout, malformed state, `ManualReview`, or a mismatched barrier makes the
installer exit nonzero and suppresses the converged-activation success message.

The installer opens and hashes the reviewed bundle through a no-follow
descriptor, copies those exact bytes into the private transaction while
preserving the `.csbundle` suffix, and passes only that anchored copy to the
CLI. The CLI imports into transaction-local account, activation, and auth
files; it never mutates the canonical files directly. The installer snapshots
the canonical files under `accounts.json.lock`, records their exact
generations, and releases the lock while the isolated import runs. It then
reacquires that lock and compares every canonical generation with the snapshot
before publishing anything. Any intervening writer makes the compare fail and
is preserved.

One uninterrupted exclusive-lock interval covers the successful compare,
preparation of every replacement, canonical publication, directory fsyncs,
post-publication generation reads, and the durable ownership receipt. There is
therefore no snapshot-to-import overwrite window and no import-to-receipt
misattribution window. A failed isolated import records only the unchanged
before generations; it does not publish partial CLI output.

All canonical snapshot, commit, receipt, and rollback operations are rooted at
a no-follow descriptor for the reviewed HOME. Each existing path component
must be an effective-user-owned directory. The transaction records the device
and inode of each canonical parent created or opened for the operation, then
re-resolves and compares those identities before mutation. A renamed,
replaced, linked, special, unowned, or otherwise unanchored parent is an
ownership loss: no canonical target is changed and the activation journal is
left for manual recovery.

The transaction snapshots the canonical lock's prior presence, mode, and bytes
before using it. Successful import leaves the canonical lock available for
future account writers. Rollback restores a previously present lock in place
or removes an installer-created lock when it was previously absent, after all
account/auth restoration has completed. Rollback restores canonical files only
when their current generations still equal the installer-owned receipt (or the
unchanged before generations when publication never occurred); a later writer
is never overwritten.

The CLI side of this handoff is deliberately lead-owned. The installer depends
on these exact wiring points and does not reproduce them in shell:

- `main.rs`: expose `import --offline-file-only` and
  `update-bundle --offline-file-only`, pass the option through
  `import_accounts`, and require a `FileOnly` result instead of calling
  `require_confirmed_activation` for the deployment preparation path.
- `activation.rs`: give `replace_accounts_with` and its dependency-injected
  implementation an explicit reload policy; after durable store/auth readback,
  persist the existing import record as `ActivationKind::Import` plus
  `ActivationState::FileOnly` without invoking reload or discarding ownership
  evidence.
- `daemon.rs`: reconcile an `Import`/`FileOnly` barrier immediately after the
  managed runtime starts, before normal rotation, and require verified v3
  convergence before allowing the barrier to become `Confirmed`.

## Verification

Before activation, inspect the staged release directly without using current:

```bash
release="$HOME/.local/share/codexswitch/releases/<version>-<sha>"
cat "$release/release-manifest.tsv"
sha256sum "$release/codexswitch-cli" "$release/patched-codex/"*
"$release/codexswitch-cli" --version
"$release/patched-codex/codex" --version
```

After separately authorized activation:

```bash
readlink "$HOME/.local/share/codexswitch/current"
readlink "$HOME/.local/share/codexswitch/previous"
readlink "$HOME/.local/bin/codexswitch-cli"
systemctl --user cat codexswitch.service
systemctl --user cat signul-codex-app-server.service
```

After a separately authorized post-commit start, verify the expected PID and
endpoint without broad process termination:

```bash
systemctl --user show signul-codex-app-server.service \
  -p MainPID -p ActiveState -p SubState -p NRestarts
curl -fsS --max-time 3 http://127.0.0.1:8390/healthz
```

## Rollback

Rollback is activation of the already published prior release. Read and record
the prior manifest first, then invoke the installer with that release's source
SHA and explicit activation:

```bash
root="$HOME/.local/share/codexswitch"
rollback_release="$(readlink -f "$root/previous")"
cat "$rollback_release/release-manifest.tsv"

export CODEXSWITCH_GIT_SHA=<rollback-manifest-git-sha>
CODEXSWITCH_ACTIVATE=1 scripts/install-linux.sh
```

The same lock, typed inactivity observations, dual runtime guards, and
candidate/current/previous validation apply. The failed release becomes
`previous`, while the permanent public CLI link follows the newly restored
`current`. Verify the offline runtime and quota readers before considering
rollback complete; runtime start remains a separate explicit action.

If the activation included an idle import, recovery first validates the
transaction-local bundle and snapshots, pins each canonical parent back to its
recorded HOME-relative device/inode identity, and acquires the canonical
account lock. It restores account, activation, and auth bytes only when the
current generations remain installer-owned. The ownership receipt is written
while that lock is still held. Finally, recovery restores the lock file's own
prior bytes and mode or its prior absence. Parent replacement, lock identity
replacement, generation drift, or an unresolved fsync leaves the journal in
place and preserves the newer state for manual review.
