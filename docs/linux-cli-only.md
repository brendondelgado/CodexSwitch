---
toc:
  - Linux CLI-Only CodexSwitch
  - Target States
  - Platform Contract
  - Recommended VPS Setup
  - Linux Service Model
  - Hermes Agent Auth Target
  - SecureDrop File Transfer
  - codex-vps Tunnel Stability
  - claude-vps Remote CLI Entry
  - Implementation Plan
cross_dependencies:
  - scripts/securedrop/cs-autopush
  - scripts/codex-vps
  - scripts/claude-vps
  - Sources/CodexSwitch/Services/SwapEngine.swift
  - Sources/CodexSwitch/Services/CodexVersionChecker.swift
  - Sources/CodexSwitch/Services/CLIStatusChecker.swift
  - docs/superpowers/plans/2026-04-29-desktop-external-hot-swap.md
  - docs/superpowers/plans/2026-04-30-desktop-linux-token-transfer.md
  - docs/runbooks/codexswitch-hot-swap-verification.md
version_control:
  branch: feat/codex-native
  commit: 58da612
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

For a VPS devbox, use Linux. This keeps the same proven hot-swap mechanism as macOS CLI:

```bash
git clone <codexswitch-repo>
cd CodexSwitch
cargo build --release -p codexswitch-cli
install -Dm755 target/release/codexswitch-cli ~/.local/bin/codexswitch-cli
codexswitch-cli import ~/codexswitch-linux-devbox-*.csbundle
codexswitch-cli doctor
codexswitch-cli tui
```

Once this repository is hosted, the intended one-liner is:

```bash
curl -fsSL https://raw.githubusercontent.com/brendondelgado/CodexSwitch/main/scripts/install-linux.sh | bash
```

