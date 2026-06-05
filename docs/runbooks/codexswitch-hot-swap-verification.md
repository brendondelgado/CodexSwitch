---
toc:
  - CodexSwitch Hot-Swap Verification Runbook
  - Why This Exists
  - Readiness Contract
  - Platform Gates
  - Account State Boundaries
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
  - crates/codexswitch-cli/src/readiness.rs
  - crates/codexswitch-cli/src/reload.rs
  - crates/codexswitch-cli/src/codex_update.rs
  - crates/codexswitch-cli/src/daemon.rs
  - crates/codexswitch-cli/src/quota.rs
  - crates/codexswitch-cli/src/account_store.rs
  - crates/codexswitch-cli/src/patched_codex.rs
  - Sources/CodexSwitch/Services/UsageResponseParser.swift
  - Sources/CodexSwitch/Services/KeychainStore.swift
  - Sources/CodexSwitch/Services/SwapEngine.swift
  - Sources/CodexSwitch/Models/AccountManager.swift
  - Sources/CodexSwitch/Services/LinuxDevboxMonitor.swift
  - Sources/CodexSwitch/Services/SingleInstanceLock.swift
  - Tests/CodexSwitchTests/SwapEngineTests.swift
  - Tests/CodexSwitchTests/SingleInstanceLockTests.swift
  - Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - Tests/CodexSwitchTests/DesktopRuntimeHotSwapStateTests.swift
  - docs/linux-cli-only.md
  - docs/sighup-safety.md
version_control:
  branch: feat/codex-native
  commit: 58da612
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

## Platform Gates

CodexSwitch must evaluate these independently:

- **Mac desktop:** official OpenAI signing and plugin health are separate from desktop hot-swap. The desktop status must not show green unless the live desktop runtime acknowledges reload.
- **Mac local CLI:** only native Codex CLI binaries are signal targets. Wrapper shells, SSH clients, and `--remote` clients are not the VPS runtime.
- **Mac remote client:** a `codex --remote` process on the Mac is a transport client, not the account-bearing app-server. It must not be treated as the VPS hot-swap target.
- **Linux VPS app-server:** the app-server process is the primary account-bearing runtime for KittyLitter/remote sessions and must acknowledge reload.
- **Linux patched CLI:** `/home/signul/.local/share/codexswitch/patched-codex/codex ...` is a native Codex runtime even when launched with arguments such as `--yolo`. Detection must inspect the executable token, not only exact command-line suffixes. The app-server detector must also accept `app-server --remote-control --listen ws://...`; otherwise the VPS can write `auth.json` but report `signaled 0 Codex hot-swap process(es)`.
- **Background ACK repair:** the daemon may repair missing ACKs for live interactive CLI sessions. It must not repeatedly signal an app-server that has not proven live reload support, because a supervised WebSocket app-server can exit on `SIGHUP` and enter a disconnecting restart loop.
- **VPS SSH transport:** CodexSwitch-managed readiness probes, swap commands, tunnels, and direct remote TTY fallbacks must pass `ControlMaster=no`, `ControlPath=none`, and `ControlPersist=no`. User shell aliases may multiplex, but app-managed Codex transports must not inherit a shared OpenSSH master where unrelated channels can add latency or close the session.

## Account State Boundaries

Mac CodexSwitch and Linux `codexswitch-cli` run the same eligibility rules, but their persisted runtime state is host-local. They should converge on quota for a shared token because both poll `https://chatgpt.com/backend-api/wham/usage`, but they do **not** automatically share active-account selection, runtime acknowledgements, daemon state, or stale `/status` banners from an existing Codex session.

- A background VPS readiness check may display the VPS active email, but it must not set the Mac active account, rewrite local `auth.json`, or start a Mac auto-swap.
- While a live `codex-vps` remote session is intentionally mirroring VPS account state in the menu bar, the VPS daemon owns automatic rotation. The Mac must not execute a second auto-swap from that mirrored state or issue repeated account-swapped notifications.

When the Mac menu app and VPS CLI disagree, compare safe evidence in this order:

1. Token hash prefix for the account on both hosts.
2. Live `wham/usage` primary and secondary windows for that token.
3. `auth-diagnostics` active account and `auth.json` hash on the host that sent the request.
4. The active Codex session's own `/status`, treating any "limits may be stale" warning as non-authoritative until rechecked.

## Menu App Process Boundaries

The Mac menu app must have exactly one live poller process. A duplicate CodexSwitch process can double-poll quota, double-sync VPS state, and produce contradictory menu updates even when each process is individually running the correct code.

CodexSwitch acquires a single-instance lock before it starts account loading, quota polling, VPS mirroring, patch checks, or status-item timers. If LaunchServices starts a second copy, that process must exit before services start. Reinstall verification should include both the installed bundle version and a one-PID process check for `/Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch`.

## Quota Snapshot Validity

`/backend-api/wham/usage` can return placeholder quota data while the backend is stale or unable to report usage for the selected account. A placeholder primary window has `used_percent = 0`, no real window duration, and a reset time equal to the fetch time. CodexSwitch must treat that as unavailable data, not as `100%` remaining quota.

