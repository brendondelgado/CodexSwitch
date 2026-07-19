---
toc:
  - CodexSwitch Hot-Swap Verification Runbook
  - Why This Exists
  - Readiness Contract
  - Swap Commit Contract
  - Rust Runtime Handoff Evidence
  - Rust Activation Barrier Recovery
  - Platform Gates
  - Unified ChatGPT Desktop Bundle
  - Desktop Bridge Verification
  - CLI Update Storage Safety
  - Desktop Update Ownership
  - Account State Boundaries
  - Manual Account Controls
  - Menu App Process Boundaries
  - Quota Snapshot Validity
  - Runtime Blockers and Reauth
  - Quota Polling Cadence
  - Mac Menubar VPS Freshness
  - Pool Capacity Math
  - Candidate Selection
  - Transient VPS Readiness Blips
  - Verification Checklist
  - Regression Requirements
  - Incident Review Questions
cross_dependencies:
  - docs/architecture/quota-and-reset-policy.md
  - docs/architecture/runtime-and-host-ownership.md
  - crates/codexswitch-cli/src/readiness.rs
  - crates/codexswitch-cli/src/reload.rs
  - Sources/CodexSwitch/Services/CodexManagedRuntimeTrust.swift
  - Sources/CodexSwitch/Services/SwapEngine.swift
  - crates/codexswitch-cli/src/codex_update.rs
  - crates/codexswitch-cli/src/daemon.rs
  - crates/codexswitch-cli/src/quota.rs
  - crates/codexswitch-cli/src/account_store.rs
  - crates/codexswitch-cli/src/patched_codex.rs
  - scripts/install-macos-cli-artifact.sh
  - Sources/CodexSwitch/Services/UsageResponseParser.swift
  - Sources/CodexSwitch/Services/KeychainStore.swift
  - Sources/CodexSwitch/Services/SwapEngine.swift
  - Sources/CodexSwitch/Services/CodexVersionChecker.swift
  - Sources/CodexSwitch/Services/CLIStatusChecker.swift
  - Sources/CodexSwitch/Services/DesktopAppConnector.swift
  - Sources/CodexSwitch/Services/CodexDesktopBridgeKeepAlive.swift
  - Sources/CodexSwitch/Services/DesktopRuntimeReloadClient.swift
  - Sources/CodexSwitch/App/AppDelegate.swift
  - Sources/CodexSwitch/Models/AccountManager.swift
  - Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - Sources/CodexSwitch/Services/SingleInstanceLock.swift
  - Tests/CodexSwitchTests/SwapEngineTests.swift
  - Tests/CodexSwitchTests/CLIStatusCheckerTests.swift
  - Tests/CodexSwitchTests/LinuxDevboxMonitorTests.swift
  - Tests/CodexSwitchTests/SingleInstanceLockTests.swift
  - Tests/CodexSwitchTests/CodexVersionCheckerTests.swift
  - Tests/CodexSwitchTests/DesktopRuntimeReloadClientTests.swift
  - Tests/CodexSwitchTests/DesktopStatusTests.swift
  - Tests/CodexSwitchTests/AccountCardViewTests.swift
  - Tests/CodexSwitchTests/PopoverUXTests.swift
  - Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - Sources/CodexSwitch/Services/CodexDesktopAppLocator.swift
  - Sources/CodexSwitch/Services/CodexDesktopAppUpdater.swift
  - scripts/patch-asar.py
  - scripts/build-app.sh
  - scripts/test_patch_asar.py
  - Tests/CodexSwitchTests/DesktopRuntimeHotSwapStateTests.swift
  - docs/linux-cli-only.md
  - docs/sighup-safety.md
version_control:
  branch: main
  commit: pending
  last_updated: 2026-07-19
---

# CodexSwitch Hot-Swap Verification Runbook

## Why This Exists

CodexSwitch previously reported hot-swap readiness from weak evidence: patched marker strings, a running process, and a successful `SIGHUP` send. That missed the real failure mode: the live Codex app-server could keep using an old cached auth manager even after CodexSwitch wrote a new `auth.json` and signaled the process.

The lesson is blunt: **installation is not behavior**. A green state is only honest after the live target proves it observed the swap.

## Readiness Contract

A Codex runtime is hot-swap ready only when all three facts are true:

1. **Store state:** CodexSwitch has an active account selected and at least one usable fallback account.
2. **Auth file state:** `~/.codex/auth.json` matches CodexSwitch's active account token source.
3. **Runtime state:** each live Codex runtime has acknowledged a reload after the latest swap signal.

Marker strings such as `sighup-verified` and `SIGHUP: auth reloaded` are necessary but not sufficient. They prove the binary was patched; they do not prove the running process loaded the new token.

Every acknowledgement identifies its `runtimeKind`; the signaler validates the
contract expected for the discovered process rather than accepting whichever
contract the acknowledgement claims. Both contracts require the exact request
nonce and matching independently loaded and active auth fingerprints.

An external ChatGPT desktop app-server uses the strict `external-app-server`
contract. It must successfully parse the current auth source, prove that the
newly cached auth fingerprint matches the independently parsed `auth.json`
fingerprint, and deliver `account/updated` to at least one initialized frontend
writer. Merely accepting a broadcast into the app-server's internal queue is not
delivery. This proof is ACK contract version 3 and is advertised by the
`codexswitch-hotswap-contract-v3` capability marker together with
`codexswitch-runtime-convergence-v3` and
`codexswitch-runtime-rotation-handoff-v1`. Reloading the Rust backend
without notifying the renderer leaves the visible account and React Query caches
stale. Desktop readiness therefore requires the runtime marker for this full
contract; a historical `desktop-auth-watcher-ready` file is not live evidence.
The ASAR auth callback must also contain the current versioned cache-invalidation
marker. A bare `_invalidateAccountQueries` function name is not sufficient: the
July 19, 2026 renderer incident placed that helper inside a lazy initializer while
calling it from module scope, producing an unhandled `ReferenceError`, provider
unmount, renderer remount, and lost composer text. Reject and migrate that unsafe
generation before launching the desktop app.
An auth-only reload while no initialized frontend is connected does not satisfy
this strict proof. Run a same-account canary with an initialized client attached
and require a version 3 ACK whose nested binding matches the request, whose
frontend delivery evidence is positive, and receipt of the `account/updated`
notification before declaring the external runtime ready.

