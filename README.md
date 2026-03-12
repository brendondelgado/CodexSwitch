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

CodexSwitch lives in your macOS menu bar and manages up to 6 ChatGPT Plus accounts simultaneously. It polls each account's quota, visualizes remaining capacity with drain bars, and **automatically swaps to the best account** when the active one runs dry — all without interrupting your workflow.

```
┌──────────────────────────────────────────────┐
│  ⚡ CodexSwitch            user@gmail.com  ⚙ │
├──────────────────────────────────────────────┤
│  ┌────────────┐ ┌────────────┐ ┌──────────┐ │
│  │ user-1     │ │ user-2     │ │ user-3   │ │
│  │ 5h ████░ 72%│ │ 5h ██░░ 38%│ │ 5h █░░ 5%│ │
│  │ Wk █████ 91%│ │ Wk ████ 65%│ │ Wk ██░ 22%│ │
│  └────────────┘ └────────────┘ └──────────┘ │
│  ┌────────────┐ ┌────────────┐ ┌──────────┐ │
│  │ user-4     │ │ user-5     │ │ user-6   │ │
│  │ 5h ███░ 55%│ │ 5h ░░░░  0%│ │ 5h ████ 88%│ │
│  │ Wk ████ 78%│ │ Wk █░░░ 10%│ │ Wk █████ 95%│ │
│  └────────────┘ └────────────┘ └──────────┘ │
├──────────────────────────────────────────────┤
│  Last swap: 2 hours ago     [+ Import Account]│
└──────────────────────────────────────────────┘
```

## Features

**📊 Live Quota Monitoring** — Polls ChatGPT's private usage API with adaptive intervals that speed up as quota drains (10min → 5min → 2min → 1min → 10sec).

**🔄 Automatic Switching** — When the active account hits 0%, CodexSwitch scores all alternatives and atomically swaps `~/.codex/auth.json` to the best one. Codex CLI picks it up immediately.

**⚡ Menu Bar Icon** — SF Symbol bolt that changes color based on quota state:
| Color | Meaning |
|-------|---------|
| 🟢 Green | > 50% remaining |
| 🟡 Yellow | 20–50% remaining |
| 🟠 Orange | 5–20% remaining |
| 🔴 Red | < 5% remaining |

**🔔 macOS Notifications** — Get notified when accounts swap, when tokens need re-auth, or when all accounts are exhausted.

**🔐 Keychain Storage** — All OAuth tokens stored in macOS Keychain. Never written to disk in plaintext.

**🚀 Launch at Login** — Uses SMAppService for clean login item registration.

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
   │  (actor)     │ │ (@MainActor)    │  │  (scoring)   │
   │              │ │                 │  │              │
   │ adaptive     │ │ accounts[]      │  │ score()      │
   │ polling      │ │ swapHistory[]   │  │ writeAuth()  │
   └──────┬───────┘ └────────┬────────┘  └──────┬───────┘
          │                  │                   │
   ┌──────▼───────┐   ┌─────▼──────┐    ┌───────▼──────┐
   │TokenRefresher │   │KeychainStore│    │~/.codex/     │
   │              │   │            │    │  auth.json   │
   │ OAuth refresh│   │ macOS      │    │  (atomic     │
   │ via OpenAI   │   │ Keychain   │    │   write)     │
   └──────────────┘   └────────────┘    └──────────────┘
```

### Swap Scoring Algorithm

When the active account's 5-hour quota hits 0%, CodexSwitch picks the best replacement:

```
score = fiveHour.remainingPercent
      + weekly.remainingPercent × 0.1          (tiebreaker)
      + resetProximityBonus                    (if resetting within 30min)
```

Accounts with both windows exhausted are excluded. The highest-scoring non-active account wins.

### Adaptive Polling

Poll frequency scales with urgency — no wasted API calls when quota is healthy, near-realtime monitoring when it matters:

| Remaining | Interval | Urgency |
|-----------|----------|---------|
| > 50% | 10 min | Relaxed |
| 20–50% | 5 min | Moderate |
| 10–20% | 2 min | Elevated |
| 5–10% | 1 min | High |
| < 5% | 10 sec | Critical |

## Getting Started

### Prerequisites

- macOS 15+
- Swift 6.3+ (Xcode 26+)
- One or more ChatGPT Plus accounts with Codex CLI access

### Build & Run

```bash
git clone https://github.com/brendondelgado/CodexSwitch.git
cd CodexSwitch
swift build
swift run CodexSwitch
```

### Adding Accounts

1. Log into a ChatGPT account in Codex CLI:
   ```bash
   codex --login
   ```
2. Click the ⚡ menu bar icon → **Import Account**
3. Repeat for each account (up to 6)

CodexSwitch reads `~/.codex/auth.json`, extracts the OAuth tokens, and stores them securely in your Keychain.

### Settings

Click the ⚙ gear icon in the popover to configure:
- **Launch at login** — start CodexSwitch automatically
- **Notifications** — toggle swap/exhaustion alerts
- **Poll frequency** — 0.5x (aggressive) to 2.0x (conservative) multiplier

## Project Structure

```
Sources/CodexSwitch/
├── App/
│   ├── CodexSwitchApp.swift      # @main entry point
│   └── AppDelegate.swift         # Orchestrates all services + UI
├── Models/
│   ├── AccountManager.swift      # @Observable account state
│   ├── AuthFile.swift            # Codex auth.json schema
│   ├── CodexAccount.swift        # Account model
│   ├── QuotaSnapshot.swift       # Quota windows + urgency tiers
│   └── SwapEvent.swift           # Swap history records
├── Services/
│   ├── AccountImporter.swift     # Import from ~/.codex/auth.json
│   ├── KeychainStore.swift       # Keychain CRUD
│   ├── NotificationManager.swift # macOS notifications
│   ├── QuotaPoller.swift         # Adaptive HTTP polling (actor)
│   ├── SwapEngine.swift          # Scoring + atomic auth write
│   ├── TokenRefresher.swift      # OAuth token refresh
│   └── UsageResponseParser.swift # ChatGPT usage API parser
└── Views/
    ├── AccountCardView.swift     # Account card with drain bars
    ├── DrainBarView.swift        # Animated quota drain bar
    ├── PopoverContentView.swift  # 2×3 grid popover
    ├── SettingsView.swift        # Preferences window
    └── StatusBarController.swift # Menu bar icon + color states
```

## Testing

```bash
swift test
```

23 tests across 4 suites covering models, services, parsing, and scoring logic.

## License

MIT

---

<p align="center">
  <em>Built with Claude Code</em>
</p>
