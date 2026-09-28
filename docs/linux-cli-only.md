---
toc:
  - Linux CLI-Only CodexSwitch
  - Target States
  - Platform Contract
  - Recommended VPS Setup
  - Linux Service Model
  - Removed Non-Core Integration
  - SecureDrop File Transfer
  - codex-vps Tunnel Stability
  - claude-vps Remote CLI Entry
  - cmux Managed SSH And Image Uploads
  - claude-vps Clodex Lane
  - signul ssh Terminal Stability
  - Implementation Plan
cross_dependencies:
  - docs/README.md
  - docs/architecture/system-overview.md
  - docs/architecture/runtime-and-host-ownership.md
  - scripts/securedrop/cs-autopush
  - scripts/codex-vps
  - scripts/claude-vps
  - scripts/clodex-credential-helper.py
  - scripts/patch-clodex-codexswitch.py
  - scripts/configure-clodex-codexswitch.mjs
  - scripts/install-clodex-vps.sh
  - scripts/signul
  - docs/runbooks/codex-vps-thread-tools-mcp.md
  - Sources/CodexSwitch/Services/SwapEngine.swift
  - Sources/CodexSwitch/Services/CodexVersionChecker.swift
  - Sources/CodexSwitch/Services/CLIStatusChecker.swift
  - docs/superpowers/plans/2026-04-29-desktop-external-hot-swap.md
  - docs/superpowers/plans/2026-04-30-desktop-linux-token-transfer.md
  - docs/runbooks/codexswitch-hot-swap-verification.md
  - docs/runbooks/linux-repository-deployment.md
  - docs/runbooks/runtime-storage-hardening-deployment.md
version_control:
  branch: main
  commit: pending
  last_updated: 2026-08-26
---

# Linux CLI-Only CodexSwitch

## Target States

- **Linux VPS:** first-class target for true CLI hot-swap because the current Codex fork reloads auth on `SIGHUP`.
- **Linux desktop / WSL:** same core behavior as VPS as long as Codex CLI runs as the same user and the SIGHUP fork is installed.
- **macOS desktop app:** must keep official OpenAI signing for Computer Use and Browser Use; desktop hot-swap must use an external/upstream reload hook, not bundle mutation.

## Platform Contract

The portable CodexSwitch core should be a headless daemon/CLI with no SwiftUI or macOS menu-bar dependency:

1. Load account records from a platform-specific CodexSwitch account store.
2. Poll quota for the active account and candidate accounts.
3. Select the next immediately usable account with the same scoring rules as `SwapEngine`.
4. Atomically write the Codex auth file:
   - Linux/macOS/WSL: `~/.codex/auth.json`
5. Notify live Codex CLI sessions:
   - Linux/macOS/WSL: `SIGHUP` to verified patched Codex CLI processes.
   - Codex `app-server` processes are also first-class hot-swap targets when their executable has the same verified SIGHUP markers.
   - Only signal Codex CLI processes owned by the current user.
   - Never signal helper, package-manager, grep, or wrapper-only processes.

## Recommended VPS Setup

For a VPS devbox, use Linux. Build and publish only through the immutable
repository installer. A direct Cargo build copied into `~/.local/bin`, a curl
pipe, or any other public-CLI replacement bypasses release provenance,
`current`/`previous`, systemd rollback, and retention policy.

```bash
git clone <codexswitch-repo>
cd CodexSwitch
export CODEXSWITCH_GIT_SHA=<full-40-or-64-character-git-sha>
export CODEXSWITCH_APPROVED_ORIGIN_REF=refs/remotes/origin/main
export CODEXSWITCH_CODEX_RUNTIME_DIR=<reviewed-runtime-directory>
export CODEXSWITCH_CODEX_VERSION=<reviewed-runtime-version>
export CODEXSWITCH_CODEX_SOURCE_SHA=<full-40-or-64-character-source-sha>

CODEXSWITCH_DRY_RUN=1 scripts/install-linux.sh
scripts/install-linux.sh

# After reviewing the immutable manifest and during an approved idle window:
CODEXSWITCH_ACTIVATE=1 scripts/install-linux.sh

# Import is a separate explicit activation-time mutation:
CODEXSWITCH_ACTIVATE=1 \
CODEXSWITCH_IMPORT_BUNDLE=~/codexswitch-linux-devbox-20260430-055931.csbundle \
CODEXSWITCH_IMPORT_BUNDLE_SHA256=<full-64-character-bundle-sha256> \
scripts/install-linux.sh
```