If the encrypted bundle is already copied to the VPS, install and import in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/brendondelgado/CodexSwitch/main/scripts/install-linux.sh | bash -s -- ~/codexswitch-linux-devbox-20260430-055931.csbundle
```

The daemon should write `auth.json`, verify each running Codex runtime contains `sighup-verified` and `SIGHUP: auth reloaded`, then require a fresh live reload acknowledgement before reporting readiness. Marker strings prove patch installation only; `.codexswitch/hotswap-ack/<pid>.json` proves the running process observed a reload. App-server runtimes are used by clients such as KittyLitter; if they are stock/unpatched, `doctor` and the TUI must report not ready instead of showing a false green state.

Account transfer should use the encrypted desktop export flow from `docs/superpowers/plans/2026-04-30-desktop-linux-token-transfer.md`, not a plaintext copy of `~/.codexswitch/accounts.json`.

## codex-vps Tunnel Stability

The Mac-side `codex-vps` helper uses local port `18390` as an SSH-forwarded WebSocket path to the VPS app-server on `127.0.0.1:8390`. All CodexSwitch-managed control-plane and interactive SSH processes must opt out of OpenSSH connection sharing with `ControlMaster=no`, `ControlPath=none`, and `ControlPersist=no`; the tunnel and direct TTY fallback are transport dependencies for live Codex sessions and must not ride on a shared master connection that can be closed or back-pressured by unrelated SSH activity. Bulk transfer helpers may still use a separate multiplexed SSH profile when throughput matters more than keystroke latency.

The interactive tunnel supervisor should also debounce health checks. A single slow `/healthz` probe can happen during local lag or Tailscale jitter and must not immediately kill the tunnel. Reopen the tunnel only after several consecutive failed probes.

For this helper, avoid implicit Tailscale SSH browser-check fallback. Tailscale SSH check mode is useful for ad hoc high-risk access, but automation should use normal OpenSSH over the encrypted Tailnet with key auth. If a human intentionally wants the Tailscale SSH fallback, require an explicit `CODEX_VPS_ALLOW_TAILSCALE_SSH_CHECK=1` opt-in.

## claude-vps Remote CLI Entry

The Mac-side `claude-vps` helper provides the same one-word VPS entrypoint for Claude Code that `codex-vps` provides for Codex. Claude Code is a terminal CLI rather than a WebSocket app-server, so `claude-vps` opens an interactive SSH TTY, changes to `/home/signul/SIGNUL`, and execs `/home/signul/.local/bin/claude` through the VPS default `bash`.

Like `codex-vps`, `claude-vps` must pass `ControlMaster=no`, `ControlPath=none`, and `ControlPersist=no` so interactive keystrokes do not share an old OpenSSH master connection. For the default `signul-vps` target, it should prefer Tailscale's userspace SSH transport with `ProxyCommand=/Applications/Tailscale.app/Contents/MacOS/Tailscale nc %h %p`, targeting `signul@signul-hostinger-kvm4`, because the normal OpenSSH host can still be affected by stale mux masters and other SSH traffic. The default remote host, repo, Claude binary, and Tailscale target can be overridden with `CLAUDE_VPS_REMOTE_HOST`, `CLAUDE_VPS_REMOTE_REPO`, `CLAUDE_VPS_REMOTE_CLAUDE`, `CLAUDE_VPS_TAILSCALE_HOST`, and `CLAUDE_VPS_TAILSCALE_TARGET`; set `CLAUDE_VPS_DISABLE_TAILSCALE_PROXY=1` to force the plain SSH host.

The implemented Linux CLI supports:

```bash
codexswitch-cli doctor
codexswitch-cli import <codexswitch-linux-devbox.csbundle>
codexswitch-cli update-bundle <codexswitch-linux-devbox.csbundle>
codexswitch-cli status
codexswitch-cli files doctor
codexswitch-cli files init
codexswitch-cli files send ./artifact.zip
codexswitch-cli files pull artifact.zip
codexswitch-cli files sync
codexswitch-cli hermes status
codexswitch-cli hermes apply
codexswitch-cli hermes apply --restart-gateway
codexswitch-cli poll [email-or-account-id]
codexswitch-cli swap <email-or-account-id>
codexswitch-cli tui
codexswitch-cli restart-codex
codexswitch-cli restart-codex --yes --include-app-server
codexswitch-cli fix-codex
codexswitch-cli fix-codex --yes
codexswitch-cli install-patched-codex --source ~/.local/share/codexswitch/codex-source --yes --replace-system-entry --replace-npm-vendor
codexswitch-cli daemon --interval-seconds 5
```

Encrypted imports support CodexSwitch `.csbundle` files directly and prompt for the passphrase on the terminal. `.age` files are also accepted through the system `age` binary. Unencrypted `.tar` imports are intended only for local tests.

## Linux Service Model

The Linux version should be a headless daemon plus a small CLI:

- `codexswitch-cli doctor`: verifies account store, auth path, SIGHUP fork, live CLI/app-server process eligibility, and quota polling.
- `codexswitch-cli update-bundle <bundle>`: replaces stale account tokens from a fresh encrypted desktop export and rewrites `auth.json`.
- `codexswitch-cli restart-codex`: dry-runs restart targets; add `--yes` to terminate live Codex CLI sessions and `--include-app-server` when the Codex app-server also needs restart.
- `codexswitch-cli fix-codex`: probes `codex --version`; add `--yes` to reinstall a known-good `@openai/codex` if the native binary is killed/broken at startup.
- `codexswitch-cli install-patched-codex`: builds the SIGHUP-capable Codex fork on the VPS, installs it under `~/.local/share/codexswitch/patched-codex`, replaces `/usr/bin/codex` with a guarded launcher when requested, and replaces the npm package's native vendor binary when requested so `codex app-server` hot-swaps too.
- `codexswitch-cli daemon`: runs quota polling and swaps accounts automatically.
- `codexswitch-cli status`: prints active account, next account, live Codex CLI/app-server sessions, and reload readiness.
- `codexswitch-cli files doctor`: verifies the Mac/VPS SecureDrop roots and local transfer prerequisites without opening a public service.
- `codexswitch-cli files init`: creates the local and VPS SecureDrop directory trees with private permissions.
- `codexswitch-cli files send <path>`: uploads one regular file to the VPS over `rsync`/SSH with an atomic remote staging move and a local SHA-256 manifest.
- `codexswitch-cli files pull [name]`: downloads one file, or the remote outbox, from the VPS into the local SecureDrop inbox.
- `codexswitch-cli files sync`: pushes the local outbox to the VPS inbox and pulls the VPS outbox to the local inbox.
- `codexswitch-cli swap <account>`: manually writes `auth.json` and reloads live CLI sessions.
- `codexswitch-cli hermes status`: checks Hermes OpenAI Codex auth/config state without printing secrets.
- `codexswitch-cli hermes apply`: writes the active CodexSwitch account into Hermes' OpenAI Codex OAuth store.
- `systemd --user` unit: keeps the daemon running on a VPS without root privileges.

## Hermes Agent Auth Target

Hermes Agent is a separate auth target from Codex CLI. CodexSwitch keeps Codex hot-swap behavior unchanged, then mirrors the selected OpenAI/ChatGPT OAuth token into Hermes' own secret store:

- Primary Hermes token file: `~/.hermes/auth.json`.
- Existing Hermes `.env`: backed up and permission-hardened to `0600`, but unrelated keys are not rewritten.
- Hermes provider config: `model.provider = "openai-codex"` and `model.default = "gpt-5.5"`.
- Gateway lifecycle: `codexswitch-cli hermes apply --restart-gateway` restarts `hermes gateway` only.
- TUI lifecycle: CodexSwitch does not kill `hermes --tui`; status/apply output tells the user to restart/resume the TUI if it is running.

The intended VPS attach helper remains separate from `codex-vps`:

```bash
ssh -t signul-vps 'tmux new -A -s hermes "hermes --tui"'
```

`codexswitch-cli import`, `update-bundle`, `swap`, `rotate-now`, and the daemon all attempt Hermes sync automatically when `~/.hermes` exists. Missing Hermes is treated as "not installed", not as a Codex swap failure.

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
  - Local roots are `0700`; generated manifests and audit logs are `0600`.
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
