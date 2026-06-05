<claude-mem-context>
# Memory Context

# [CodexSwitch] recent context, 2026-04-22 11:48pm EDT

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (22,623t read) | 1,521,956t work | 99% savings

### Apr 21, 2026
482 12:29p 🔵 CodexSwitch Freeze-Risk Audit Scope Identified
483 12:30p 🔵 CodexSwitch Polling Architecture — Multiple Overlapping Timers Probing Codex.app
484 " 🔵 repairInstalledAppIfNeeded Path Runs codesign --deep and pkill Against Live Codex.app
485 " 🔵 Injected `_codexSwitchEnsureDesktopAuthSync` Runs `setInterval(2000)` Inside Codex.app's Renderer
486 12:31p 🔵 CodexDesktopAppProcessClassifier uses pgrep with 1.5s timeout to detect Codex.app runtime state
497 12:35p 🔵 Five distinct polling/probing vectors identified that could indirectly affect Codex.app during normal use
498 " 🔵 Injected JS auth-sync loop runs every 2s inside Codex.app renderer — highest-risk freeze candidate
499 " 🔵 npm fallback subprocess in _getLatestVersion() can block for up to 5 seconds on every checkVersions() call
530 12:49p 🔵 CodexSwitch Freeze Audit: lsof Called Every 5s Without Timeout
531 " 🔵 CodexSwitch Freeze Audit: Injected JS Polls Codex App-Server Every 2 Seconds
532 " 🔵 CodexSwitch Freeze Audit: applicationWillTerminate Uses DispatchSemaphore.wait() on Main Thread
533 " 🔵 CodexSwitch Freeze Audit: writeAuthFile Called Synchronously on Main Actor During Swap
534 4:12p 🔵 CodexSwitch Main-Updater Freeze Audit Initiated
535 4:14p 🔵 Thread Unload Refactored: remove_connection Now Returns Zero-Subscriber Thread IDs
536 " 🔵 Codex.app Live Freeze: Renderer Stuck in V8 JIT, App-Server at 87% CPU
537 " 🔵 Rollout Loading: Entire JSONL Read Into Memory Synchronously Before Parse
538 " 🔵 Thread Unload Timeout: 10-Second Blocking Wait Inside tokio::spawn
625 5:46p 🔵 CodexSwitch Token Expiry Status and Auth File Structure
626 5:47p 🔵 CodexSwitch Core Architecture: Auth Flow, Swap Engine, and Token Refresh
627 " 🔵 Account ID Mismatch Between accounts.json and auth.json
628 " 🔵 AccountManager Active Account Sync and Sort Logic
629 5:48p ✅ Codex Desktop App Reinstalled from Stock ZIP
630 5:49p 🔵 Stock Codex 26.417.41555 Codesign Verified Successfully
632 " 🔵 CodexSwitch Git Worktree Layout and Branch State
633 " 🔵 Codex Desktop Process Tree After Stock Reinstall
636 5:51p 🟣 CodexSwitch main Branch: Codex Desktop App ASAR Patching Pipeline
637 " 🟣 CodexSwitch main Branch: Plan-Aware Swap Scoring and shouldSwap() Logic
638 " 🟣 CodexSwitch main Branch: KeychainStore Migrated to File-Based accounts.json Storage
639 " 🟣 CodexSwitch main Branch: QuotaPoller Polling Interval Improvements
642 5:52p 🔵 patch-asar.py: Four Patches Applied to Codex app.asar
643 " 🔵 SIGHUP Process Targeting Rules: Interactive TTY, Executable Path, and Age Checks
645 " ⚖️ Stabilization Plan: Stock Codex App + Direct WebSocket Injection Instead of ASAR Patch
646 " 🔵 SwapLog: POSIX O_APPEND Atomic Daily-Rotating Log and SettingsView Patch Status UI
647 5:53p 🔵 Desktop Patch Repair Decision Logic and Auto-Swap Readiness Conditions
648 6:01p 🔵 CodexSwitch Rapid Swap Loop Detected in Logs
649 " 🔵 CodexSwitch SwapEngine.shouldSwap Logic Inspected
650 " 🔵 CodexSwitch SIGHUP Signal Architecture in AppDelegate
651 6:02p 🔴 CodexSwitch Swap Loop Fixed with 30-Second Cooldown and SIGHUP Disabled
652 " 🔵 Live Account Quota State Revealed in Test Output
654 " ✅ CodexSwitch Swap Loop Fix Rebuilt, Reinstalled, and Verified Stable
657 6:03p ⚖️ Codex.app Desktop Bundle Patching Permanently Disabled in CodexAutoPatchMonitor
658 " 🔵 Post-Relaunch State Verified: accounts.json and auth.json in Sync
664 6:07p 🔵 patch-asar.py Desktop Patching Infrastructure: Three Patch Functions Still Present but Disabled
665 " 🔵 CodexDesktopAppLocator Patch Detection Requires All Three Markers and No Legacy Markers
667 " ✅ patch-asar.py Inverted: Now Removes Desktop Auth Patches Instead of Applying Them
668 6:08p ✅ CodexDesktopAppLocator requiredPatchMarkers Reduced to Fast-Mode Only
669 " ✅ All Tests Pass After Desktop Patch Architecture Changes
670 6:11p 🔵 Full Scope of main-updater Branch Changes Confirmed via Git Status
684 6:17p ✅ Desktop ASAR Patching Re-Enabled in CodexAutoPatchMonitor
685 " 🔵 CodexPatchingTests Covers Full Desktop Patch Decision Tree

