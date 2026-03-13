<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-000?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white" alt="Swift 6.3">
  <img src="https://img.shields.io/badge/SwiftUI-✓-007AFF" alt="SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<h1 align="center">⚡ CodexSwitch</h1>

<p align="center">
  <strong>Multi-account quota manager for Codex CLI</strong><br>
  <em>Never hit a rate limit again — CodexSwitch monitors your ChatGPT accounts and auto-switches to the one with the most remaining quota.</em>
</p>

<p align="center">
  <strong>macOS only</strong> · Native Swift + SwiftUI · No Electron, no web views
</p>

---

## The Problem

Codex CLI uses a single `~/.codex/auth.json` file for authentication. If you have multiple ChatGPT Plus accounts, you're stuck manually swapping tokens when one runs out of quota. You lose flow, you waste time, and you miss the optimal switching window.

## The Solution

CodexSwitch lives in your macOS menu bar and manages multiple ChatGPT Plus accounts simultaneously. It polls each account's quota, visualizes remaining capacity with drain bars, and **automatically swaps to the best account** when the active one runs dry — with SIGHUP hot-swap so the CLI picks up new tokens instantly without restarting.

## Features

**📊 Live Quota Monitoring** — Polls ChatGPT's usage API with adaptive intervals. Active account polls every 5 seconds for near-realtime UI. Inactive accounts poll based on urgency, sleeping until their reset time to minimize API calls.

**🔄 Automatic Switching** — When the active account's 5-hour or weekly quota hits 0%, CodexSwitch scores all alternatives and atomically swaps `~/.codex/auth.json`. Anti-ping-pong logic ensures candidates must have usable capacity on both windows before swapping.

**⚡ SIGHUP Hot-Swap** — Sends SIGHUP to running Codex CLI processes after every swap and on app launch, so the CLI reloads tokens instantly. Uses `pgrep` + `proc_pidinfo` to find processes and skip those younger than 10 seconds (still initializing).

**🖥 Desktop App Token Injection** — Detects the Codex desktop app via WebSocket and injects new tokens directly, keeping desktop sessions in sync.

**📊 Pooled Usage Meter** — Aggregated view of all accounts' 5-hour and weekly capacity with Pro plan equivalence comparison. Shows estimated pool runway using `min(5h estimate, weekly ceiling)`. When all weekly is exhausted, shows countdown to nearest weekly reset.

**⚡ Menu Bar Icon** — SF Symbol bolt with color states:
| Color | Meaning |
|-------|---------|
| 🟢 Green | > 50% remaining |
| 🟡 Yellow | 20–50% remaining |
| 🟠 Orange | 5–20% remaining |
| 🔴 Red | < 5% remaining |

**🔔 macOS Notifications** — Notified on account swap, token refresh failure, and all-accounts-exhausted.

**🔐 Keychain Storage** — All OAuth tokens stored in macOS Keychain. Never written to disk in plaintext.

**📋 Diagnostic Logging** — Daily log files at `~/.codexswitch/logs/` with swap events, SIGHUP delivery, polling errors, and token refreshes. Old logs auto-pruned after 7 days.

## How It Works

```
                    ┌─────────────────┐
                    │   Menu Bar ⚡    │
                    │ StatusBarController│
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │   AppDelegate    │  orchestrates everything
                    └──┬──┬──┬──┬──┬──┘
                       │  │  │  │  │
          ┌────────────┘  │  │  │  └────────────┐
          │               │  │  │               │
   ┌──────▼──────┐ ┌─────▼──▼──▼─────┐  ┌──────▼──────┐
   │ QuotaPoller  │ │ AccountManager  │  │  SwapEngine  │
   │  (actor)     │ │ (@Observable)   │  │  (scoring)   │
   │              │ │                 │  │              │
   │ adaptive     │ │ accounts[]      │  │ score()      │
   │ polling      │ │ swapHistory[]   │  │ writeAuth()  │
   │              │ │ syncWithAuth()  │  │ signalCLI()  │
   └──────┬───────┘ └────────┬────────┘  └──────┬───────┘
          │                  │                   │
   ┌──────▼───────┐   ┌─────▼──────┐    ┌───────▼──────┐
   │TokenRefresher │   │KeychainStore│    │~/.codex/     │
   │              │   │            │    │  auth.json   │
   │ OAuth refresh│   │ macOS      │    │  (atomic     │
   │ via OpenAI   │   │ Keychain   │    │   rename)    │
   └──────────────┘   └────────────┘    └──────────────┘
```

