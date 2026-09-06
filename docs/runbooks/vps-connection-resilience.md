---
title: VPS connection resilience
description: Fail-closed runtime ownership, resource policy, and non-mutating recovery guidance for CodexSwitch VPS sessions.
toc:
  - VPS Connection Resilience
  - Apply VPS Config Changes
  - Failure Model
  - Observational Check Contract
  - Resource Policy
  - Runtime Convergence Contract
  - Updater Runtime Gate
  - Maintenance Build Contract
  - Recovery Verification
cross_dependencies:
  - crates/codexswitch-cli/systemd/codexswitch.service
  - crates/codexswitch-cli/systemd/codexswitch.service.d/10-maintenance-resources.conf
  - crates/codexswitch-cli/systemd/signul-codex-app-server.service
  - crates/codexswitch-cli/systemd/signul-codex-app-server.service.d/10-runtime-resources.conf
  - crates/codexswitch-cli/src/codex_update.rs
  - crates/codexswitch-cli/src/codex_update/runtime_discovery.rs
  - crates/codexswitch-cli/src/codex_update/generated_systemd.rs
  - crates/codexswitch-cli/src/codex_update/source_patching.rs
  - crates/codexswitch-cli/src/codex_update/source_daemon_patching.rs
  - crates/codexswitch-cli/src/codex_update/source_app_server_template.rs
  - crates/codexswitch-cli/src/codex_update/source_turn_template.rs
  - crates/codexswitch-cli/src/codex_update/transaction.rs
  - crates/codexswitch-cli/src/codex_update/preparation.rs
  - crates/codexswitch-cli/src/bounded_command.rs
  - crates/codexswitch-cli/src/patched_codex.rs
  - scripts/install-linux.sh
  - scripts/lib/observe-managed-systemd.py
  - scripts/lib/observe-managed-daemon.py
  - scripts/lib/install-linux-common.sh
  - scripts/lib/install-linux-activation.sh
  - scripts/manifests/linux-systemd-contract.tsv
  - scripts/codex-vps
  - scripts/vps-codex-restart.py
  - scripts/test_vps_codex_restart.py
  - scripts/build-app.sh
  - scripts/test_codex_vps.sh
  - Tests/Fixtures/RuntimeConvergence/reload-contract-v3.json
  - docs/linux-cli-only.md
  - docs/runbooks/linux-repository-deployment.md
  - docs/runbooks/codex-vps-thread-tools-mcp.md
  - Sources/CodexSwitch/Services/VPSCodexRestartResult.swift
  - Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - Sources/CodexSwitch/Views/SettingsView.swift
  - Tests/CodexSwitchTests/VPSCodexRestartTests.swift
version_control:
  branch: main
  commit: pending
  status: local_uncommitted
  last_updated: 2026-09-06
---

# VPS Connection Resilience

## Apply VPS Config Changes

After editing the VPS `~/.codex/config.toml`, the desktop-facing daemon can be
restarted from CodexSwitch Settings > Linux Devbox Monitor > **Restart VPS
Codex...**. The button first checks the desktop socket's kernel owner, current
managed executable, valid TOML, native `config/read` validation, and idle state
of every loaded task. Returned config values are never displayed. Active or
unknown work blocks the action. The confirmation binds the process identity
and config digest, and both are checked again before shutdown. This is an
explicit operation, not an automatic or scheduled restart. The final idle read
cannot atomically prevent another client from starting work, so do not start
new VPS work while confirming the restart.

The bundled `scripts/vps-codex-restart.py` is sent over the configured SSH
connection and executed without installing or changing the remote helper.
`--check` is read-only and returns a confirmation plan. `--restart` requires
that plan's `--pid`, `--process-start`, and `--config-digest`. The action holds
the shared runtime installation lock and an exclusive restart lock, signals
only the reverified desktop owner through a Linux pidfd with SIGINT, and waits
up to 120 seconds. It never sends SIGKILL to the app-server. Once exit is
proven, it invokes the current patched `codex app-server daemon start` and
verifies a new socket owner plus initialized handshake. This supports legacy
desktop SSH servers that have no native daemon PID record; a bare native
`daemon restart` would refuse those servers and can also force-kill managed
servers, so the UI does not use it.

This restarts the Unix-socket server used by ChatGPT's built-in SSH connection.
It does not restart CodexSwitch account switching, the independent port-8390
service, or local Mac apps. `codex-vps restart` is not equivalent: it targets
the port-8390 service and its bridge instead. Keep task helpers routed to the
desktop Unix socket as specified in the thread-tools runbook.