Access 1522k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>

## Codex.app Desktop Patch Runbook

Use this when the user explicitly asks to patch `/Applications/Codex.app` after
a Codex desktop update. That explicit request overrides older CodexNative
instructions that protected the stock app during wrapper-only debugging.

1. Confirm permissions and runtime safety before mutation.
- Verify write access with a temporary file in
  `/Applications/Codex.app/Contents/Resources/`.
- Verify the desktop host and app-server are quit. Crashpad and Computer Use
  helper leftovers are not blockers. Prefer the `codex_app_is_running()` filter
  in `scripts/patch-asar.py` over raw broad `pgrep` output.

2. Confirm signing before repacking.
- Run `security find-identity -v -p codesigning` and require a non-ad-hoc
  identity such as `Developer ID Application`, `Apple Development`, or
  `Mac Developer`.
- Xcode or Apple Developer account login alone is not enough; the private key
  must be in Keychain.
- The identity must be Apple-issued. A self-signed certificate named
  `Apple Development: ...` can make `codesign --verify` pass while launchd still
  refuses to spawn Codex.app with `RBSRequestErrorDomain Code=5` /
  `NSPOSIXErrorDomain Code=163`.
- If an Apple-issued cert/key pair is already on disk, import it with
  `openssl pkcs12 -legacy -export ...` and `security import ... -A`, then approve
  the Keychain prompt with `Always Allow`. Without `-legacy`, Keychain import may
  fail with PKCS#12 MAC verification errors.
- When signing Codex.app with a non-OpenAI Team ID, do not preserve OpenAI-only
  entitlements such as `2DC432GLL2.*` keychain groups or application groups.
  Re-sign the app root with minimal Electron-safe local entitlements instead.
- Do not expose private keys, commit signing material, or place signing
  material in SecureDrop.

3. Run and repair the patcher.
- Run `python3 scripts/patch-asar.py`.
- If a new Codex build changes minified JS structure, extract the current ASAR
  to a temp directory, fix `scripts/patch-asar.py` against the real extracted
  bundle shape, and add a regression in `scripts/test_patch_asar.py` before
  retrying the installed app.
- Current durable auth patch markers include `_invalidateAccountQueries`; verify
  the marker in `/Applications/Codex.app/Contents/Resources/app.asar` after
  patching.

4. Verify the installed app, not only the workdir.
- Run the patcher tests.
- Verify `codesign --verify --strict --verbose=4 /Applications/Codex.app`.
- Launch Codex.app only after the installed ASAR marker and codesign checks are
  green.

