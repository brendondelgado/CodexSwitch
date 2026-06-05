---
toc:
  - Desktop And Linux Token Transfer Implementation Plan
  - File Structure
  - Chunk 1: Desktop Hot-Swap Truth And Recovery
  - Chunk 2: Encrypted Linux Export From The Desktop UI
  - Chunk 3: Linux CLI Import And Daemon
  - Chunk 4: End-To-End Verification
  - Security Rules
cross_dependencies:
  - Sources/CodexSwitch/Views/SettingsView.swift
  - Sources/CodexSwitch/Services/KeychainStore.swift
  - Sources/CodexSwitch/Models/CodexAccount.swift
  - Sources/CodexSwitch/Services/SwapEngine.swift
  - Sources/CodexSwitch/Services/CLIStatusChecker.swift
  - Sources/CodexSwitch/Services/DesktopRuntimeReloadClient.swift
  - Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - docs/linux-cli-only.md
  - docs/superpowers/plans/2026-04-29-desktop-external-hot-swap.md
version_control:
  branch: feat/codex-native
  base_commit: 58da612
  created: 2026-04-30
---

# Desktop And Linux Token Transfer Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CodexSwitch reliable for macOS desktop/CLI hot-swap boundaries and add a one-click encrypted export/import path so the Linux VPS version can reuse the user’s existing logged-in account tokens without re-login.

**Architecture:** Keep `Codex.app` official-signed for Computer Use and Browser Use. CodexSwitch desktop owns account management, UI export, and macOS status truth; Linux gets a headless `codexswitch-cli` daemon that imports an encrypted account bundle, writes `~/.codex/auth.json`, and SIGHUPs verified Codex CLI sessions. Token transfer is explicit, encrypted, short-lived, and never uses raw copy/paste of `accounts.json`.

**Tech Stack:** Swift 6 macOS menu-bar app, Swift Testing, Rust or Swift headless Linux CLI, `age`-style passphrase/public-key encryption, JSON account bundle, POSIX `SIGHUP`, `systemd --user`.

---

## File Structure

- Modify: `Sources/CodexSwitch/Views/SettingsView.swift`
  - Add “Linux Devbox” section with export actions, transfer status, and safety copy.
- Create: `Sources/CodexSwitch/Services/LinuxDevboxExportService.swift`
  - Builds sanitized export metadata, encrypts selected `CodexAccount` records, writes bundle files, and creates import commands.
- Create: `Sources/CodexSwitch/Models/LinuxDevboxBundle.swift`
  - Defines versioned portable bundle schema, metadata, selected accounts, active account, and export expiry.
- Create: `Tests/CodexSwitchTests/LinuxDevboxExportServiceTests.swift`
  - Covers selected-account export, active-account preservation, encryption required, and no plaintext token leakage in bundle metadata.
- Modify: `docs/linux-cli-only.md`
  - Replace sketch with concrete install/import commands once the CLI shape is final.
- Create: `crates/codexswitch-cli/` or `Sources/CodexSwitchCLI/`
  - Linux headless CLI/daemon. Prefer Rust if the goal is Linux-first distribution and static-ish deployment.
- Create: `crates/codexswitch-cli/src/import.rs`
  - Decrypts desktop export bundle and writes `~/.codexswitch/accounts.json` with `0600`.
- Create: `crates/codexswitch-cli/src/auth.rs`
  - Generates Codex-compatible `~/.codex/auth.json`.
- Create: `crates/codexswitch-cli/src/reload.rs`
  - Discovers live Codex CLI processes and sends SIGHUP only to verified same-user CLI sessions.
- Create: `crates/codexswitch-cli/systemd/codexswitch.service`
  - User service template for VPS daemon mode.

---

## Chunk 1: Desktop Hot-Swap Truth And Recovery

### Task 1: Keep desktop app honest and plugin-safe

**Files:**
- Modify: `Sources/CodexSwitch/Services/DesktopPatchManager.swift`
- Modify: `Sources/CodexSwitch/Services/CLIStatusChecker.swift`
- Test: `Tests/CodexSwitchTests/DesktopStatusTests.swift`
- Test: `Tests/CodexSwitchTests/CLIStatusCheckerTests.swift`

- [ ] **Step 1: Assert official Codex.app mode never claims desktop hot-swap**

Add/keep tests where official OpenAI signing and Computer Use compatibility are true but no runtime reload hook exists.

Expected label:

```text
Computer Use ready; desktop hot-swap needs upstream reload
```

