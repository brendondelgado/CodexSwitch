---
toc:
  - CodexSwitch
  - The Problem
  - The Solution
  - Features
  - How It Works
  - Getting Started
  - Project Structure
  - Documentation
  - Testing
  - License
cross_dependencies:
  - Sources/CodexSwitch/App/AppDelegate.swift
  - Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - Sources/CodexSwitch/Services/DesktopRuntimeReloadClient.swift
  - Sources/CodexSwitch/Views/SettingsView.swift
  - docs/sighup-safety.md
  - docs/README.md
  - docs/architecture/system-overview.md
  - docs/audits/2026-07-12-codebase-audit.md
version_control:
  updated_on: 2026-07-12
  updated_by: Codex
  status: working-tree
---

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-000?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white" alt="Swift 6.3">
  <img src="https://img.shields.io/badge/SwiftUI-✓-007AFF" alt="SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<h1 align="center">⚡ CodexSwitch</h1>

<p align="center">
  <strong>Multi-account quota manager for Codex CLI</strong><br>
  <em>Reduce quota interruptions with observable account selection and verified runtime reloads.</em>
</p>

<p align="center">
  <strong>Mac menu app and Linux/VPS coordinator</strong> · Native Swift + Rust CLI/daemon
</p>

---

## The Problem

Codex CLI uses a single `~/.codex/auth.json` file for authentication. If you have multiple ChatGPT Plus accounts, you're stuck manually swapping tokens when one runs out of quota. You lose flow, you waste time, and you miss the optimal switching window.

## The Solution

CodexSwitch manages multiple paid ChatGPT accounts through a native Mac menu app and a headless Linux/VPS coordinator. Each host observes quota, selects an eligible local account, commits the complete token bundle, and reloads verified Codex runtimes without requiring the user to exit and resume a session.

## Features

**📊 Live Quota Monitoring** — Polls ChatGPT usage with adaptive intervals and renders only the quota windows the service actually supplies. Five-hour and weekly windows are optional; weekly-only paid accounts remain fully supported.

**🔄 Automatic Switching** — Ranks confirmed usable accounts by plan, capacity, and stability, then atomically commits the selected account. Pro capacity is preferred for faster inference; scarce banked resets are protected near natural weekly recovery.

**⚡ Verified Hot-Swap** — Reloads only verified Codex CLI or app-server targets after the auth commit passes readback. Runtime identity and acknowledgement are part of the operation; status checks never signal processes.

**🖥 Desktop Runtime Reload** — Sends the complete access, refresh, and identity token set through the supported desktop app-server RPC path and records acknowledgement.

**🧭 Direct Desktop Routing** — Codex.app stays on stock OpenAI transport. CodexSwitch removes legacy desktop Headroom env bridges while preserving account hot-swap, bundled CLI repair, and plugin readiness patches.

**📊 Pooled Usage Meter** — Aggregates only observed windows and keeps Mac and VPS state distinct. Missing data is displayed as unknown or absent, never as zero or full.

**⚡ Menu Bar Icon** — SF Symbol bolt with color states:
| Color | Meaning |
|-------|---------|
| 🟢 Green | > 50% remaining |
| 🟡 Yellow | 20–50% remaining |
| 🟠 Orange | 5–20% remaining |
| 🔴 Red | < 5% remaining |

**🔔 macOS Notifications** — Notified on account swap, token refresh failure, and all-accounts-exhausted.

**🔐 Private Account Store** — Account records use a locked, validated, atomically replaced private store. Runtime token material is written only to the host's required Codex auth location with restrictive permissions.

**📋 Diagnostic Logging** — Daily log files at `~/.codexswitch/logs/` with swap events, SIGHUP delivery, polling errors, and token refreshes. Old logs auto-pruned after 7 days.

## How It Works

```text
observe quota/reset state -> rank eligible local accounts
                          -> lock and revalidate the account store
                          -> commit complete auth state atomically
                          -> read back the committed identity
                          -> reload verified local runtimes
                          -> publish acknowledgement and status
```

The Mac and VPS run this lifecycle independently. The Mac can display read-only VPS observations, but a remote session never becomes authority over Mac auth state. Diagnostics are observational, and updates or repairs require explicit commands.

The detailed component map and rationale live in the [system overview](docs/architecture/system-overview.md). The exact candidate and reset hierarchy lives in the [quota and reset policy](docs/architecture/quota-and-reset-policy.md).

## Getting Started

### Prerequisites

- macOS 15+
- Swift 6.3+ (Xcode 26+)
- One or more paid ChatGPT accounts with Codex access
- A SIGHUP-capable Codex CLI binary (writes `~/.codexswitch/sighup-verified` on startup)

### Build & Run