A local interactive CLI embeds an in-process app-server but has no desktop
renderer writer. Its `local-interactive-cli` acknowledgement may complete after
the verified auth reload and must report the active auth generation plus
reconnect readiness. It advertises `codexswitch-hotswap-cli-contract-v3` plus
the shared convergence and rotation-handoff markers, reports no completed
frontend write, and may send `account/updated` to the TUI only as a best-effort
notification. A closed in-process outgoing channel identifies a stale handler:
that handler must exit before reading the request. The bounded request remains
available for the live handler and the injected-turn binding.

A typed usage-limit response from the active runtime is authoritative over a
separate quota poll. The in-turn retry path must mark that account temporarily
unusable and select a ready replacement even when the usage endpoint still
reports apparent headroom; otherwise the retry repeats with credentials the
runtime has already rejected.

## Swap Commit Contract

CodexSwitch distinguishes the configured account from the account proven active
inside each runtime. Writing auth.json and selecting an account in accounts.json
establishes only configured state. The menu must not label that account current,
emit SWAP_COMPLETED, or send a success notification until all required live
local runtimes acknowledge the same account and complete token fingerprint.

A swap is transactional across these boundaries:

1. The account-store update must be durably writable. A disk-full or lock/write
   failure aborts the swap before success is published.
2. auth.json must be written atomically and read back as the intended account.
3. Each discovered account-bearing runtime must either acknowledge the new auth
   generation or be reported explicitly as restart-required.
4. Status and quota observations from an older swap generation must not be
   allowed to overwrite the current generation.

CLI swap and rotate commands must exit unsuccessfully when any discovered
runtime is reported as skipped or unacknowledged. Writing auth state is not a
successful hot swap, and callers must be able to distinguish configured state
from runtime convergence using the process exit status.

If `swap` blocks while `lslocks` shows the daemon owning
`accounts.json.lock`, inspect the daemon journal before retrying. Runtime ACK
waits and provider polling must not own that lock. Repeating
`CommittedDegraded` messages with zero verified ACKs indicate a convergence
barrier, not permission to retry immediately; stop the faulty daemon, preserve
the activation journal for evidence, and keep configured state distinct from
the account actually loaded by the runtime. Confirm quota with a fresh poll
before selecting a replacement, because a cached 100-percent observation can
outlive the provider's real allowance.

The desktop JSON-RPC fallback verifies `account/login/start` with a subsequent
`account/read`. Codex 0.144.1 does not return `chatgptAccountId` from that read;
it returns an optional ChatGPT email and plan. Verification therefore requires
a ChatGPT account, compares normalized email when both sides provide one, and
compares canonical meaningful plan tiers. It must not claim that account ID was
verified by this endpoint.

When convergence is incomplete, the UI must show configured and runtime state
separately. Healthy quota for the configured account is not evidence that a
still-running CLI or desktop process stopped using the prior account.

## Rust Runtime Handoff Evidence

For a Rust CLI swap, daemon rotation, import activation, or rotation injected
from a running Codex turn, require all of the following in one attempt:

1. The durable activation record names the intended store generation and full
   token fingerprint.
2. The reload request contains the exact configured absolute auth path. A
   missing runtime binding is a hard failure; it does not authorize the default
   `~/.codex/auth.json` path.
3. At least one expected live runtime is signalled, every expected target ACKs,
   and each ACK matches PID/start identity, nonce, auth path, and both loaded and
   active fingerprints.
4. An injected turn parses the CLI's structured result, proves the same auth
   path and fingerprint, and performs an independent verified reload of its
   `AuthManager` before retrying.

The injected turn must derive its current start identity from the operating
system, then match a fresh local-interactive-runtime ACK to the still-present,
bounded request file by contract version, nonce, start identity, auth path, and
expected fingerprint. It must recompute the complete fingerprint from the
current no-follow auth descriptor before launching rotation. PID equality or a
nonempty cached ACK alone is not binding evidence.

`signaled = 0`, an empty default summary, or a file-only commit is not a hot
swap. A manual offline operation reports `FileOnly` explicitly. Daemon and
automatic paths keep the activation pending/degraded and return failure until
runtime convergence is proven.
An older unresolved `FileOnly` record remains a hard pre-policy barrier even
when a new command was launched with reload disabled. Verify that quota polls,
banked-reset reads or redemption, replacement selection, and newly targeted
success output all remain absent until that older record converges.

Import verification begins from a prepared, validated bundle that has not yet
changed the account store. Test failure injection after store commit, during
auth write, and after process interruption. In each case, the exact pre-import
store/auth state must be restored only when the transaction still owns the
committed generation; a CAS mismatch must preserve concurrent state and leave
durable manual-review evidence.

Use `import --offline-file-only` or `update-bundle --offline-file-only` only
after repository deployment has positively proved the managed runtime idle.
That command must publish an `Import/FileOnly` barrier without calling reload.
After startup, reconcile the same target to `Confirmed` before declaring the
deployment active. Interactive imports retain live convergence by default.

## Rust Activation Barrier Recovery

When a patched Codex turn logs `automatic activation is blocked by a durable
manual-review record`, inspect the activation record and current store/auth
identity before touching either credential file. A token fingerprint can change
during a normal refresh while the stable provider account remains unchanged.

The CLI automatically repairs only the historical false-positive record whose
rotation kind and exact bounded reason identify the old degraded-token mismatch.
Repair additionally requires exactly one active store account, the same stable
provider target named by the record, and an exact match between that account's
complete current token set and `auth.json`. It then retries verified convergence
for the durable target before performing the newly requested rotation. Generic,
corrupt, cross-account, missing-target, or store/auth-divergent manual-review
records remain blocked without signalling or writing credentials. Version and
kind must be explicitly present as v3 rotation evidence; compatibility defaults
never authorize repair. The coordinator repeats store-generation and complete
auth readback after the ACK, and import is blocked behind the same convergence
barrier before replacement bytes can be written.

The regression proof requires two reload acknowledgements for a cross-target
request behind a repaired barrier: one for the durable current target and one
for the selected replacement. The final activation record must be `Confirmed`
for the replacement. Never delete the journal merely to make rotation continue.

Promote a reviewed Mac runtime artifact with
`scripts/install-macos-cli-artifact.sh <artifact-directory>`. The helper
independently verifies GitHub build attestations, the exact four-file manifest,
all hashes, thin arm64 identities, and code signatures before it executes the
artifact control plane. That control plane performs one updater-lease-held,
journaled three-binary activation and route publication transaction. It does
not signal, restart, or quit the currently running Codex process; exit and
resume once after activation to enter the new runtime.