The stage-only invocation publishes a versioned release but does not change
`current`, `previous`, the permanent public CLI link, systemd state, account
data, or processes. Activation requires the full Git SHA again, refuses active
managed or legacy services, atomically advances the immutable pointers and
systemd transaction, and performs no import unless both the bundle path and its
reviewed SHA-256 are explicitly set in that activation invocation. The journal
is committed only after requested enable, restart, and import actions verify;
failure restores pointers, unit bytes, `.wants` links, prior inactive service
posture, and exact pre-import account/auth state.

The daemon should write `auth.json`, verify each running Codex runtime contains `sighup-verified` and `SIGHUP: auth reloaded`, then require a fresh live reload acknowledgement before reporting readiness. Marker strings prove patch installation only; `.codexswitch/hotswap-ack/<pid>.json` proves the running process observed a reload. App-server runtimes are used by remote clients; if they are stock or unpatched, `doctor` and `status` must report not ready instead of showing a false green state.

Account transfer should use the encrypted desktop export flow from `docs/superpowers/plans/2026-04-30-desktop-linux-token-transfer.md`, not a plaintext copy of `~/.codexswitch/accounts.json`.

## codex-vps Tunnel Stability

The Mac-side `codex-vps` helper uses local port `18390` as an SSH-forwarded WebSocket path to the VPS app-server on `127.0.0.1:8390`. All CodexSwitch-managed control-plane and interactive SSH processes must opt out of OpenSSH connection sharing with `ControlMaster=no`, `ControlPath=none`, and `ControlPersist=no`; the tunnel and direct TTY fallback are transport dependencies for live Codex sessions and must not ride on a shared master connection that can be closed or back-pressured by unrelated SSH activity. Bulk transfer helpers may still use a separate multiplexed SSH profile when throughput matters more than keystroke latency. SSH setup and keepalive tolerance must accommodate a temporarily CPU-starved VPS: the defaults are a 30-second connect timeout, 15-second keepalive interval, and six unanswered keepalives before OpenSSH declares the peer dead. Operators may tune these with `CODEX_VPS_SSH_CONNECT_TIMEOUT`, `CODEX_VPS_SSH_SERVER_ALIVE_INTERVAL`, and `CODEX_VPS_SSH_SERVER_ALIVE_COUNT_MAX`; the defaults must not recreate a roughly 10-second death threshold.

ChatGPT's built-in SSH remote is a separate transport and lifecycle: it reaches the VPS through a `codex app-server proxy` connected to `~/.codex/app-server-control/app-server-control.sock`, not through the port-8390 `codex-vps` service. A successful `codex-vps` restart or `/healthz` probe therefore does not prove the built-in remote recovered, and recycling ChatGPT's local SSH bridge does not prove the port-8390 service recovered. Diagnose and verify the endpoint used by the failing client.

Port `18390` is ownership-protected. Before opening a tunnel, the helper must atomically acquire `~/.codexswitch/codex-vps-tunnel-18390.lock` and atomically publish owner, supervisor, and SSH-child metadata inside it. Cleanup may signal an SSH PID only when the lock token still belongs to the current helper and the PID, parent PID, SSH command, forward specification, and listening socket all match that metadata. A listener that cannot be proved to be this helper's current SSH child is unknown: refuse to attach or replace it, report its PID, and leave it running. A dead owner record may be reclaimed only when no process is listening on `18390`.

The interactive supervisor owns SSH as a background child and monitors both that exact process and `/healthz` while the remote client runs. Cleanup traps must be installed before the startup readiness wait so an interrupt or failed startup cannot orphan the child or lock. Health probes use an 8-second default timeout and are debounced across four consecutive failures, configurable with `CODEX_VPS_TUNNEL_HEALTH_TIMEOUT_SECONDS`, `CODEX_VPS_TUNNEL_HEALTH_FAILURE_LIMIT`, and `CODEX_VPS_TUNNEL_HEALTH_INTERVAL_SECONDS`. Tunnel creation or health failure retries use bounded exponential backoff, starting at 2 seconds and capped at 30 seconds via `CODEX_VPS_TUNNEL_RECONNECT_DELAY` and `CODEX_VPS_TUNNEL_RECONNECT_DELAY_MAX`; startup readiness may wait up to 90 seconds via `CODEX_VPS_TUNNEL_STARTUP_TIMEOUT_SECONDS`. Reconnecting the local SSH tunnel must never start or restart the remote app-server. Remote service restart remains an explicit `codex-vps restart` operation.