- [ ] **Step 2: Assert CLI status ignores desktop app-server**

Test `pgrep -lf codex` output containing:

```text
/Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled
/Applications/Codex.app/Contents/MacOS/Codex
/opt/homebrew/bin/codex
```

Expected: only the terminal CLI process is considered a CLI hot-swap target.

- [ ] **Step 3: Keep desktop reload as a proven-runtime-only path**

`DesktopRuntimeReloadClient` may report ready only after a real supported reload method succeeds. Do not use ASAR markers, app bundle mutations, or local signing as a readiness shortcut.

- [ ] **Step 4: Run focused tests**

Run:

```bash
swift test --filter 'DesktopStatusTests|CLIStatusCheckerTests|DesktopRuntimeReloadClientTests'
```

Expected: PASS.

---

## Chunk 2: Encrypted Linux Export From The Desktop UI

### Task 2: Define a portable account bundle

**Files:**
- Create: `Sources/CodexSwitch/Models/LinuxDevboxBundle.swift`
- Test: `Tests/CodexSwitchTests/LinuxDevboxBundleTests.swift`

- [ ] **Step 1: Write schema tests**

Create tests for this versioned metadata shape:

```swift
struct LinuxDevboxBundleMetadata: Codable, Equatable {
    let schemaVersion: Int
    let createdAt: Date
    let expiresAt: Date
    let exportedByHost: String
    let accountCount: Int
    let activeAccountId: String?
    let emails: [String]
}
```

Expected: metadata contains emails and counts but never access tokens, refresh tokens, ID tokens, or raw account IDs.

- [ ] **Step 2: Define encrypted payload**

Payload contains the existing `[CodexAccount]` JSON plus active account state. It must remain compatible with `KeychainStore`’s current file-backed shape at `~/.codexswitch/accounts.json`.

- [ ] **Step 3: Add expiry**

Default export expiry: 30 minutes. Expiry is advisory for local files but enforced by Linux import unless `--ignore-expiry` is explicitly passed.

### Task 3: Add desktop export service

**Files:**
- Create: `Sources/CodexSwitch/Services/LinuxDevboxExportService.swift`
- Test: `Tests/CodexSwitchTests/LinuxDevboxExportServiceTests.swift`

- [ ] **Step 1: Write failing no-plaintext-token test**

Test:

```swift
let bundle = try service.makeBundle(accounts: accounts, activeAccountId: active, passphrase: "test passphrase")
#expect(!String(decoding: bundle.fileData, as: UTF8.self).contains("refresh-token"))
#expect(!String(decoding: bundle.fileData, as: UTF8.self).contains("access-token"))
```

- [ ] **Step 2: Implement export with required encryption**

Use an `age`-compatible format if practical:
- Passphrase mode for easiest UI.
- Public-key recipient mode later for repeat VPS exports without typing a passphrase.

If native `age` support is not available in Swift, shell out to a bundled/validated `age` binary only from an explicit user action, never from background polling.

- [ ] **Step 3: Write export files**

Default output:

```text
~/Desktop/codexswitch-linux-devbox-YYYYMMDD-HHMMSS.tar.age
```

Contents before encryption:

```text
metadata.json
accounts.json
README-import.txt
```

- [ ] **Step 4: Generate import command**

After export, the UI shows:

```bash
scp ~/Desktop/codexswitch-linux-devbox-*.tar.age user@devbox:~
ssh user@devbox 'codexswitch-cli import ~/codexswitch-linux-devbox-*.tar.age && codexswitch-cli doctor'
```

### Task 4: Add Linux Devbox UI section

**Files:**
- Modify: `Sources/CodexSwitch/Views/SettingsView.swift`
- Test: `Tests/CodexSwitchTests/LinuxDevboxExportServiceTests.swift`

- [ ] **Step 1: Add “Linux Devbox” settings section**

UI actions:
- `Export All Accounts For Linux`
- `Export Selected Accounts`
- `Copy Import Commands`
- `Reveal Export In Finder`

- [ ] **Step 2: Add passphrase UX**

Flow:
1. User clicks export.
2. UI shows selected accounts and active account.
3. User enters export passphrase twice.
4. CodexSwitch writes encrypted bundle.
5. CodexSwitch displays copyable `scp` and `ssh` import commands.

- [ ] **Step 3: Add safety warnings**

Copy:

```text
This bundle contains encrypted Codex login tokens. Anyone with the file and passphrase can use these accounts. Delete it after importing on the devbox.
```