## Platform Gates

CodexSwitch must evaluate these independently:

- **Mac desktop:** official OpenAI signing and plugin health are separate from desktop hot-swap. The desktop status must not show green unless the live desktop runtime acknowledges reload.
- **Mac local CLI:** only native interactive Codex CLI binaries with the CLI-specific capability marker are signal targets. Wrapper shells, code-mode hosts, `exec` subprocesses, SSH clients, and `--remote` clients are not the account-bearing local runtime. Both `~/.local/bin/codex` and `/opt/homebrew/bin/codex` must resolve their managed launcher target to the native binary before validation. A local launch must fail with a repair instruction when no complete hot-swap runtime is available; it must never silently fall back to the stock npm or desktop-bundled CLI, because that creates a process that can observe exhausted credentials but cannot adopt the next account in-turn.
- **Mac CLI discovery:** preliminary `pgrep` candidates use exact process-name matching for `codex`. Full-command-line matching is prohibited because unrelated CodexSwitch paths and short-lived tools can make an otherwise valid batch incomplete.
- **Mac CLI first ACK:** a current attested managed CLI may receive its first request only when its route, hashes, read-only files, owner, and running executable vnode all match. A historical runtime without the v3 CLI contract requires one exit and resume.
- **Retry-exhausted CLI recovery:** topology observation runs off the main actor and is throttled. Once historical CLIs are gone, one new all-managed topology may re-arm same-target convergence; an unchanged failing topology must not loop.
- **Desktop code-mode helper:** `codex-code-mode-host` is a worker owned by the desktop app-server, not an independent interactive CLI. It must not appear as a Mac CLI readiness blocker or receive a standalone auth-reload signal; readiness follows its parent app-server.
- **Mac remote client:** a `codex --remote` process on the Mac is a transport client, not the account-bearing app-server. It must not be treated as the VPS hot-swap target.
- **Linux VPS app-server:** the app-server process is the primary account-bearing runtime for KittyLitter/remote sessions and must acknowledge reload.
- **Remote SSH proxy:** `codex app-server proxy` is a transport bridge, not the account-bearing runtime, so it is excluded from SIGHUP targeting. After promoting a new VPS binary, reconnect the desktop's remote SSH transport so the proxy adopts the new protocol and model catalog; validate auth against the long-running remote-control app-server.
- **Linux patched CLI:** `/home/signul/.local/share/codexswitch/patched-codex/codex ...` is a native Codex runtime even when launched with arguments such as `--yolo`. Detection must inspect the executable token, not only exact command-line suffixes. The app-server detector must also accept `app-server --remote-control --listen ws://...`; otherwise the VPS can write `auth.json` but report `signaled 0 Codex hot-swap process(es)`.
- **Background ACK repair:** the daemon may repair missing ACKs for live interactive CLI sessions. Discovery attempts are capped at one per 60 seconds even when no ACK is missing; a healthy no-work result must advance the cadence clock. It must not repeatedly signal an app-server that has not proven live reload support, because a supervised WebSocket app-server can exit on `SIGHUP` and enter a disconnecting restart loop.
- **Barrier failure:** when the daemon tick rejects a durable activation barrier, the production loop must skip its background ACK repair for that iteration. Test the outer loop decision, not only the inner tick.
- **Desktop RPC deadlines:** WebSocket send/receive timeouts must use a monotonic dispatch deadline rather than a cooperative Swift sleep. Executor saturation or a non-cooperative URLSession operation must not postpone cancellation or hold a swap transaction open past its bounded deadline.
- **Kernel executable identity:** a fresh ACK never substitutes for current
  process identity. On macOS, classify from the command line but authorize a
  signal only after `proc_pidpath` independently resolves the same executable
  identity captured at discovery. A changed or unavailable kernel path fails
  closed; a prepared update must converge process identity before reload.
- **SIGHUP ownership:** current upstream app-server builds may register `SIGHUP` as a graceful shutdown signal. The patched runtime must remove that shutdown branch so the CodexSwitch auth-reload task is the only SIGHUP subscriber. A valid ack followed by process exit is a failed hot-swap, not readiness.
- **VPS SSH transport:** CodexSwitch-managed readiness probes, swap commands, tunnels, and direct remote TTY fallbacks must pass `ControlMaster=no`, `ControlPath=none`, and `ControlPersist=no`. User shell aliases may multiplex, but app-managed Codex transports must not inherit a shared OpenSSH master where unrelated channels can add latency or close the session.

## Unified ChatGPT Desktop Bundle

OpenAI's unified macOS desktop release keeps the `com.openai.codex` bundle
identifier while installing as `/Applications/ChatGPT.app`. CodexSwitch must
discover the active desktop bundle by identity and support both that path and
the legacy `/Applications/Codex.app` path. Process classification, ASAR
patching, signature checks, bundled plugin discovery, app-server diagnostics,
and stock app updates must all use the same resolved path.
The signing verifier must resolve the main binary from `CFBundleExecutable`;
the unified bundle uses `Contents/MacOS/ChatGPT`, while legacy releases used
`Contents/MacOS/Codex`.

The desktop app may launch an external CLI through `CODEX_CLI_PATH`. That
override is valid only when CodexSwitch has installed a complete, current
runtime directory containing both `codex` and `codex-code-mode-host`. Updating
only the main executable is invalid: it can break tool execution and can make
the desktop UI run a stale model catalog even when the app bundle itself is
current. Mac and VPS installs must stage and promote the companion binary with
the patched `codex` executable before restarting an app-server. Process
parsing must recognize that prepared app-server even though its path contains
the product name `codexswitch`; only the CodexSwitch menu app itself is
excluded from runtime discovery.

On macOS, copying a valid Cargo-built Mach-O into the prepared runtime creates
a new executable file that must be ad-hoc signed before validation or launch.
The staging operation must re-sign both copied Mach-O executables and then run
the staged `codex --version`; validating only the original Cargo output can
leave a prepared runtime that AMFI terminates at exec time. Non-Mach-O fixtures
and Linux runtime copies do not use this signing step.

The menubar's CLI updater must invoke the exact native
`~/.local/bin/codexswitch-cli` JSON update contract. It must not install the npm
package or revive the historical source-fork rebuild as a fallback. Mac builds
run with `CARGO_BUILD_JOBS=1`; an update is successful only after the Rust
updater reports `installed`, both local launcher routes are repaired to the same
complete runtime, and an independent installed-version check matches the
reported stable version. A prepared artifact is not an installed runtime.