The wrapper must keep owning the local remote-client process instead of replacing itself with a one-shot `exec`. If the VPS app-server restarts or the WebSocket closes, the local Codex client can exit even after the SSH tunnel has recovered. By default, `codex-vps` should reconnect after abnormal client exits, stop on clean `/exit` or terminal interrupt statuses, and use bounded exponential delays starting at `CODEX_VPS_RECONNECT_DELAY=2` and capped by `CODEX_VPS_RECONNECT_DELAY_MAX=30`. `CODEX_VPS_AUTO_RECONNECT=0` and `CODEX_VPS_RECONNECT_MAX` remain available for diagnostics and bounded retry counts.

Before attaching, `codex-vps` must also check root filesystem headroom on the VPS. A full or near-full disk can make Codex's rollout/session writer fail, which can sever the app-server WebSocket and leave the local client looking like a random tunnel drop. The default contract is: warn at 90% used, refuse attach below 20GB free or at 97% used, and allow an explicit `CODEX_VPS_SKIP_REMOTE_DISK_PREFLIGHT=1` override only for emergency diagnostics.

For this helper, avoid implicit Tailscale SSH browser-check fallback. Tailscale SSH check mode is useful for ad hoc high-risk access, but automation should use normal OpenSSH over the encrypted Tailnet with key auth. If a human intentionally wants the Tailscale SSH fallback, require an explicit `CODEX_VPS_ALLOW_TAILSCALE_SSH_CHECK=1` opt-in.

## claude-vps Remote CLI Entry

The Mac-side `claude-vps` helper opens native Claude Code in a persistent VPS tmux session. It changes to `/home/signul/SIGNUL`, resolves the newest exact-title match for `backend agent`, and reconnects to its existing managed pane or launches `/home/signul/.local/bin/claude --resume <session-id>`. Use `ccs claude-vps` for the separate CCS lane. The preferred title is configurable with `CLAUDE_VPS_PREFERRED_SESSION_TITLE`; an empty value restores newest-file selection. A missing configured title fails closed. Session resolution happens on the VPS without copying history or session identifiers to the Mac.

Live ownership uses Claude's VPS-local `~/.claude/sessions/<pid>.json` registration, validated against the process start ticks in `/proc`, because an in-process resume can change the thread without changing command-line arguments. A valid registration supersedes the original command-line session ID. Attaching an already-running managed owner is allowed even when another external owner exists, since attachment creates no writer. Multiple tmux owners remain ambiguous; an external-only owner still blocks a new resume.

Plain `claude-vps` and `claude-vps --tmux` use the persistent tmux workflow. Before attaching, the remote helper compares the selected preferred session with the exact session id owned by the live managed pane. A matching pane is attached unchanged. If a managed pane owns a different session, it is renamed under a timestamped `claude-vps-preserved-*` name rather than killed, and a fresh managed pane explicitly resumes the preferred session. If the preferred session is already owned by an unmanaged tmux or non-tmux process, the helper refuses to create a concurrent writer. `--continue` remains only a fallback when no repository session exists and no preferred title is configured.

Plain `claude-vps` honors Claude's persisted `/tui` mode and does not force `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN`. The VPS currently persists `tui: "fullscreen"`, so fullscreen remains active across managed pane creation and reconnection. Use `claude-vps --classic` or `claude-vps --native-scrollback` to explicitly force inline/native scrollback, and `claude-vps --fullscreen` to force fullscreen plus the no-flicker renderer. Use `claude-vps --raw`, `claude-vps --terminal`, or `claude-vps --tui` only for deliberate direct-terminal debugging where renderer fidelity matters more than process persistence.

Plain `claude-vps` launches the persistent VPS session with `--dangerously-skip-permissions` by explicit operator policy. `-yolo`, `--yolo`, and `--dangerously-skip-permissions` remain accepted aliases. Use `claude-vps --safe` or `claude-vps --ask-permissions` to opt back into normal permission prompts for a newly created pane. Changing the requested permission mode never kills a matching live pane implicitly; finish or exit that pane before recreating it when a mode change is required.