```bash
git clone https://github.com/brendondelgado/CodexSwitch.git
cd CodexSwitch
scripts/build-app.sh --install
```

The installer stages and verifies the complete signed app before replacing the
installed bundle, and restores the previous bundle if activation fails. Use
`CODEXSWITCH_SWIFTPM_JOBS=1` to keep compilation memory bounded on smaller Macs.

### Adding Accounts

1. Click the ⚡ menu bar icon → **Add Account**
2. Sign in with Google OAuth in the browser window that opens
3. Tokens are stored in the private CodexSwitch account store and written to Codex auth only during a verified activation
4. Repeat for each account

### Settings

Click the ⚙ gear icon in the popover to configure:
- **Launch at login** — start CodexSwitch automatically
- **Poll frequency** — 0.5x (aggressive) to 2.0x (conservative) multiplier
- **Desktop app repair** — optionally let CodexSwitch patch Codex.app after updates; desktop traffic remains direct OpenAI transport
- **Remove all accounts** — clear the CodexSwitch account store and reset local state

## Project Structure

```text
Sources/CodexSwitch/
├── App/
│   ├── CodexSwitchApp.swift        # @main entry point
│   └── AppDelegate.swift           # Orchestrates services, swap logic, UI
├── Models/
│   ├── AccountManager.swift        # @Observable account state + sync
│   ├── AuthFile.swift              # Codex auth.json schema
│   ├── CodexAccount.swift          # Account model with quota data
│   ├── QuotaSnapshot.swift         # Optional semantic quota windows
│   └── SwapEvent.swift             # Swap history records
├── Services/
│   ├── AccountImporter.swift       # Import from ~/.codex/auth.json
│   ├── CLIStatusChecker.swift      # Verify CLI can read current auth
│   ├── CodexVersionChecker.swift   # Detect and prepare compatible Codex runtimes
│   ├── DesktopPatchManager.swift   # Desktop compatibility status and patching
│   ├── DesktopRuntimeReloadClient.swift # Complete-token desktop reload RPC
│   ├── KeychainStore.swift         # File account repository + legacy migration
│   ├── NotificationManager.swift   # macOS notification delivery
│   ├── OAuthLoginManager.swift     # Google OAuth login flow
│   ├── QuotaPoller.swift           # Adaptive HTTP polling (actor)
│   ├── SwapEngine.swift            # Scoring, auth write, SIGHUP signaling
│   ├── SwapLog.swift               # Structured diagnostic logging
│   ├── SwapStatistics.swift        # Swap frequency + pattern analytics
│   ├── TokenRefresher.swift        # OAuth token refresh
│   └── UsageResponseParser.swift   # ChatGPT usage API response parser
└── Views/
    ├── AccountCardView.swift       # Account card with drain bars + reset times
    ├── DrainBarView.swift          # Animated quota drain bar
    ├── PooledUsageMeterView.swift  # Aggregate pool metrics + Pro comparison
    ├── PopoverContentView.swift    # 2×3 grid popover with Next Up / Next Available
    ├── SettingsView.swift          # Preferences window
    ├── StatusBarController.swift   # Menu bar icon + color state management
    └── SwapStatsView.swift         # Swap history statistics display

crates/codexswitch-cli/
├── src/                            # Linux/VPS coordinator, policy, reload, updater
└── systemd/                        # Repository-owned user service definitions

scripts/                            # Transport, deployment, patching, and focused tests
docs/                               # Canonical architecture wiki, runbooks, plans, and audits
```

## Documentation

The canonical maintainer and agent wiki starts at [`docs/README.md`](docs/README.md). Architecture contracts define product policy and ownership; runbooks define operational procedures; audits and plans track migration state without redefining behavior.

Claude and other repository agents should begin with [`CLAUDE.md`](CLAUDE.md), which routes questions to the smallest authoritative document and records live-session and deployment safety boundaries.

## Testing

```bash
# Requires full Xcode, including SwiftUI and Testing macro plugins.
swift test

# Linux/VPS core without writing build artifacts into the repository.
CARGO_TARGET_DIR=/tmp/codexswitch-target CARGO_BUILD_JOBS=1 \
  cargo test --locked --offline -p codexswitch-cli

# Transport, deployment, SecureDrop, and patcher fixtures.
python3 -m unittest discover -s scripts -p 'test_*.py'
```

The audit also uses a standalone Swift banked-reset harness when the selected Command Line Tools installation lacks `SwiftUIMacros` or `TestingMacros`. See the [codebase audit](docs/audits/2026-07-12-codebase-audit.md) for the current verified counts and environment limitations.

## License

MIT

---

<p align="center">
  <em>Built with Claude Code</em>
</p>