Automatic Mac CLI maintenance checks the stable channel every 15 minutes but
starts at most one update operation at a time. It may build only when the data
volume has at least 20 GiB free, and it must defer instead of repeatedly retrying
an already-running update. A low-disk deferral is reconsidered on the next
15-minute check, while a real check, prepare, or install failure backs off for
six hours. Automatic installation replaces only future launcher targets; it
does not terminate a live CLI or desktop app-server. Those sessions remain
explicitly restart-required until they relaunch on the verified runtime.

The unified app's native Sparkle feed remains the source of truth for desktop
versions. CodexSwitch's fallback updater must accept both `ChatGPT.app` and
legacy `Codex.app` archive layouts, install to the current product name, verify
the stock OpenAI signature, and let the normal patch monitor reapply desktop
compatibility only after the app has quit.

## Desktop Bridge Verification

Current ChatGPT builds use stdio for a private local app-server unless
`CODEX_APP_SERVER_WS_URL` is present. CodexSwitch's supported desktop topology
is one patched listener on `127.0.0.1:9223` with ChatGPT connected to it.

Verify:

```sh
lsof -nP -iTCP:9223
```

Expected:

- one patched `codex` process owns the `LISTEN` socket;
- ChatGPT has one established connection to that listener;
- no stale private `codex ... app-server` process remains.

The ChatGPT desktop log must report:

```text
Starting app-server connection hostId=local transport=websocket
```

Every CodexSwitch connection sends `initialize` before `account/login/start`
or `account/read`. Current app-server replies may omit `jsonrpc: "2.0"`, so the
response is valid when it has the expected `id` and exactly one
`result`/`error` outcome. An explicit different JSON-RPC version is invalid.

Do not report success from the bridge connection alone. The activation journal
must become `confirmed`, and the matching `hotswap-ack/<pid>.json` must prove
the strict runtime reload.

## CLI Update Storage Safety

The Rust Codex CLI updater must treat an installed version as terminal for that
version when the selected runtime also satisfies the current hot-swap marker
contract and includes `codex-code-mode-host`. Before entering `Preparing`, it
refreshes that complete installed runtime and reconciles matching versions to
`Installed`; a stale failed or prepared state must never rebuild it. The same
upstream version may be prepared once when an older CodexSwitch patch contract
is installed, after which the version-scoped failure policy still applies.

A failed source preparation records both the failed version and a durable retry
deadline. Stable-channel metadata checks may discover a newer version and may
clear an obsolete failure record, but only when the discovered version is
strictly newer. A registry rollback or the return of the same failed version
must not erase its cooldown. Automatic preparation resumes only after that
deadline or when a newer stable version is available. The update-state file is
committed by same-directory temporary-file rename so a crash or disk-full write
cannot truncate the only copy of the cooldown.

Manual preparation is idempotent too. If the requested version already has a
fully validated immutable generation, the command returns that generation
instead of creating another one. If the same version is inside its preparation
cooldown, the command reports the deferred state and does not bypass the
deadline.

Each source build stages into a unique immutable attempt directory beneath the
version directory. The active prepared runtime and launcher target are changed
only by the installation transaction after both `codex` and
`codex-code-mode-host` validate, the binary reports the expected prepared
version, and macOS execution validation succeeds. Validation includes the
companion's non-empty executable mode and Mach-O signature, not only its
existence. Metadata recovery and installation repeat that complete validation;
marker presence alone must never promote an interrupted generation. A failed
or interrupted preparation must not modify the bytes or path used by a live CLI
or desktop app-server.

Cargo output is temporary updater state. Once the two runtime executables have
been copied into their immutable attempt directory, the updater removes the
source checkout's `codex-rs/target` tree on success and failure. The retained
checkout may support later patching, but compiled intermediates must not refill
the Mac between retry windows. When a prior `Preparing` state is stale, the next
locked updater operation removes its recorded updater-owned target and partial
UUID generation before applying the 20 GiB capacity gate. Cleanup is restricted
to paths beneath the CodexSwitch data directory and never follows symlinks. If
that stale state already contains a fully validated generation, recovery
promotes it to `ReadyToInstall` and cleans only the build target instead of
destroying the reusable runtime.

A cleanup error after successful runtime validation must not discard that
immutable generation or schedule another source build. The updater advances the
verified generation to `ReadyToInstall`, reports the cleanup problem as a
non-fatal warning, and lets installation converge before any later maintenance
retry. The recorded cleanup target remains durable state after installation and
is retried by later locked maintenance until removal succeeds; no failed
cleanup may become an untracked directory.

The updater owns the Cargo output location. Its build command forces
`CARGO_TARGET_DIR` to the checkout's `codex-rs/target` path so inherited shell or
Cargo configuration cannot redirect gigabytes outside the cleanup boundary.

Installation writes `Installing` before mutation. A failed install keeps the
validated immutable generation, records a version-scoped six-hour install
retry deadline, and does not retry on every daemon iteration. The next attempt
also removes abandoned PID-specific temporary install files before creating a
new atomic copy, but only when the suffix is a numeric PID whose process is no
longer alive. A concurrent installer's active temporary copy is never removed.
Successful installation clears both preparation and install failure records.

## Desktop Update Ownership

Automatic desktop patch or update activation must defer while a detached
app-server is running because the process may own live remote work. A deliberate
operator repair may stop that service only after PID, user, executable path, and
process start time are revalidated immediately before `SIGTERM`. Broad
`pkill -f` matching is prohibited.

Re-signing the unified app for local compatibility changes its signing team, so
Sparkle's privileged installer can reject an otherwise valid update. CodexSwitch
must own the update lifecycle whenever the installed desktop bundle is locally
signed:

1. Poll the official Sparkle appcast at least once per minute and use conditional
   HTTP requests when validators are available.
2. Download a newer full archive into CodexSwitch's private staging directory
   without quitting a live ChatGPT session.
3. Verify the staged app's bundle identity, version, and stock OpenAI signature
   before marking it ready.
4. Install only after the ChatGPT host and account-bearing app-server have exited.
5. Apply and verify the compatibility patch before relaunching the updated app.
6. Watch the Applications directory so an external replacement triggers an
   immediate compatibility check rather than waiting for a periodic timer.