Claude Code 2.1.219 and later recognize Claude Opus 5 as `claude-opus-5`, but CCS 8.8.1 shipped before that model was added to its static selector and its refreshed CLIProxy catalog can still omit it. Apply `scripts/patch-ccs-claude-model-catalog.py` on the VPS to add the exact model to both selector surfaces. The patch is pinned to the checked CCS version, validates its insertion anchor, installs atomically with backups, and is idempotent; it must refuse an unknown CCS version or source shape. CLIProxy v7.2.98 also lacks the Opus 5 provider-registry entry, so the selector-only patch is insufficient: `scripts/build-cliproxy-opus5.sh` builds a Linux amd64 binary from the exact upstream tag and models-file preimage with one additional `claude-opus-5` registry record. Install that binary only after zero-active-session verification, retain the prior binary as the executable rollback, restart the proxy, and require both `/v1/models` visibility and a real CCS-routed smoke request before claiming availability. These changes do not alter the default model, account pool, or routing policy. After both selector surfaces are verified, run `ccs claude --config` and select `Claude Opus 5` to persist the reconnect default in `~/.ccs/claude.settings.json`; otherwise an older explicit `ANTHROPIC_MODEL` pin can continue to force Opus 4.8 even though the catalog and proxy already advertise Opus 5.

## claude-vps Clodex Lane

`claude-vps clodex` is the persistent VPS entrypoint for
`@bman654/clodex`. It uses the same protected transport and session-ownership
checks as `claude-vps`, but launches the pinned VPS-local Clodex binary in the
separate `claude-vps-clodex` tmux session. Its default exact preferred title is
`backend agent`; an explicitly empty
`CLODEX_VPS_PREFERRED_SESSION_TITLE` selects the newest session regardless of
title for `/home/signul/SIGNUL`.

An active Claude Code background worker launched with `--fork-session` writes
a real child history that may itself be the newest working thread. The child
must remain the resume target rather than being silently replaced by its older
parent. While the child background PTY is live it remains the sole writer and
causes a fail-closed refusal. Changing backends requires an explicit,
identity-verified stop of that exact worker at a safe restart point, followed
by a fresh owner check and exact-session resume.

The selected identity is exported in the pane's initial command so a cold tmux
server cannot lose it and degrade to `--continue`. Post-creation tmux
environment metadata is not an authority for which history was opened.

The Clodex lane defaults to SSH so an early ownership or readiness refusal is
printed instead of being hidden by a mosh startup teardown; set
`CLODEX_VPS_TRANSPORT=mosh` to opt in. New Clodex panes default to
`--dangerously-skip-permissions`, independently of the ordinary lane's
environment override. `claude-vps clodex --safe` is the explicit opt-out.

This is a composed CodexSwitch/CCS backend lane. Clodex proxy mode remains the
outer selective gateway: selected Clodex models route to OpenAI, while
ordinary Claude/Fable requests pass through to the loopback CCS endpoint.
CCS then applies its current account order, affinity, retry, cooldown, and
quota routing instead of allowing the request to bind to a single native
Claude login. The wrapper labels the Clodex tmux session separately and fails
closed if the pinned Clodex passthrough patch or CCS runtime-helper check is
not ready.

Clodex OpenAI authentication is a read-through view of the complete account
that CodexSwitch has committed as active on the VPS. CodexSwitch remains the
only account-selection and OAuth-refresh owner. The fixed
`/home/signul/.local/bin/clodex-credential-helper` takes the shared
CodexSwitch account-store lock, proves the active account and `auth.json`
token sets match, and returns the credential only through the helper pipe.
Clodex does not persist a second copy and its pinned runtime patch refuses to
refresh, replace, or delete the managed credential. Each inference resolves
the active account again so a later CodexSwitch hot swap is observed without
restarting Clodex.

For the Anthropic branch, the helper resolves only CCS's internal loopback API
key into the VPS process environment; it never exposes a per-account
Anthropic token. CLIProxy chooses the account per request. The default
`CLODEX_VPS_ANTHROPIC_BACKEND=ccs` can be changed to `native` only as an
explicit rollback/diagnostic mode for a newly created pane.

Do not run Clodex's device-code login for this provider. Install and verify the
pinned package, exact runtime patch, stable helper, and metadata-only provider
configuration with `scripts/install-clodex-vps.sh`. The wrapper never copies
tokens, provider metadata, or Claude session contents to the Mac. See
`docs/architecture/clodex-codexswitch-credential-bridge.md` and
`docs/runbooks/clodex-vps.md` for readiness, launch, rollback, and upgrade
steps.

