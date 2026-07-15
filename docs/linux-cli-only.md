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
  - signul ssh Terminal Stability
  - Implementation Plan
cross_dependencies:
  - docs/README.md
  - docs/architecture/system-overview.md
  - docs/architecture/runtime-and-host-ownership.md
  - scripts/securedrop/cs-autopush
  - scripts/codex-vps
  - scripts/claude-vps
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
  last_updated: 2026-07-13
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

ChatGPT's built-in SSH remote is a separate transport and lifecycle: it reaches the VPS through a `codex app-server proxy` connected to `~/.codex/app-server-control/app-server-control.sock`, not through the port-8390 `codex-vps` service. A successful `codex-vps` restart or `/healthz` probe therefore does not prove the built-in remote recovered, and recycling ChatGPT's local SSH bridge does not prove the port-8390 service recovered. Both the port-8390 listener and the built-in `unix://` daemon are account-bearing reload targets when running, while their `app-server proxy` transport helpers are not. A swap is converged only after every discovered listener acknowledges the same credential generation. Diagnose and verify the endpoint used by the failing client.

Port `18390` is ownership-protected. Before opening a tunnel, the helper must atomically acquire `~/.codexswitch/codex-vps-tunnel-18390.lock` and atomically publish owner, supervisor, and SSH-child metadata inside it. Cleanup may signal an SSH PID only when the lock token still belongs to the current helper and the PID, parent PID, SSH command, forward specification, and listening socket all match that metadata. A listener that cannot be proved to be this helper's current SSH child is unknown: refuse to attach or replace it, report its PID, and leave it running. A dead owner record may be reclaimed only when no process is listening on `18390`.

The interactive supervisor owns SSH as a background child and monitors both that exact process and `/healthz` while the remote client runs. Cleanup traps must be installed before the startup readiness wait so an interrupt or failed startup cannot orphan the child or lock. Health probes use an 8-second default timeout and are debounced across four consecutive failures, configurable with `CODEX_VPS_TUNNEL_HEALTH_TIMEOUT_SECONDS`, `CODEX_VPS_TUNNEL_HEALTH_FAILURE_LIMIT`, and `CODEX_VPS_TUNNEL_HEALTH_INTERVAL_SECONDS`. Tunnel creation or health failure retries use bounded exponential backoff, starting at 2 seconds and capped at 30 seconds via `CODEX_VPS_TUNNEL_RECONNECT_DELAY` and `CODEX_VPS_TUNNEL_RECONNECT_DELAY_MAX`; startup readiness may wait up to 90 seconds via `CODEX_VPS_TUNNEL_STARTUP_TIMEOUT_SECONDS`. Reconnecting the local SSH tunnel must never start or restart the remote app-server. Remote service restart remains an explicit `codex-vps restart` operation.

The wrapper must keep owning the local remote-client process instead of replacing itself with a one-shot `exec`. If the VPS app-server restarts or the WebSocket closes, the local Codex client can exit even after the SSH tunnel has recovered. By default, `codex-vps` should reconnect after abnormal client exits, stop on clean `/exit` or terminal interrupt statuses, and use bounded exponential delays starting at `CODEX_VPS_RECONNECT_DELAY=2` and capped by `CODEX_VPS_RECONNECT_DELAY_MAX=30`. `CODEX_VPS_AUTO_RECONNECT=0` and `CODEX_VPS_RECONNECT_MAX` remain available for diagnostics and bounded retry counts.

Before attaching, `codex-vps` must also check root filesystem headroom on the VPS. A full or near-full disk can make Codex's rollout/session writer fail, which can sever the app-server WebSocket and leave the local client looking like a random tunnel drop. The default contract is: warn at 90% used, refuse attach below 20GB free or at 97% used, and allow an explicit `CODEX_VPS_SKIP_REMOTE_DISK_PREFLIGHT=1` override only for emergency diagnostics.

For this helper, avoid implicit Tailscale SSH browser-check fallback. Tailscale SSH check mode is useful for ad hoc high-risk access, but automation should use normal OpenSSH over the encrypted Tailnet with key auth. If a human intentionally wants the Tailscale SSH fallback, require an explicit `CODEX_VPS_ALLOW_TAILSCALE_SSH_CHECK=1` opt-in.

## claude-vps Remote CLI Entry

The Mac-side `claude-vps` helper provides the same one-word VPS entrypoint for Claude Code that `codex-vps` provides for Codex. Plain `claude-vps` opens a persistent remote tmux session through CCS: it opens the protected VPS SSH lane, changes to `/home/signul/SIGNUL`, and launches `/usr/bin/ccs claude --continue` inside the managed `claude-vps` tmux session. This keeps CCS/CLIProxy account sharing in the model path while keeping the Claude Code process alive if the Mac sleeps, disconnects, or changes networks.