### Swap Scoring Algorithm

When the active account hits 0% on either window, CodexSwitch picks the best replacement:

```
if weekly exhausted → score = -1 (ineligible)

if 5h exhausted (but weekly available):
  score = resetProximity × 15 + weekly.remaining × 0.1
  (closer to 5h reset = higher score, scaled 0→1 over 5h window)

otherwise:
  score = fiveHour.remainingPercent
        + weekly.remainingPercent × 0.3
        × (0.5 penalty if weekly < 20%)
```

Anti-ping-pong guard: a candidate must have **both** usable 5h and usable weekly (`!isExhausted` on both) before the swap executes.

### Adaptive Polling

Active account polls every 5 seconds. Inactive accounts use urgency-based intervals that sleep until their next reset:

| Remaining | Active | Inactive |
|-----------|--------|----------|
| > 50% | 5s | 10 min |
| 20–50% | 5s | 5 min |
| 10–20% | 5s | 2 min |
| 5–10% | 5s | 1 min |
| < 5% | 5s | 10 sec |
| Exhausted | 5s | Sleep until reset + 2s |

Inactive accounts with plenty of quota (> 50%) check every 10 minutes. Exhausted inactive accounts sleep until their 5h window resets, then poll once to confirm.

## Getting Started

### Prerequisites

- macOS 15+
- Swift 6.3+ (Xcode 26+)
- One or more ChatGPT Plus accounts with Codex CLI access
- A SIGHUP-capable Codex CLI binary (writes `~/.codexswitch/sighup-verified` on startup)

### Build & Run

```bash
git clone https://github.com/brendondelgado/CodexSwitch.git
cd CodexSwitch
swift build
# Copy to Applications
cp .build/debug/CodexSwitch /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch
open /Applications/CodexSwitch.app
```

### Adding Accounts

1. Click the ⚡ menu bar icon → **Add Account**
2. Sign in with Google OAuth in the browser window that opens
3. Tokens are extracted and stored securely in Keychain
4. Repeat for each account

### Settings

Click the ⚙ gear icon in the popover to configure:
- **Launch at login** — start CodexSwitch automatically
- **Poll frequency** — 0.5x (aggressive) to 2.0x (conservative) multiplier
- **Remove all accounts** — clear Keychain and reset

## Project Structure

```
Sources/CodexSwitch/
├── App/
│   ├── CodexSwitchApp.swift        # @main entry point
│   └── AppDelegate.swift           # Orchestrates services, swap logic, UI
├── Models/
│   ├── AccountManager.swift        # @Observable account state + sync
│   ├── AuthFile.swift              # Codex auth.json schema
│   ├── CodexAccount.swift          # Account model with quota data
│   ├── QuotaSnapshot.swift         # 5h/weekly windows + urgency tiers
│   └── SwapEvent.swift             # Swap history records
├── Services/
│   ├── AccountImporter.swift       # Import from ~/.codex/auth.json
│   ├── CLIStatusChecker.swift      # Verify CLI can read current auth
│   ├── CodexVersionChecker.swift   # Detect SIGHUP-capable binary
│   ├── DesktopAppConnector.swift   # WebSocket token injection for desktop app
│   ├── KeychainStore.swift         # Keychain CRUD operations
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
```

## Testing

```bash
swift test
```

24 tests across 4 suites covering models, quota parsing, polling intervals, and swap scoring.

## License

MIT

---

<p align="center">
  <em>Built with Claude Code</em>
</p>