Remote Control is optional and not the default because it moves the UI to Claude web/mobile instead of the terminal TUI. Use `claude-vps --remote-control` only when that is intended; the unprefixed command launches the native Claude binary. Use `ccs claude-vps --remote-control` only when shared-account routing is intentional. Remote Control can work with CCS shared-account routing, but CCS must not expose the proxy token through `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY`; Claude Code treats those as API-key auth and may not activate Remote Control. The working contract is `ANTHROPIC_BASE_URL` pointed at the local CLIProxy path plus `ANTHROPIC_CUSTOM_HEADERS="Authorization: Bearer <ccs-token>"`, launched through the `remote-control` subcommand.

Like `codex-vps`, `claude-vps` must pass `ControlMaster=no`, `ControlPath=none`, and `ControlPersist=no` so interactive keystrokes do not share an old OpenSSH master connection. The command contract is explicit: `claude-vps` launches `/home/signul/.local/bin/claude` with the VPS account's native Claude authentication, while `ccs claude-vps` launches `/usr/bin/ccs claude` through the CCS account pool. The two lanes use distinct managed tmux sessions (`claude-vps` and `claude-vps-ccs`) so invoking one command can never silently attach to the other backend. The Mac CCS wrapper is a narrow dispatcher: only the `claude-vps` and legacy `claude2` subcommands are intercepted, and every other argument is passed unchanged to the installed CCS CLI.

Numbered native lanes use the short forms `claude-vps 2` and `claude-vps 3`. They map to tmux sessions `claude-vps-2` and `claude-vps-3`, default automatic continuation off, and therefore start fresh conversations without taking ownership of the primary lane's preferred thread. Repeating the same numbered command attaches to its existing numbered tmux session. An explicit `CLAUDE_VPS_AUTO_CONTINUE` override remains available for diagnostics, but concurrent-resume ownership checks still apply.

## cmux Managed SSH And Image Uploads

When `claude-vps` is invoked from a cmux terminal, it must use cmux's managed SSH workspace rather than spawning raw `mosh` directly. cmux's managed SSH connection owns the SCP upload lane used for dragged or pasted images and files; an ordinary mosh process nested in a cmux pane does not expose enough connection context for cmux to translate a local temporary path into a VPS path.

The launcher first bootstraps or verifies the existing backend-specific VPS tmux session over its noninteractive management SSH lane. It then calls the bundled cmux CLI with `cmux ssh <host> --ssh-option RequestTTY=force -- tmux attach-session ...`. The forced PTY is required by tmux. This preserves the existing native, CCS, Clodex, and numbered tmux identities while making the visible outer connection cmux-managed and SCP-aware. Re-running a command selects an existing connected cmux workspace with the same managed-session title instead of creating a duplicate.

This path uses the bundled CLI identified by `CMUX_BUNDLED_CLI_PATH` and is enabled automatically only when `CMUX_WORKSPACE_ID` is present. Set `CLAUDE_VPS_CMUX_MANAGED_SSH=0` to force the legacy inline SSH/mosh transport for diagnostics. Outside cmux, the existing transport selection is unchanged. cmux Remote tmux and `mosh-tmux` are optional newer capabilities, not prerequisites for image upload support in this launcher.

For the default `signul-vps` target, the launcher should prefer Tailscale's userspace SSH transport with `ProxyCommand=/Applications/Tailscale.app/Contents/MacOS/Tailscale nc %h %p`, targeting `signul@signul-hostinger-kvm4`, because the normal OpenSSH host can still be affected by stale mux masters and other SSH traffic. The default remote host, repo, Claude launcher, launcher subcommand, Remote Control name, Remote Control spawn mode, and Tailscale target can be overridden with `CLAUDE_VPS_REMOTE_HOST`, `CLAUDE_VPS_REMOTE_REPO`, `CLAUDE_VPS_REMOTE_CLAUDE`, `CLAUDE_VPS_REMOTE_CLAUDE_SUBCOMMAND`, `CLAUDE_VPS_REMOTE_CONTROL_NAME`, `CLAUDE_VPS_REMOTE_CONTROL_SPAWN`, `CLAUDE_VPS_TAILSCALE_HOST`, and `CLAUDE_VPS_TAILSCALE_TARGET`; set `CLAUDE_VPS_REMOTE_CONTROL_DEFAULT=1` only to intentionally make web/mobile Remote Control the default. `CLAUDE_VPS_BACKEND_MODE=ccs` is the explicit low-level equivalent of the `ccs claude-vps` dispatcher and is not the default. Set `CLAUDE_VPS_DISABLE_TAILSCALE_PROXY=1` to force the plain SSH host. Set `CLAUDE_VPS_DISABLE_TMUX=1` or use `claude-vps --raw` only for deliberate bare-terminal debugging; raw terminal sessions intentionally do not use the tmux auto-reconnect loop.