`--continue` is only a resume selector; it has no renderer-performance meaning. Plain `claude-vps` and `claude-vps --tmux` use the persistent tmux workflow; with no Claude arguments those modes add `--continue` so the latest `/home/signul/SIGNUL` conversation opens. Use `claude-vps --raw`, `claude-vps --terminal`, or `claude-vps --tui` only for deliberate direct-terminal debugging where renderer fidelity matters more than process persistence. Use `claude-vps --fullscreen` only to explicitly opt into Claude's fullscreen alternate-screen renderer.

Use `claude-vps -yolo` when the persistent VPS session should launch Claude Code with `--dangerously-skip-permissions`. The `-yolo` flag is consumed by the Mac helper and forwarded through the tmux launch environment, so it keeps the persistent CCS-backed path instead of turning into a one-off raw terminal argument. `claude-vps --dangerously-skip-permissions` and `claude-vps --yolo` are accepted aliases for the same behavior. If a non-yolo `claude-vps` pane is already running, `-yolo` does not kill it implicitly; use `/exit` first or run `claude-vps --repair-scrollback -yolo` at a safe stopping point to recreate the managed pane with the yolo flag.

Remote Control is optional and not the default because it moves the UI to Claude web/mobile instead of the terminal TUI. Use `claude-vps --remote-control` only when that is intended; it launches `/usr/bin/ccs claude remote-control --name signul-vps --spawn=same-dir`. Remote Control can work with CCS shared-account routing, but CCS must not expose the proxy token through `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY`; Claude Code treats those as API-key auth and may not activate Remote Control. The working contract is `ANTHROPIC_BASE_URL` pointed at the local CLIProxy path plus `ANTHROPIC_CUSTOM_HEADERS="Authorization: Bearer <ccs-token>"`, launched through the `remote-control` subcommand.

Like `codex-vps`, `claude-vps` must pass `ControlMaster=no`, `ControlPath=none`, and `ControlPersist=no` so interactive keystrokes do not share an old OpenSSH master connection. For the default `signul-vps` target, it should prefer Tailscale's userspace SSH transport with `ProxyCommand=/Applications/Tailscale.app/Contents/MacOS/Tailscale nc %h %p`, targeting `signul@signul-hostinger-kvm4`, because the normal OpenSSH host can still be affected by stale mux masters and other SSH traffic. The default remote host, repo, Claude launcher, launcher subcommand, Remote Control name, Remote Control spawn mode, and Tailscale target can be overridden with `CLAUDE_VPS_REMOTE_HOST`, `CLAUDE_VPS_REMOTE_REPO`, `CLAUDE_VPS_REMOTE_CLAUDE`, `CLAUDE_VPS_REMOTE_CLAUDE_SUBCOMMAND`, `CLAUDE_VPS_REMOTE_CONTROL_NAME`, `CLAUDE_VPS_REMOTE_CONTROL_SPAWN`, `CLAUDE_VPS_TAILSCALE_HOST`, and `CLAUDE_VPS_TAILSCALE_TARGET`; set `CLAUDE_VPS_REMOTE_CONTROL_DEFAULT=1` only to intentionally make web/mobile Remote Control the default, or set `CLAUDE_VPS_REMOTE_CLAUDE=/home/signul/.local/bin/claude` to intentionally bypass CCS and use native Claude. Set `CLAUDE_VPS_DISABLE_TAILSCALE_PROXY=1` to force the plain SSH host. Set `CLAUDE_VPS_DISABLE_TMUX=1` or use `claude-vps --raw` only for deliberate bare-terminal debugging; raw terminal sessions intentionally do not use the tmux auto-reconnect loop.

`claude-vps` must also normalize the remote terminal contract before launching Claude Code. It should set `TERM=xterm-256color`, preserve truecolor via `COLORTERM=truecolor`, force full color depth with `FORCE_COLOR=3`, apply the local terminal size to the remote PTY with `stty rows <rows> cols <cols>` when available, and set `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` unless `--fullscreen` was explicitly requested. Claude Code is a terminal TUI; if it inherits a zero-sized PTY, a terminal type the remote runtime handles poorly, or an alternate-screen renderer that fights the outer terminal scrollback, redraws can repeat, wrap off-screen, drop chunks, and lose the anchored bottom statusline.

The managed remote tmux session is named `claude-vps` under `/home/signul/SIGNUL`; it keeps a large scrollback history, enables mouse scrolling, hides tmux's own status bar by default, and keeps tmux's alternate screen enabled. Mouse wheel events pass through to Claude Code's fullscreen renderer when Claude has mouse tracking active; forcing tmux copy-mode is an opt-in fallback via `CLAUDE_VPS_TMUX_FORCE_COPY_SCROLL=1`. If the managed `tmux` session still exists but all panes are dead after a Claude `/exit`, the helper respawns that dead pane with the same launch command instead of attaching to a `pane is dead` screen.

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
`codex-runtime-storage-leases-v1` and enables lease-aware local thread-store
compression. Active sessions are never cleanup candidates; inactive stable
rollouts move through bounded lossless hot retention, and over-budget state
fails closed instead of deleting unarchived history.

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