The UI uses the configured SSH host/user/key/port, snapshots the target when
confirmation opens, disables duplicate requests, and runs the command off the
UI thread. A changed target cancels the pending confirmation. It does not echo
raw remote errors because invalid configuration diagnostics can contain secret
values. Transport uncertainty does not trigger automatic redispatch. A green
result requires the helper's complete `restarted` response with a new process
identity, unchanged config digest, and version. If the outcome is
unknown, inspect VPS readiness before trying again.

The restarted server rereads configuration. Saved task history remains, but
interrupted turns may need to be resumed, and explicit task/model overrides
can still take precedence over config defaults. Reopen the VPS task if the
desktop does not reconnect automatically. Restarting a server is not proof
that every pre-existing task adopted a changed default.

Regression coverage uses fake SSH runners, process identities, and lifecycle
responses, including active tasks, PID/config/socket drift, graceful-stop
timeout, replacement validation, invalid JSON, rejected execution,
missing completion markers, and definite local launch failure. Tests
must not restart the live VPS or require a real config change.

## Failure Model

ChatGPT's built-in SSH remote and the port-8390 `codex-vps` endpoint are
independent transports, but both depend on the VPS remaining schedulable. SSH
keepalives cannot preserve a session when memory and swap are exhausted or the
kernel OOM killer terminates an app-server.

Treat an app-server PID change, a systemd restart counter increase, or an OOM
journal event as a runtime failure rather than a harmless tunnel drop. Verify
the Unix-socket daemon and the port-8390 service independently after recovery.

## Observational Check Contract

`codex-vps --check` and help output are observational. They may probe existing
transport, service health, and version provenance, but they must not create a
tunnel, rewrite thread state, download or install a client, invoke a package
manager, or start, stop, or restart a service.

A Mac/VPS Codex version mismatch is a failed readiness observation, not
authorization to repair. The check reports both versions and this explicit
operator command:

```bash
codex-vps sync-client
```

Only the named `sync-client` command may install the matching Mac remote
client. Run it separately after reviewing the mismatch; never run it merely as
a side effect of a status or help request. The deterministic shell regression
uses mutator and `npm` tripwires to enforce this boundary without contacting the
VPS or changing local client state.

## Resource Policy

The port-8390 app-server receives high CPU and IO weight plus protected low
memory so it wins contention against CodexSwitch maintenance. Its service keeps
an elevated file-descriptor limit and restarts promptly after an actual crash.

The CodexSwitch daemon and its updater children run at lower CPU and IO
priority and use idle-class IO scheduling. The persistent maintenance unit has
`MemoryHigh=4G`, enforceable `MemoryMax=6G`, and `MemorySwapMax=2G`; an update
that cannot complete within those ceilings must fail without changing the
immutable active release.

The checked-in systemd drop-ins are installed and verified only by the
full-SHA `scripts/install-linux.sh` activation transaction. Do not run direct
unit installation, reload, or restart commands as a shortcut, and do not
restart a healthy account-bearing app-server during active work.

The repository-owned app-server unit requests graceful shutdown with
`KillSignal=SIGINT`, uses `KillMode=mixed` so the main process receives that
signal before remaining cgroup processes are cleaned up, and allows
`TimeoutStopSec=120`. `SendSIGKILL=no` forbids systemd from force-terminating
the remaining cgroup when that deadline expires. A timeout is an unresolved
manual-recovery condition: preserve the process and updater journal, inspect
ownership during an approved maintenance window, and do not retry activation
or mutate pointers. These values take effect only after a separately approved
deployment activation. Editing the checked-in unit does not authorize a live
`daemon-reload`, stop, start, or restart.

## Runtime Convergence Contract

Repository-generated local CLI and external app-server runtimes consume only
the nested convergence v3 request in `hotswap-request/<pid>.json`; there is no
generated fallback to `<pid>.nonce` or a flat v1 request. The v3 binding pins
the target process/start identity, kernel executable path/device/inode, runtime
kind, auth-file path/device/inode, stable provider account ID, complete token
fingerprint, request nonce, and issuance timestamp. Its acknowledgement repeats
that exact binding and reports loaded and active fingerprints, auth generation,
and runtime-specific frontend/reconnect evidence.

Readiness is unknown unless all identities converge. Operator-facing evidence
uses the stable non-secret provider account ID rather than relying on email.
Rust and Swift share
`Tests/Fixtures/RuntimeConvergence/reload-contract-v3.json` as the canonical
wire example.

## Updater Runtime Gate

Automatic patched-Codex updates on Linux may check metadata and prepare one
source build with one Cargo job and a three-hour runaway ceiling. The outer
watchdog allows four hours so the inner owner always kills and reaps Cargo and
its compiler descendants first. Before building, the updater writes an atomic
target-provenance record bound to the exact version, upstream commit, patched
source diff, and build recipe. A bounded build failure preserves a matching
target for the next retry; missing, malformed, future-dated, stale, or
different-provenance targets are removed before reuse. Metadata-only ticks
cannot clean or refill that target. A validated generation remains
`ReadyToInstall`; automatic updater ticks never replace the live binary or
activate a runtime, and they reuse rather than duplicate the staged payload.