## Codex.app Auth Reload Contract

When fixing CodexSwitch account swaps or token refreshes, preserve the full
desktop auth token set.

- `~/.codex/auth.json` and `~/.codexswitch/accounts.json` must agree on the
  active account before blaming Codex.app.
- Desktop runtime reloads must write `auth.json`, signal the app-server, and
  send the refreshed token set through the desktop JSON-RPC path.
- Do not send only `accessToken` to Codex.app. A swap can look fixed briefly
  while Codex.app still holds an old refresh token, then fail later with:
  `Your access token could not be refreshed because you have since logged out
  or signed in to another account. Please sign in again.`
- Regression tests for `DesktopRuntimeReloadClient.reloadRequest` must assert
  that `refreshToken` is included when available.
- A live `codex-vps` session must not suppress Mac desktop auto-swap while
  Codex.app is running locally; the VPS can own remote rotation, but the Mac
  desktop still needs to protect its active local session.

## Codex.app Embedded Browser Session Repair

- The error `Your access token could not be refreshed because you have since
  logged out or signed in to another account` can come from Codex.app's embedded
  ChatGPT browser partition, not from `~/.codex/auth.json`.
- Check `~/Library/Application Support/Codex/Partitions/codex-browser-app`
  before claiming an auth fix is complete. Stale ChatGPT cookies/localStorage
  there can survive fresh CodexSwitch tokens and fresh app-server SIGHUP acks.
- Repair by backing up the partition under
  `~/.codexswitch/backups/codex-browser-app/<timestamp>/codex-browser-app` and
  letting Codex.app recreate it. Do not delete it in place, and do not move it
  while Codex.app is running.
- CodexSwitch should automatically perform that backup repair only when the
  partition is stale and Codex.app is not running, including from the Codex.app
  termination hook.

## CodexSwitch SecureDrop Agent Protocol

Use CodexSwitch SecureDrop whenever the user asks to share, send, receive, move, attach, transfer, or place an artifact in the secure folder between this Mac and the SIGNUL VPS.

- Default Mac secure folder: `~/CodexSwitch SecureDrop`
- Default VPS secure folder: `/home/signul/codexswitch-secure-files`
- Mac -> VPS: run `cs-send <path>` / `codexswitch-cli files send <path>`, or drop a regular file into `~/CodexSwitch SecureDrop/outbox` and the Mac LaunchAgent auto-pushes it to `/home/signul/codexswitch-secure-files/inbox` within about 15 seconds.
- VPS -> Mac: place files in `/home/signul/codexswitch-secure-files/outbox`; the Mac auto-pulls them into `~/CodexSwitch SecureDrop/inbox` within about 15 seconds. Manual fallback: `cs-pull <name>` or `cs-sync`.
- When the user says "move/share this to the secure folder", do it proactively and report the destination path.
- Do not use ad hoc public links, email, or cloud drives for Mac/VPS artifact transfer unless the user explicitly asks.
- Do not put secrets, OAuth tokens, raw account stores, or private keys in SecureDrop unless the user explicitly confirms the risk.
- Prefer regular files and archives. Symlinks are not valid transfer artifacts.
- After transferring a file, include the exact recipient-side path in the response. Auto-pushed Mac outbox files are consumed locally after SHA-256 verification on the VPS.

### SecureDrop directory and knowledge-sync additions

Use `cs-send-dir <dir> [name]` on the Mac and `cs-share-dir <dir> [name]` on the VPS for multi-file captures. These create tar archives with adjacent SHA-256 files and use atomic staging.

Use the shared knowledge folder for ongoing agent findings:

- Mac: `~/CodexSwitch SecureDrop/knowledge`
- VPS: `/home/signul/codexswitch-secure-files/knowledge`
- Status: `cs-knowledge-status`
- Event hook: `cs-watch <subdir> -- <command>`

The knowledge folder syncs roughly every 15 seconds. Conflicts go to `knowledge/.conflicts/` for human review. Do not place secrets in knowledge or SecureDrop.