While CodexSwitch owns this path, it must disable Sparkle's automatic checks for
the locally signed bundle so Sparkle does not repeatedly download an archive its
privileged installer cannot accept.

Desktop status and readiness probes must inspect the currently available
code-signing identity without importing certificates or private keys. Keychain
repair is a mutation reserved for an explicit patch, build, or repair operation;
the patcher exposes separate inspection and repair command paths so opening the
menu cannot change Keychain state.

An update may be downloaded, verified, and staged while ChatGPT is running, but
an automatic check must never replace the installed bundle or force-quit a call,
active turn, or other live session. "Automatic" means preparation happens
without user work and installation is entered only from a proven app-termination
boundary. An explicit manual install is also allowed, but it uses the identical
fail-closed host and app-server gate. A committed replacement remains an install
success when rollback-material cleanup is pending; later safe termination or
scheduling work retries that cleanup without rolling the new bundle back.
Live-host detection must recognize both
`/Applications/ChatGPT.app/Contents/MacOS/ChatGPT` and the legacy
`/Applications/Codex.app/Contents/MacOS/Codex`, in addition to an
account-bearing app-server. A packager or patcher must refuse replacement when
its bounded quit wait expires; it must never delete an installed bundle while
that bundle's process is still alive.

Do not use `launchctl submit` for a one-shot deferred desktop replacement.
Submitted jobs can be inferred as keep-alive services and relaunch every ten
seconds after the source bundle has been consumed. Run the guarded replacement
directly, remove any temporary service on every exit path, and do not post
installer status through `osascript display notification`; clicking those
notifications opens Script Editor because Script Editor is their sender.

Known model slugs must remain legible while the online catalog refreshes. In
particular, selecting `gpt-5.6-sol` from the new-model announcement must render
as `5.6 Sol`, not `Custom`, even if the first catalog snapshot temporarily has
no `displayName`. The fallback label is derived from the known model slug and
must not rewrite the selected model or reasoning effort. Both the catalog
option mapper and the selected-model button need this fallback; fixing only the
option mapper still leaves the active selection labeled `Custom` when its
catalog entry is temporarily absent.

The desktop's remote `available_models` allowlist can lag behind the bundled
CLI catalog during a model rollout. A visible GPT-5.6 model returned by the
active app-server must remain in the picker even when that remote allowlist is
stale. The desktop compatibility patch may bypass the stale allowlist only for
GPT-5.6 entries actually returned by `model/list`; it must never synthesize a
model that the active runtime did not advertise.

The active app-server is also authoritative for GPT-5.6 reasoning efforts.
When `model/list` advertises `max`, the desktop must preserve it even if the
desktop's enabled-effort cache predates that rollout. For Sol's compact power
presets, `max` belongs between `xhigh` and `ultra`; compatibility code may add
that preset only for the server-advertised GPT-5.6 capability and must not make
an unsupported effort selectable. This ordering contract applies whether the
bundle stores ultra inline with the base presets or as a separately appended
optional preset.

Remote model queries are cached by host id. Reinitializing an SSH app-server
with the same host id must invalidate the `[models, list, hostId]` query prefix
immediately. A connection restart cannot leave the old catalog active for the
normal five-minute stale window, because the selected model and the picker
options would then disagree even though the replacement app-server already
advertises the new catalog.

Fast Mode compatibility is a model-metadata repair, not an account-entitlement
bypass. Older desktop bundles gate Fast from `additionalSpeedTiers`; unified
ChatGPT build `26.707.51957` and later service-tier layouts derive the picker
from each model's `serviceTiers`, then require `isServiceTierAllowed` and more
than one `availableOptions` entry. When the active model is in the bundled
CLI's fast-capable catalog but refreshed model metadata omits the Fast
representation consumed by the active layout, the compatibility patch may
repair that missing representation. The service-tier layout may add exactly
one synthetic `priority` / `Fast` option for that model. It must preserve an
explicit `requirements.featureRequirements.fast_mode == false` result and must
not add, replace, or duplicate metadata when the server already supplied any
service-tier entries. Both the legacy and service-tier layouts remain supported.

The Fast compatibility marker is required desktop-patch evidence. Production
patching must apply the matching Fast fallback before repacking, and desktop
readiness must remain patch-needed when that marker is absent. A unit test that
only exercises the legacy synthetic `font-settings` gate is insufficient: each
supported unified bundle layout needs a fixture that proves discovery, patch
application, explicit-prohibition preservation, non-duplication, and
idempotence. Every desktop locator and readiness surface must use the same
required marker set, including `_bundledFastModels`; a lower-level locator must
not report a stock or partially patched ASAR as compatible.

The app packager defaults to a release build. On a machine where only Apple's
Command Line Tools are installed and the SDK's `SwiftUIMacros` plugin is
unavailable, a previously verified debug build may be packaged explicitly with
`CODEXSWITCH_BUILD_CONFIGURATION=debug CODEXSWITCH_SKIP_SWIFT_BUILD=1
scripts/build-app.sh --install`. Skipping compilation is valid only after the
test suite has rebuilt and verified the selected executable. Both overrides
must remain explicit and must never silently change the release default.

Installation must stage the complete bundle on the `/Applications` filesystem
and verify its executable, removed-code markers, and strict code signature
before changing `/Applications/CodexSwitch.app`. Activation renames the existing
bundle to a same-filesystem rollback path, moves the verified staged bundle into
place, verifies the installed copy, and launches it. Any move, verification, or
launch failure restores the prior bundle. A permission failure during staging
must leave the running installed version untouched.

`CFBundleSourceRevision` must distinguish a clean commit from an uncommitted
working tree. Dirty builds include a deterministic source-tree fingerprint so
operators can identify the exact executable under test even before the changes
are committed to `main`.

## Account State Boundaries

Mac CodexSwitch and Linux `codexswitch-cli` run the same eligibility rules, but their daemon/runtime control remains host-local. They should converge on token, plan, quota, subscription, and runtime-blocker state through encrypted Mac -> VPS account-state sync plus each host's own `https://chatgpt.com/backend-api/wham/usage` polling. They must not automatically share active-account selection, runtime acknowledgements, daemon state, or stale `/status` banners from an existing Codex session.