The explicit `install-prepared-codex` command is also offline-only. Before any
replacement it must prove both the exact repository app-server unit and the
managed app-server daemon are inactive. Inactive is a positive, complete
observation. Systemd must report inactive for the exact loaded fragment and
exact guard-bearing `ExecStart`; exit 4/not-found, failed, timeout, malformed
output, or provenance drift is unknown. Daemon checks bind exact PID/start
identity, device/inode, canonical executable path, argv, socket, and reservation
lock. A hardlink alias, spoofed argv, PID reuse, identity change, missing
executable, failed probe, malformed artifact, or incomplete process scan is
unknown. Active and unknown observations block the operation and leave the
generation staged with a retry instruction. The installer never stops or
restarts either owner. Runtime quiescence and any later start are separately
authorized owner actions after provenance and readiness review.
If a transaction has already published recovery evidence, the
activation journal remains live until a later positively inactive,
provenance-matching recovery completes; an ambiguous owner never authorizes
journal removal.

The systemd app-server holds the shared runtime start/install guard for its
full lifetime. The Codex Unix daemon uses its separate managed-daemon
reservation during startup. The owners can therefore serve concurrently while
remaining independently observable.

That proof is repeated at the commit boundary. Linux installation pre-stages
the runtime and code-mode host in the final directory, then holds an exclusive
`%h/.local/share/codexswitch/runtime-start-install.lock` and exclusive ownership
of `$CODEX_HOME/app-server-daemon/app-server.pid.lock` continuously through the
final systemd/daemon observation, journaled helper and runtime renames, hash and
version readback, updater-state commit, directory sync, rollback-file cleanup,
and journal removal. The repository unit holds the runtime lock in shared mode;
the managed daemon start path uses its separate reservation. An installer owns
both locks exclusively, so a racing start prevents every mutation or waits for
the completed offline replacement. Crash recovery obtains the same two guards
and repeats the typed observation before restoring or completing the recorded
pair.

An `Installed` updater state confirms only the installed-file version. It does
not claim the port-8390 service or Unix-socket daemon was reloaded. Likewise,
same-version file discovery cannot erase an unresolved install or activation
failure, or any other prior `Failed` state and its metadata, left by an older
updater.

Transient `Checking`, `Preparing`, and `Installing` values do not replace that
failure truth. The state file carries typed metadata, preparation, installation,
and activation failure records, including retry metadata and matching install
transaction id. Metadata failure cannot replace an older unresolved failure;
install success clears only its own transaction. The interruption record is
durable before `Installing`, and mutating status reconciliation is serialized
by `codex-update.lock`. Crash replay and concurrent status readers restore
`Failed`, not infer `Installed` from disk.

Automatic macOS checks use the metadata-discovery entrypoint only. They do not
run retention, stale-generation cleanup, pending-target cleanup, deletion,
source checkout, preparation, installation, or activation. Cleanup remains a
preparation or maintenance operation. Absent state uses a pure default
and does not inspect or execute the installed runtime. State is bounded,
regular-file-only, and no-follow; registry bytes are bounded before JSON decode,
including chunked responses.

## Maintenance Build Contract

Never run an unrestricted Rust build on the live VPS. Repository-owned build
paths default to one Cargo job, positive niceness, and idle-class Linux IO.
Ad hoc validation must use the same limits, preferably in a transient user
scope with an explicit memory high-water mark:

```bash
systemd-run --user --scope \
  -p CPUWeight=10 \
  -p IOWeight=10 \
  -p MemoryHigh=4G \
  -p MemoryMax=6G \
  -p MemorySwapMax=2G \
  nice -n 10 ionice -c 3 cargo test --jobs 1
```

If a build requires more memory, move it to a non-live builder rather than
raising limits on the production remote-session host.

## Recovery Verification

After resource exhaustion, verify all of the following without restarting a
healthy runtime:

```bash
ssh signul-vps 'cat /proc/loadavg; grep -E "^(MemAvailable|SwapFree):" /proc/meminfo'
ssh signul-vps 'systemctl --user show signul-codex-app-server.service -p MainPID -p NRestarts -p ActiveState -p SubState'
ssh signul-vps 'curl -fsS --max-time 3 http://127.0.0.1:8390/healthz'
ssh signul-vps '~/.local/share/codexswitch/current/patched-codex/codex app-server daemon version'
```

The daemon version output must match the `current` Codex version, its PID and
Unix socket must identify a running `current` executable, and the port-8390
service must be active and answer its health endpoint. A green result from only
one endpoint does not establish ChatGPT remote readiness. The patched daemon
must not create or update a standalone package generation in the background.