This rule applies at every boundary: the Swift parser, Rust CLI parser, account-store load/save, VPS account-state mirror, menu-bar display, pooled usage math, and swap candidate selection. Placeholder snapshots must not be persisted, mirrored into a healthy local snapshot, shown as green/100%, used as next-up, or used to block a necessary swap.

## Runtime Blockers and Reauth

Quota-unavailable is not the same state as reauthentication-required. Placeholder quota windows are transient backend data failures and should be retried with backoff, especially for inactive Pro accounts that have no trusted quota snapshot yet.

Authentication failures are different. A 401/token-expired/token-invalidated account must be marked runtime-unusable, excluded from swap candidates and pooled usage, persisted, mirrored between Mac and VPS, and shown as `Needs login` even if an old quota snapshot still exists. Stale exhausted reset text must never hide a known auth blocker.

## Quota Polling Cadence

The daemon may use a slower normal polling interval while the active account has comfortable quota, but it must tighten as soon as either tracked quota window falls below the danger band:

- `<= 5%` remaining: poll every `2s`.
- `<= 2%` remaining: poll every `1s`.

When the user-visible status would round remaining quota to `1%`, or when any hard runtime usage-limit signal appears, it must rotate before the next user request depends on that exhausted account.

Inactive accounts need a separate upgrade-watch cadence because plan purchases happen out-of-band while CodexSwitch is already running. Any inactive account below Pro is re-polled at least every `15s`; if either window is exhausted, it is re-polled every `5s`. When the Mac app detects a plan-type change, it also asks the configured Linux devbox to poll that same account immediately so both stores converge without waiting for the next VPS daemon tick.

## Mac Menubar VPS Freshness

When a Mac-side Codex client is attached to the VPS app-server, the menubar must mirror the VPS account store from `codexswitch-cli account-state` cadence, not the slower readiness cadence. The Mac client is only a transport, but its presence means the user is actively watching or driving VPS traffic from the Mac; stale active-account UI is therefore misleading.

- Active VPS remote client detected: fetch sanitized VPS account state every `5s`, with overlapping checks suppressed.
- During that active remote mirror, auto-swap execution stays on the VPS; the Mac view reflects the result without initiating its own competing swap.
- No active VPS remote client detected: keep the normal `60s` readiness cadence.
- The detector must include both `codex-vps` terminal clients and Codex.app-launched `codex --remote ws://100.95.84.123:8390 ...` clients.
- SSH/Tailscale tunnel helper processes are transport plumbing and must not be mistaken for an active Codex remote client.

## Pool Capacity Math

The pooled usage meter must not count every account as one Plus account. It uses Plus-equivalent capacity by plan:

- Plus: `1x` 5h and weekly capacity.
- Pro 5x / `$100`: `10x` 5h and weekly capacity through May 31, 2026, then `5x`.
- Pro 20x / `$200`: `25x` 5h capacity through May 31, 2026, and `20x` weekly capacity; after the promo, both are `20x`.
- Free/Go accounts are excluded from nominal Plus-equivalent math unless OpenAI publishes a stable Plus-equivalent multiplier for them.

The UI should show both single-Plus and single-Pro comparisons so a mixed pool of Plus, Pro 5x, and Pro 20x accounts does not look like a pile of identical Plus accounts.

## Candidate Selection

Candidate scoring is tier-first and quota-aware: Pro outranks Pro Lite, Pro Lite outranks Plus, Plus outranks Free, and unusable/exhausted accounts are excluded. Within the same plan tier, when two candidates have comparable 5h quota and weekly quota, prefer the account whose 5h window resets sooner. That burns the older/shorter-lived usable window first instead of preserving it until it expires unused.

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
- [ ] Each live target has a fresh `.codexswitch/hotswap-ack/<pid>.json` acknowledgement.
- [ ] A forced rotation changes the active account and signals the expected process count.
- [ ] The app-server journal or ack file proves the signal handler ran after the rotation.
- [ ] The next real Codex request or remote compact uses the new account and does not repeat the old usage-limit error.
- [ ] Mac desktop, Mac CLI, Mac remote client, and VPS app-server statuses are checked separately.

## Regression Requirements

Every future hot-swap change must include tests for:

- Marker-only binaries are **not** ready without live acknowledgement.
- App-server patching targets the `AuthManager` captured by `MessageProcessor`, not an earlier preload/auth probe.
- Expired or quota-exhausted active accounts rotate to usable candidates and rewrite `auth.json`.
- Runtime `UsageLimitReached` inside Codex rotates once, reloads the active `AuthManager`, and retries the turn before surfacing an error.
- Active quota at or below 5% uses 2-second polling, at or below 2% uses 1-second polling, and quota displayed as `1%` rotates immediately.
- Inactive below-Pro accounts are re-polled for out-of-band plan upgrades within 15 seconds, and exhausted below-Pro accounts within 5 seconds.
- Mac plan changes trigger a safe `codexswitch-cli poll <account>` on the configured Linux devbox without transferring or logging secrets.
- Mac menubar active-account display follows VPS account-state within a few seconds while a Codex.app or CLI `--remote` VPS session is active.
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