- A background VPS readiness check may display the VPS active email, but it must not set the Mac active account, rewrite local `auth.json`, or start a Mac auto-swap.
- While a live `codex-vps` remote session is intentionally mirroring VPS account state in the menu bar, the VPS daemon owns automatic rotation. The Mac must not execute a second auto-swap from that mirrored state or issue repeated account-swapped notifications.
- An asynchronous `auth.json` observation may promote a stable external account change, but it must be discarded when the local active account changes while the file read is suspended. The next timer pass can read again; a stale pre-swap observation must never revert a completed swap or re-export the old account to the VPS.

When the Mac menu app and VPS CLI disagree, compare safe evidence in this order:

1. Token hash prefix for the account on both hosts.
2. Live `wham/usage` primary and secondary windows for that token.
3. `auth-diagnostics` active account and `auth.json` hash on the host that sent the request.
4. The active Codex session's own `/status`, treating any "limits may be stale" warning as non-authoritative until rechecked.

## Manual Account Controls

Each account card is one manual activation control. Its visible click target and
default macOS accessibility press action must call the same primary action:
reauthenticate an unusable account, retry a configured-but-unconfirmed account,
or switch the Mac to another account. Hover and tooltip helpers must be declared
non-hit-testable so they cannot intercept that control.

The control must remain available while an automatic-retry-limit
`ManualReview` barrier is visible. A successful press must produce activation
journal evidence; a visual highlight change without a new activation generation
is not proof that the request ran.

The manual switch revalidates exact durable source credentials but does not
require the old runtime to be current. It must then converge the newly selected
target normally. If authorization stops before credential mutation, verify that
the prior activation journal was restored and neither configured file changed.

## Menu App Process Boundaries

The Mac menu app must have exactly one live poller process. A duplicate CodexSwitch process can double-poll quota, double-sync VPS state, and produce contradictory menu updates even when each process is individually running the correct code.

CodexSwitch acquires a single-instance lock before it starts account loading, quota polling, VPS mirroring, patch checks, or status-item timers. If LaunchServices starts a second copy, that process must exit before services start. Reinstall verification should include both the installed bundle version and a one-PID process check for `/Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch`.

## Quota Snapshot Validity

`/backend-api/wham/usage` can return placeholder quota data while the backend is stale or unable to report usage for the selected account. A placeholder primary window has `used_percent = 0`, no real window duration, and a reset time equal to the fetch time. CodexSwitch must treat that as unavailable data, not as `100%` remaining quota.

This rule applies at every boundary: the Swift parser, Rust CLI parser, account-store load/save, VPS account-state mirror, menu-bar display, pooled usage math, and swap candidate selection. Placeholder snapshots must not be persisted, mirrored into a healthy local snapshot, shown as green/100%, used as next-up, or used to block a necessary swap.

## Runtime Blockers and Reauth

Quota-unavailable is not the same state as reauthentication-required. Placeholder quota windows are transient backend data failures and should be retried with backoff, especially for inactive Pro accounts that have no trusted quota snapshot yet.

Authentication failures are different. A 401/token-expired/token-invalidated account must be marked runtime-unusable, excluded from swap candidates and pooled usage, persisted, mirrored between Mac and VPS, and shown as `Needs login` even if an old quota snapshot still exists. Stale exhausted reset text must never hide a known auth blocker.

A direct runtime `usage_limit` signal from Codex is also authoritative. The active account must be marked runtime-unusable and rotated away even if a fresh `/wham/usage` response still reports apparent remaining percentage. The usage endpoint can lag or omit model-specific exhaustion; it must not be allowed to reselect the same account after Codex already refused a request.

## Quota Polling Cadence

The daemon may use a slower normal polling interval while the active account has comfortable quota, but it must tighten as soon as either tracked quota window falls below the danger band:

- `<= 5%` remaining: poll every `2s`.
- `<= 2%` remaining: poll every `1s`.

When the user-visible status would round remaining quota to `1%`, or when any hard runtime usage-limit signal appears, it must rotate before the next user request depends on that exhausted account.

Inactive accounts need a separate upgrade watch because plan purchases happen
out-of-band while CodexSwitch is already running. On a healthy no-rotation tick,
the daemon probes at most one due inactive account and selects it with a stable,
fair rotation across polling buckets. A timeout or transient failure leaves the
old freshness timestamp unchanged. This bound prevents a large inactive pool
from delaying the next active-account safety poll. Once a swap or plan upgrade
is actually required, candidate refresh is exhaustive before ranking. When the
Mac app detects a plan-type change, it also asks the configured Linux devbox to
poll that same account immediately instead of waiting for background rotation.

## Mac Menubar VPS Freshness

When a Mac-side Codex client is attached to the VPS app-server, the menubar may display the sanitized VPS account observation from `codexswitch-cli account-state` cadence, not the slower readiness cadence. That observation is a separate remote presentation state and never replaces the Mac active account.

- Active VPS remote client detected: fetch sanitized VPS account state every `5s`, with overlapping checks suppressed.
- VPS auto-swap execution stays on the VPS. Mac local auto-swap continues to protect Mac local runtimes and is not suppressed by the remote connection.
- No active VPS remote client detected: keep the normal `60s` readiness cadence.
- The detector must include both `codex-vps` terminal clients and Codex.app-launched `codex --remote ws://100.95.84.123:8390 ...` clients.
- SSH/Tailscale tunnel helper processes are transport plumbing and must not be mistaken for an active Codex remote client.
- The Mac menu app must not push local active-account swaps to the VPS. The VPS rotates itself through its own coordinator and hot-swap path even when the Mac is offline. The Mac may display VPS state in a clearly remote view and sync non-authoritative observations, but background sync preserves each host's active account unless that host's coordinator rotates it.

## Pool Capacity Math

The pooled usage meter must not count every account as one Plus account. It uses the verified plan-capacity table and calculates each semantic quota window independently. An account contributes to five-hour capacity only when it reports a five-hour window, and to weekly capacity only when it reports a weekly window. Temporary promotions and plan multipliers belong in the versioned capacity model and tests, not in this runbook.

The UI should show meaningful plan comparisons without fabricating capacity for a missing window.

## Candidate Selection

Candidate selection follows `docs/architecture/quota-and-reset-policy.md`. Verification must prove that missing five-hour data is not exhaustion, unusable accounts are excluded, Pro capacity is preferred, the natural-reset guard protects scarce resets, and ties are deterministic.

## Transient VPS Readiness Blips

Incident note from 2026-05-03 03:34 UTC: the Mac menu app reported `LINUX_DEVBOX_NOT_READY` for VPS app-server pid `2765261` because the process had hot-swap marker strings but no live reload acknowledgement yet. This was a real transient readiness gap, not a fabricated UI state:

- Mac monitor log: `03:34:30.672Z` reported `SIGHUP markers present, but live process has not acknowledged a reload`.
- VPS daemon journal: `03:34:32` reported `verified hot-swap reload for 1 process(es); 0 skipped`.
- VPS ack evidence: `~/.codexswitch/hotswap-ack/2765261.json` was created at `03:34:32.122Z`.
- Next Mac monitor check: `03:34:55.618Z` returned ready.

Treat one recovered not-ready result after a previously ready VPS as a transient bootstrap blip in the UI; suppress orange flicker until two consecutive issue checks fail. Still log the first blip as `LINUX_DEVBOX_TRANSIENT_*` so a recurring pattern remains visible. Two consecutive issue checks are real operator-visible not-ready state.

## Verification Checklist

Before claiming hot-swap is fixed or ready:

- [ ] `codexswitch-cli auth-diagnostics` shows active account hash equals `auth.json` hash.
- [ ] `codexswitch-cli doctor` reports live runtimes as verified, not merely patched.
- [ ] A fresh app-server restart is auto-acknowledged by the daemon bootstrap reload without waiting for a real quota swap.
- [ ] A fresh Mac `9223` bridge restart can bootstrap its first ACK during an
  explicit desktop activation, but only when the launchd PID, generated bridge
  files, their embedded exact managed route, expected runtime/helper hashes,
  listener owner, and running executable vnode all agree. A stale independent
  CLI forwarding wrapper must not block this desktop-only bootstrap.
- [ ] The Swift managed-launcher fixture uses real tab bytes and contains no
  literal `\t` indentation sequences, matching the Rust-generated launcher.
- [ ] Relaunching CodexSwitch recovers a same-target
  `automatic_retry_limit_reached` journal once, after bridge installation,
  without changing the configured account or credential files.
- [ ] Each live target has a fresh `.codexswitch/hotswap-ack/<pid>.json` acknowledgement.
- [ ] The desktop runtime contains the account-update marker, and the ACK proves matching disk/active auth fingerprints, the current signal nonce, and at least one completed frontend write.
- [ ] A local interactive CLI ACK identifies `local-interactive-cli`, proves matching disk/active auth fingerprints and the current signal nonce, reports auth-generation/reconnect readiness, and reports zero desktop frontend writes.
- [ ] A first-ACK CLI canary succeeds for the current managed runtime, while a historical or non-route runtime is skipped and remains restart-required.
- [ ] Exiting the final historical CLI and resuming through the managed launcher re-arms an exhausted same-target journal without relaunching CodexSwitch.
- [ ] The installed desktop version matches the latest official appcast release, or a newer signed release is staged for the next safe quit.
- [ ] The installed ASAR contains exactly one Fast compatibility marker declaration, and the patched renderer still honors an explicit `featureRequirements.fast_mode == false` prohibition.
- [ ] The installed ASAR contains `CODEXSWITCH_AUTH_CACHE_INVALIDATION_V2` exactly once, contains no nested legacy WeakMap helper, and a same-account auth notification produces no `_invalidateAccountQueries is not defined`, provider unmount, route remount, or window reload.
- [ ] The installed ASAR contains `CODEXSWITCH_REMOTE_RECENTS_REFRESH_PATCH_V2`; its fallback adds no immediate mount refresh, polls at 60 seconds, retains native callback and startup updates, and clears its single timer on unmount.
- [ ] The bundled `patch-asar.py` hash matches the source used for the CodexSwitch build, the desktop-patch log records Fast fallback application without a structure warning, and the ASAR integrity hash plus strict code-sign verification pass before relaunch.
- [ ] A forced rotation changes the configured account and signals the expected process count.
- [ ] From `CommittedDegraded`, an explicit cross-target operator selection starts a fresh activation while automatic rotation remains blocked.
- [ ] From retry-exhausted `ManualReview`, an explicit cross-target operator selection can recover; every other manual-review reason remains blocked.
- [ ] A manual cross-account switch can leave an unconfirmed source runtime when the account store and `auth.json` still agree exactly.
- [ ] A pre-mutation authorization failure restores the prior activation journal instead of pinning manual review to an uncommitted target.
- [ ] Launch recovery repairs `activation_file_commit_failed` only when the account store and `auth.json` agree on one known account, and publishes configured-only state.
- [ ] Each account card exposes a default accessibility press action, and pressing it produces the same activation request as a normal click.
- [ ] The account-card hover overlay is non-hit-testable and cannot swallow a click.
- [ ] The menu lists the configured account first and does not style it as runtime-current until fresh confirmation exists.
- [ ] The app-server journal or ack file proves the signal handler ran after the rotation.
- [ ] With a disposable live desktop session, `CODEXSWITCH_RUN_LIVE_DESKTOP_RELOAD=1 swift test --filter SwapEngineTests/liveDesktopAppServerReloadWhenRequested` exercises discovery, capability gating, `SIGHUP`, and acknowledgement as one path.
- [ ] The next real Codex request or remote compact uses the new account and does not repeat the old usage-limit error.
- [ ] Mac desktop, Mac CLI, Mac remote client, and VPS app-server statuses are checked separately.

## Regression Requirements

Every future hot-swap change must include tests for:

- Marker-only binaries are **not** ready without live acknowledgement.
- A fresh ACK from the running PID remains authoritative when the executable at that path was replaced after process start or the executable path cannot be resolved.
- Desktop readiness rejects binaries that reload backend auth without broadcasting `account/updated` to the shell.
- Missing or malformed auth produces no successful ACK and does not replace valid cached auth with `None`.
- Zero initialized frontends, a closed frontend writer, and a same-second stale ACK cannot satisfy hot-swap verification.
- The SIGHUP request nonce is unique per signal and must be echoed by the matching PID ACK.
- An external app-server rejects a CLI-kind ACK, and a local interactive CLI accepts only its CLI-kind ACK with exact nonce/fingerprints plus auth-generation/reconnect readiness.
- A stale in-process app-server handler exits on a closed outgoing channel before it can read the request; the request remains available for the live handler and injected-turn binding, while `account/updated` delivery to the TUI remains best-effort.
- A stale `desktop-auth-watcher-ready` file cannot make a current desktop process report ready.
- Desktop updates are downloaded and signature-verified while the app is live, but replacement and compatibility patching wait for app termination.
- An in-flight `auth.json` read cannot revert a local account swap that completes before the read returns.
- Account cards keep one shared primary action for normal clicks and the default
  accessibility press action, while hover helpers remain non-hit-testable.