`claude-vps` must also normalize the remote terminal contract before launching Claude Code. It should set `TERM=xterm-256color`, preserve truecolor via `COLORTERM=truecolor`, force full color depth with `FORCE_COLOR=3`, apply the local terminal size to the remote PTY with `stty rows <rows> cols <cols>` when available, and leave `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN` unset unless `--classic` was explicitly requested. Claude Code is a terminal TUI; if it inherits a zero-sized PTY, a terminal type the remote runtime handles poorly, or an alternate-screen override that disagrees with persisted `/tui` state, redraws can repeat, wrap off-screen, drop chunks, and lose the anchored bottom statusline.

The native managed remote tmux session is named `claude-vps` and the CCS-routed session is named `claude-vps-ccs`, both under `/home/signul/SIGNUL`; each keeps a large scrollback history, enables mouse scrolling, hides tmux's own status bar by default, and keeps tmux's alternate screen enabled. Mouse wheel events pass through to Claude Code's fullscreen renderer when Claude has mouse tracking active; forcing tmux copy-mode is an opt-in fallback via `CLAUDE_VPS_TMUX_FORCE_COPY_SCROLL=1`. If a managed `tmux` session still exists but all panes are dead after a Claude `/exit`, the helper respawns that dead pane with the same backend-specific launch command instead of attaching to a `pane is dead` screen.

To reduce redraw corruption during reconnects and scrollback, `claude-vps` should set tmux's session and window history limits before pane creation, detach stale clients on attach, enable focus/extended-key support, keep aggressive resize enabled for the managed window, and avoid `tmux pipe-pane` by default so the renderer is not shadowed by a terminal-frame transcript. Do not force Claude Code's fullscreen/no-flicker renderer by default; `CLAUDE_VPS_CLAUDE_CODE_NO_FLICKER=1` or `claude-vps --fullscreen` is an opt-in mode. Do not disable Claude Code virtual scroll by default; `CLAUDE_VPS_CLAUDE_CODE_DISABLE_VIRTUAL_SCROLL=1` is an opt-in diagnostic for specific blank-region bugs, and it can remove useful in-app scrollback when combined with mouse passthrough. ANSI pane logging remains available with `CLAUDE_VPS_TMUX_LOG=1`, but `claude-vps-transcript` is the preferred reliable history path because it reads Claude's JSONL session store directly.

If an already-running `claude-vps --tmux` pane was created before the 200k history limit was applied, tmux cannot raise that pane's history limit in place. Use `claude-vps --repair-scrollback` at a safe stopping point to recreate the managed tmux session with the corrected history limit and resume Claude with `--continue`.

For reliable conversation review, use `claude-vps-transcript` instead of terminal scrollback. It renders the latest VPS Claude JSONL session from `/home/signul/.claude/projects/<repo-key>/*.jsonl` as plain text, so it is not affected by Claude Code fullscreen redraws, tmux copy-mode limits, or mosh/SSH terminal repaint issues. Common examples:

```bash
claude-vps-transcript -n 120
claude-vps-transcript -n 200 --no-tools | less
claude-vps-transcript --all --output ~/Downloads/claude-vps-transcript.txt
claude-vps-transcript -n 120 --copy
```

## signul ssh Terminal Stability

Use `signul ssh` for ad hoc interactive SIGNUL VPS shells that may run full-screen CLIs such as `claude`. It opens the same protected SSH lane as `claude-vps`: no OpenSSH multiplexing, forced interactive TTY, safe `xterm-256color` terminal type, truecolor enabled, and explicit initial PTY rows/columns.

Avoid launching full-screen TUIs from a plain shared `ssh signul-vps` session. That host is still useful for simple commands, but shared SSH masters and missing/zero PTY geometry can make terminal UIs redraw over themselves.

Read-only diagnosis and non-deployment operations include:

```bash
codexswitch-cli doctor
codexswitch-cli status
codexswitch-cli files doctor
codexswitch-cli files init
codexswitch-cli files send ./artifact.zip
codexswitch-cli files pull artifact.zip
codexswitch-cli files sync
codexswitch-cli poll [email-or-account-id]
```

Do not use direct `import`, `update-bundle`, `fix-codex`,
`install-patched-codex`, executable copying, or service commands as deployment
shortcuts. A helper may prepare a reviewed runtime or encrypted bundle artifact
only. Live installation, import, enablement, and restart must use
`scripts/install-linux.sh` with the same approved full Git SHA, immutable
runtime provenance, explicit activation flags, and a reviewed bundle SHA-256
when applicable. Unencrypted `.tar` bundles are local-test fixtures only.