- [ ] **Step 4: Never log secrets**

Add tests or code review checklist item verifying `SwapLog`, `Logger`, and UI status never include token strings.

---

## Chunk 3: Linux CLI Import And Daemon

### Task 5: Create Linux CLI package

**Files:**
- Create: `crates/codexswitch-cli/Cargo.toml`
- Create: `crates/codexswitch-cli/src/main.rs`
- Create: `crates/codexswitch-cli/src/account_store.rs`
- Create: `crates/codexswitch-cli/src/auth.rs`
- Create: `crates/codexswitch-cli/src/import.rs`
- Create: `crates/codexswitch-cli/src/reload.rs`

- [ ] **Step 1: Add command skeleton**

Commands:

```bash
codexswitch-cli doctor
codexswitch-cli import <bundle.tar.age>
codexswitch-cli status
codexswitch-cli swap <email-or-account-id>
codexswitch-cli daemon
```

- [ ] **Step 2: Import encrypted bundle**

Import behavior:
- Prompt for passphrase unless `CODEXSWITCH_IMPORT_PASSPHRASE_FILE` is set.
- Decrypt bundle.
- Validate schema version and expiry.
- Write `~/.codexswitch/accounts.json` with mode `0600`.
- Write active account to `~/.codex/auth.json` with mode `0600`.

- [ ] **Step 3: Implement Linux process discovery**

Use `/proc` to find same-user Codex CLI processes. Exclude:
- `codex app-server`
- package manager scripts
- grep/rg
- `codexswitch-cli`
- non-current-user processes

- [ ] **Step 4: Verify SIGHUP support before signaling**

Read executable bytes or `strings` equivalent and require both:

```text
sighup-verified
SIGHUP: auth reloaded
```

If missing, report:

```text
restart Codex CLI to activate swap
```

Do not signal unverified processes.

### Task 6: Add daemon and systemd user service

**Files:**
- Create: `crates/codexswitch-cli/src/daemon.rs`
- Create: `crates/codexswitch-cli/systemd/codexswitch.service`
- Modify: `docs/linux-cli-only.md`

- [ ] **Step 1: Add polling loop**

Daemon loop:
- Poll active account.
- Poll candidates periodically.
- Swap when active account reaches hard-limit or configured threshold.
- Write `auth.json`.
- SIGHUP verified live sessions.

- [ ] **Step 2: Add service template**

Create:

```ini
[Unit]
Description=CodexSwitch CLI daemon

[Service]
ExecStart=%h/.local/bin/codexswitch-cli daemon
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

- [ ] **Step 3: Document VPS setup**

Update `docs/linux-cli-only.md` with:

```bash
mkdir -p ~/.config/systemd/user
cp codexswitch.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now codexswitch
loginctl enable-linger "$USER"
```

---

## Chunk 4: End-To-End Verification

### Task 7: Verify desktop export to Linux import

**Files:**
- Modify: `docs/linux-cli-only.md`
- Test: manual runbook section

- [ ] **Step 1: Export from CodexSwitch desktop UI**

Expected:
- Encrypted `.tar.age` file is created.
- UI shows account count and active account.
- No token appears in UI logs or `~/.codexswitch/logs`.

- [ ] **Step 2: Transfer to Linux devbox**

Run:

```bash
scp ~/Desktop/codexswitch-linux-devbox-*.tar.age user@devbox:~
```

Expected: file copied.

- [ ] **Step 3: Import on Linux**

Run:

```bash
codexswitch-cli import ~/codexswitch-linux-devbox-*.tar.age
codexswitch-cli doctor
```

Expected:
- Accounts imported.
- Active account written to `~/.codex/auth.json`.
- File modes are `0600`.

- [ ] **Step 4: Verify hot-swap**

Start a patched Codex CLI session on Linux, then run:

```bash
codexswitch-cli swap <other-account-email>
codexswitch-cli status
```

Expected:
- `auth.json` account ID changes.
- Verified Codex CLI process receives `SIGHUP`.
- Codex session continues with new account without relogin.

---

## Security Rules

- Never export plaintext `accounts.json` from the UI.
- Never put tokens in command-line arguments, logs, notifications, or clipboard text.
- The export passphrase must not be stored.
- The encrypted export file should default to `0600`.
- The Linux importer must refuse expired bundles by default.
- Linux daemon must never signal processes owned by another user.
- Desktop app must never mutate or re-sign `/Applications/Codex.app` while Computer Use and Browser Use depend on official signing.