- Manual swap authorization requires exact durable source credentials but not
  source runtime-current evidence; automatic swaps and active credential
  maintenance retain their fresh runtime-proof requirement.
- Pre-credential authorization failures restore the operation's prior journal
  under the same lease, and launch repair of file-commit failures requires exact
  store/auth agreement before publishing configured-only recovery.
- App-server patching targets the `AuthManager` captured by `MessageProcessor`, not an earlier preload/auth probe.
- Expired or quota-exhausted active accounts rotate to usable candidates and rewrite `auth.json`.
- Runtime `UsageLimitReached` inside Codex rotates once, reloads the active `AuthManager`, and retries the turn before surfacing an error.
- In-turn usage-limit and auth-failure rotation passes the exact verified auth path to normal `rotate-now`, uses a bounded configurable timeout and output limit, requires the CLI's verified-runtime result, reloads that exact path through the turn `AuthManager`, compares the complete fingerprint, and retries only once. The injected path must not contain `--no-reload` or synthesize a default auth path.
- Injected path binding rejects stale/future ACKs, PID-reuse start identities,
  wrong runtime kinds, mismatched or missing request nonces, changed disk auth
  fingerprints, symlinked artifacts, and oversized ACK/request files.
- Both injected rotation subprocesses stream and drain stdout/stderr concurrently
  under a hard per-stream cap, and timeout handling kills and reaps the child;
  post-hoc length checks around `Command::output` are insufficient.
- Empty reload summaries and zero discovered targets produce an explicit file-only or degraded result, never `Confirmed`; daemon and automatic rotations require at least one acknowledged target.
- Import parsing is side-effect free, and import activation restores the exact pre-import store/auth after injected write or crash failures without overwriting a concurrent generation.
- Auth rollback tests inject a concurrent replacement between ownership
  observation and commit; the replacement survives and activation records
  durable manual review.
- Account-store tests exercise hostile umask, mode repair/rejection, created-versus-reopened inode proof, symlink-safe descriptor traversal, fsync/readback, and an actual second process contending on the shared lock.
- All Rust subprocess, `ps`, and exact-unit `systemctl` paths have deterministic timeout tests. Signal tests cover identity change immediately before delivery and before ACK acceptance.
- Desktop RPC timeout tests run beside the full concurrent Swift suite and prove that a cancellation-ignoring operation cannot delay the monotonic deadline.
- Source trees, prepared generations, update logs, request files, and ACK files enforce count, age, and total-byte retention while preserving active/current/rollback artifacts; oversized ACKs are rejected before allocation.
- Artifact scans stop at deterministic entry/time/memory budgets, generated
  request readers cap bytes before allocation, and reset-journal tests prove
  descriptor-anchored generation CAS, exact readback, symlink rejection, and
  concurrent-writer manual-review preservation.
- Active quota at or below 5% uses 2-second polling, at or below 2% uses 1-second polling, and quota displayed as `1%` rotates immediately.
- A healthy daemon tick performs no more than one due inactive maintenance
  probe, rotates that opportunity fairly, preserves freshness on failure, and
  still refreshes every required candidate before a swap decision.
- Mac plan changes trigger a safe `codexswitch-cli poll <account>` on the configured Linux devbox without transferring or logging secrets.
- Mac menubar active-account display follows VPS account-state within a few seconds while a Codex.app or CLI `--remote` VPS session is active.
- Desktop discovery and updates cover `/Applications/ChatGPT.app` and the legacy `/Applications/Codex.app` without maintaining divergent path constants.
- Patched CLI promotion includes `codex-code-mode-host` on both Mac and Linux, and refuses an incomplete prepared runtime.
- A running desktop `codex-code-mode-host` helper is excluded from standalone Mac CLI detection even when it lives beside `codex` in a prepared runtime directory.
- A configured app-server under `~/.local/share/codexswitch/prepared-codex/` remains a desktop reload target even though its path contains `codexswitch`.
- A missing display name for `gpt-5.6-sol` falls back to `5.6 Sol` in both catalog options and the selected-model button while preserving the selected slug and reasoning effort.
- A stale desktop `available_models` allowlist cannot hide GPT-5.6 entries that the active app-server returned as picker models.
- A server-advertised GPT-5.6 `max` effort survives the desktop enabled-effort filter, and the Sol preset order is `xhigh`, `max`, `ultra`.
- Legacy `additionalSpeedTiers` and unified `serviceTiers` Fast layouts are both discovered and patched idempotently; the unified fallback adds one missing `priority` / `Fast` option only for a bundled fast-capable model, preserves non-empty server metadata, and never overrides an explicit `featureRequirements.fast_mode == false` prohibition.
- Missing Fast compatibility evidence keeps desktop patch/readiness status pending even when every auth, model-label, refresh, signature, and runtime marker is present.
- Reinitializing a same-host remote app-server invalidates the host-scoped model-list query before the picker renders its replacement catalog.
- Pool capacity math uses plan-weighted Plus-equivalent multipliers and distinguishes Pro 5x promotional capacity from Pro 20x 5h/weekly capacity.
- Same-tier candidates with comparable quota prefer the earlier 5h reset; earlier reset must not beat a meaningful quota gap or a higher paid tier.
- Binary readiness markers require the usage-limit retry marker, not just old SIGHUP/ack strings.
- UI "Next Up" uses the same immediate-usable candidate gate as auto-swap, so a Pro account at 1% weekly does not appear before a usable Plus account.
- Remote/client wrapper processes are not signaled as if they were account-bearing runtimes.
- CLI readiness/status checks are read-only and never send SIGHUP to bootstrap acknowledgement.
- `doctor` and UI copy say `not verified` or `restart required` instead of showing a green state when acknowledgement is missing.
- A single VPS not-ready check after a ready state is debounced, but two consecutive not-ready checks still surface orange and notify.

## Incident Review Questions

When a swap fails, answer these before applying a fix:

1. Which process actually sent the failed request?
2. Which auth source did that process load at startup?
3. Did `auth.json` change to the intended active account?
4. Did the live process acknowledge the reload after the change?
5. Did the next request use the new account, or only the store/auth file changed?

If any answer is unknown, CodexSwitch must not report readiness as green.