## Linux Service Model

The Linux version should be a headless daemon plus a small CLI:

- `codexswitch-cli doctor`: verifies account store, auth path, SIGHUP fork, live CLI/app-server process eligibility, and quota polling.
- `codexswitch-cli daemon`: runs quota polling and swaps accounts automatically.
- `codexswitch-cli status`: prints active account, next account, live Codex CLI/app-server sessions, and reload readiness.
- `codexswitch-cli files doctor`: verifies the Mac/VPS SecureDrop roots and local transfer prerequisites without opening a public service.
- `codexswitch-cli files init`: creates the local and VPS SecureDrop directory trees with private permissions.
- `codexswitch-cli files send <path>`: uploads one regular file to the VPS over `rsync`/SSH with an atomic remote staging move and a local SHA-256 manifest.
- `codexswitch-cli files pull [name]`: downloads one file, or the remote outbox, from the VPS into the local SecureDrop inbox.
- `codexswitch-cli files sync`: pushes the local outbox to the VPS inbox and pulls the VPS outbox to the local inbox.
- `systemd --user` unit: keeps the daemon running on a VPS without root privileges.

There is no interactive `codexswitch-cli tui` entrypoint. Setup and diagnosis
use the explicit headless commands above so account, runtime, and deployment
mutations remain visible and scriptable.

The CLI still contains low-level account and runtime maintenance subcommands for
internal compatibility, but this document does not authorize invoking them as
an installation path. Repository deployment always enters through the
full-SHA immutable installer transaction above.

The checked-in persistent units enforce cgroup ceilings, not advisory watermarks
alone. The maintenance daemon uses `MemoryMax=6G` and `MemorySwapMax=2G`; the
session-bearing app-server uses `MemoryMax=14G`, `MemorySwapMax=2G`, and
`MemoryLow=512M`. The app-server release must contain
`codex-runtime-storage-leases-v1`, while every checked-in unit and installer
observer leaves local thread-store compression absent/off. A future activation
requires the separate quiescence and authorization contract; active sessions
are never candidates, and over-budget state remains measurement-only.

Codex updates must refresh both active VPS app-server lifecycles. The
`signul-codex-app-server.service` WebSocket listener on `127.0.0.1:8390` serves
the `codex-vps` tunnel, while ChatGPT's SSH remote connection runs
`codex app-server proxy` against the separately managed Unix-socket daemon at
`~/.codex/app-server-control/app-server-control.sock`. After a full-SHA
immutable activation replaces the patched runtime, only explicit installer
flags may restart the repository-managed systemd service. Any helper that
prepares the runtime stops at artifact preparation and must not replace a public
executable or restart a live endpoint. An update is not live until each
separately authorized active endpoint's reported app-server version matches the
activated release. Restart and health evidence remain endpoint-specific:
recovery of either lifecycle does not establish recovery of the other.

## Removed Non-Core Integration

Hermes is not a CodexSwitch responsibility or runtime dependency. Historical repository code coupled Hermes token synchronization to normal imports, swaps, rotations, daemon cycles, and the removed interactive TUI. The repository integration, TUI, and their tests have been removed.

Do not reintroduce or use that path as an example for new auth targets. An older live VPS release may still contain the historical behavior until a provenance-pinned CodexSwitch release is activated; this cleanup does not modify the separate Hermes installation, data, or processes.

## SecureDrop File Transfer

CodexSwitch SecureDrop is the Mac/VPS file-transfer path for artifacts, bundles, reports, and review files. It is intentionally not a public file server:

- Transport: `rsync -az --partial --timeout=30 -e ssh` over the dedicated `signul-vps-files` SSH/Tailscale host, with shell-quoted paths for compatibility with macOS' bundled `rsync`. `signul-vps-files` uses its own persistent OpenSSH control socket on port 22 so SecureDrop stays high-throughput without sharing the protected `codex-vps` interactive transport.
- Mac root: `~/CodexSwitch SecureDrop` by default.
- VPS root: `/home/signul/codexswitch-secure-files` by default.
- Folder contract:
  - `inbox`: files received by that machine.
  - `outbox`: files that machine wants the other side to receive.
  - `manifests`: local SHA-256 manifests for sent files.
  - `audit/transfers.jsonl`: append-only local transfer log.
  - `.incoming`: remote staging area used before atomic publish.
- Automation:
  - Mac `~/CodexSwitch SecureDrop/outbox` is watched by `com.codexswitch.securedrop.autopush`; regular files are pushed to `/home/signul/codexswitch-secure-files/inbox`, hash-verified, and then removed from the Mac outbox. If a matching remote file already exists, autopush treats the transfer as complete and removes the local queued copy without re-uploading it.
  - VPS `/home/signul/codexswitch-secure-files/outbox` is watched by `com.codexswitch.securedrop.autopull`; files are pulled to `~/CodexSwitch SecureDrop/inbox` and then removed from the VPS outbox. `~/Downloads/CodexSwitch SecureDrop` is a symlink to that inbox because macOS LaunchAgents can be TCC-blocked from writing directly into `~/Downloads`.
- Safety rules:
  - Regular files only for `send`; symlinks and directories are rejected.
  - Remote folder/file arguments reject path traversal and separators.
  - SHA-256 is computed with a fixed-size streaming buffer and the opened file's
    identity is revalidated before the manifest is accepted; transfer size does
    not determine process memory use.
  - The staged VPS file is hash-verified before atomic publish. A mismatch is
    removed from staging and never replaces the destination.
  - Local roots are `0700`; generated manifests and audit logs are `0600`.
  - Transfer audit entries use a dedicated cross-process lock, append-only I/O,
    and bounded rotation. Concurrent sends cannot rewrite or drop prior entries.
  - No raw token/account secrets are included in transfer logs.

Typical use from the Mac:

```bash
codexswitch-cli files init
codexswitch-cli files send ~/Downloads/source-mesh-blocker-breakthrough-20260518.zip
cp ~/Downloads/artifact.zip ~/CodexSwitch\ SecureDrop/outbox/   # auto-pushes to VPS inbox
codexswitch-cli files ls --folder inbox
codexswitch-cli files pull result.zip
codexswitch-cli files sync
```

On the VPS, agents can read files from `/home/signul/codexswitch-secure-files/inbox` and place return artifacts in `/home/signul/codexswitch-secure-files/outbox`. The Mac auto-pulls VPS outbox files, with manual fallback through `codexswitch-cli files pull` or `codexswitch-cli files sync`.

## Implementation Plan

1. Extract portable account scoring, auth-file generation, and quota polling into a shared core or a small Linux-native CLI.
2. Add Linux process discovery with the same denylist used by macOS status checks.
3. Add SIGHUP signaling for same-user Codex CLI processes whose executable has the verified hot-swap markers.
4. Add `doctor`, `status`, `swap`, and `daemon` commands.
5. Add a `systemd --user` unit template for VPS startup.
6. Keep macOS desktop app separate: official signing stays untouched, and desktop hot-swap only becomes green when an actual runtime reload hook is proven.

## SecureDrop Knowledge Sync

SecureDrop also supports AI-agent collaboration on multi-file captures and shared research notes:

- Directory send Mac -> VPS: `cs-send-dir <local-dir> [optional-name]` creates a SHA-256-verified tar archive and publishes it to `/home/signul/codexswitch-secure-files/inbox` through `.incoming/<uuid>` staging.
- Directory share VPS -> Mac: `cs-share-dir <local-dir> [optional-name]` creates a SHA-256-verified tar archive in `/home/signul/codexswitch-secure-files/outbox`; the Mac autopull LaunchAgent delivers it to `~/CodexSwitch SecureDrop/inbox`, visible from `~/Downloads/CodexSwitch SecureDrop`.
- Atomic extraction: `cs-extract <tarball> [--target <dir>]` verifies an adjacent `.sha256` file when present and extracts through an `.incoming-extract-*` staging directory.
- Knowledge mirror: `~/CodexSwitch SecureDrop/knowledge` mirrors with `/home/signul/codexswitch-secure-files/knowledge` about every 15 seconds.
- Conflict policy: SHA-256 equality is primary. If both sides changed the same file since the previous index, both versions are copied under `knowledge/.conflicts/<path>.<side>.<timestamp>` before last-writer-wins propagation.
- Status: `cs-knowledge-status` reports local/remote knowledge paths, file counts, conflict counts, and sync timer/LaunchAgent state.
- Watcher: `cs-watch <subdir> -- <command>` polls `.synclog.jsonl` and runs the command when a sync event touches that subdirectory.

Secret material remains excluded from SecureDrop knowledge: no OAuth tokens, raw account stores, private keys, or credentials unless Brendon explicitly confirms the risk.
