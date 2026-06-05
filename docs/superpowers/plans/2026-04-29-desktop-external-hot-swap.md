---
toc:
  - Desktop External Hot-Swap Implementation Plan
  - File Structure
  - Chunk 1: Freeze The Safety Boundary
  - Chunk 2: Discover The Official Desktop Runtime Contract
  - Chunk 3: Implement External Desktop Reload Client
  - Chunk 4: Integrate Swap Flow And Status UI
  - Chunk 5: Recovery, Diagnostics, And Regression Harness
  - Execution Notes
cross_dependencies:
  - Sources/CodexSwitch/Services/DesktopAppConnector.swift
  - Sources/CodexSwitch/Services/DesktopPatchManager.swift
  - Sources/CodexSwitch/Services/CLIStatusChecker.swift
  - Sources/CodexSwitch/App/AppDelegate.swift
  - Sources/CodexSwitch/Services/SwapEngine.swift
  - scripts/patch-asar.py
  - Tests/CodexSwitchTests/DesktopStatusTests.swift
  - Tests/CodexSwitchTests/DesktopRuntimeHotSwapStateTests.swift
version_control:
  branch: feat/codex-native
  base_commit: 58da612
  created: 2026-04-29
---

# Desktop External Hot-Swap Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CodexSwitch hot-swap Codex desktop sessions without mutating or re-signing `/Applications/Codex.app`, while preserving Computer Use, Browser Use, and all signed bundled plugins.

**Architecture:** Keep `Codex.app` official/OpenAI-signed. CodexSwitch writes `~/.codex/auth.json`, then uses a runtime-only desktop reload path: first an official app-server WebSocket/RPC if one exists, otherwise a safe external process signal/restart boundary that never edits the app bundle. Bundle patching becomes a diagnostic/deprecated path, not the happy path.

**Tech Stack:** Swift 6, macOS AppKit menu-bar app, local Codex app-server WebSocket/JSON-RPC, `lsof`/`pgrep` diagnostics, Swift Testing, Python ASAR patcher tests.

---

## File Structure

- Modify: `Sources/CodexSwitch/Services/DesktopPatchManager.swift`
  - Owns signed-app/plugin compatibility checks and must permanently refuse unsafe ASAR/bundle mutation when official Computer Use is installed.
- Modify: `Sources/CodexSwitch/Services/DesktopAppConnector.swift`
  - Evolves from token injection helper into the external desktop runtime client.
- Create: `Sources/CodexSwitch/Services/DesktopRuntimeReloadClient.swift`
  - Owns app-server discovery, protocol probing, reload attempts, and structured results.
- Create: `Sources/CodexSwitch/Services/DesktopRuntimeDiagnostics.swift`
  - Owns lightweight diagnostics for app-server process path, signing state, port, and last reload error.
- Modify: `Sources/CodexSwitch/Services/CLIStatusChecker.swift`
  - Shows honest desktop readiness: official plugins OK, external reload ready/unavailable, never false-green.
- Modify: `Sources/CodexSwitch/App/AppDelegate.swift`
  - Calls desktop external reload after account swap, not ASAR patching.
- Modify: `scripts/patch-asar.py`
  - Keeps hard refusal for official signed Codex.app; no automatic fallback to re-signing.
- Create/Modify tests under `Tests/CodexSwitchTests/`
  - Contract tests for signed-app preservation, runtime reload status, protocol probe behavior, and swap flow fallback.

---

## Chunk 1: Freeze The Safety Boundary

### Task 1: Make unsafe desktop mutation impossible by default

**Files:**
- Modify: `Sources/CodexSwitch/Services/DesktopPatchManager.swift`
- Modify: `scripts/patch-asar.py`
- Modify: `Tests/CodexSwitchTests/DesktopStatusTests.swift`

- [ ] **Step 1: Write tests for official signing preservation**

Add/keep tests asserting:

```swift
#expect(
    DesktopPatchManager.statusMessage(
        running: true,
        runtimeState: .unknown,
        automaticPatchingEnabled: true,
        permissionDeniedBackoffActive: false,
        codexAppSignatureCompatible: true,
        markers: .init(
            auth: false,
            fast: false,
            bundledPluginListRoot: false,
            bundledCLI: false,
            versionCompatible: true,
            computerUsePluginSignatureCompatible: true
        )
    ) == "Desktop app preserves official signing for Computer Use; desktop hot-swap needs an external/upstream reload path."
)
```

- [ ] **Step 2: Run the focused tests**

Run: `swift test --filter DesktopStatusTests`

Expected: PASS.

- [ ] **Step 3: Ensure patcher refusal remains explicit**

Keep this behavior in `scripts/patch-asar.py`: if official `Codex.app` and official Computer Use plugin are present, exit `2` unless `CODEXSWITCH_ALLOW_UNSAFE_DESKTOP_RESIGN=1` is explicitly set.

- [ ] **Step 4: Run patcher regression tests**

Run: `python3 scripts/test_patch_asar.py`

Expected: PASS.

- [ ] **Step 5: Verification checkpoint**

Run:

```bash
codesign -dv /Applications/Codex.app 2>&1 | egrep 'Identifier=|TeamIdentifier='
spctl --assess --type execute -vv /Applications/Codex.app
```

Expected before final recovery: local signed apps are reported as blockers. Expected final state: `TeamIdentifier=2DC432GLL2` and `spctl` accepted.

---

## Chunk 2: Discover The Official Desktop Runtime Contract

### Task 2: Probe the app-server without changing state

**Files:**
- Create: `Sources/CodexSwitch/Services/DesktopRuntimeDiagnostics.swift`
- Create: `Tests/CodexSwitchTests/DesktopRuntimeDiagnosticsTests.swift`

- [ ] **Step 1: Write parsing tests for app-server process discovery**

Test cases:

```swift
let output = """
34109 /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled
90722 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex app-server --analytics-default-enabled
"""
```

Expected:
- Desktop app-server path is detected separately from Homebrew CLI app-server.
- Desktop app-server signed-app compatibility can be reported without running `codesign` in tests.

- [ ] **Step 2: Implement diagnostics model**

Add:

```swift
struct DesktopRuntimeDiagnostics: Sendable, Equatable {
    let appServerPID: Int32?
    let appServerPath: String?
    let websocketPort: UInt16?
    let codexAppTeamIdentifier: String?
    let codexAppAcceptedByGatekeeper: Bool
    let computerUsePluginCompatible: Bool
    let lastReloadError: String?
}
```

- [ ] **Step 3: Implement pure parsers first**

Add pure functions for:
- parsing `pgrep -fl` output
- parsing `lsof` output
- classifying desktop app-server vs CLI app-server

- [ ] **Step 4: Add live diagnostic method**

Add `DesktopRuntimeDiagnostics.current()` using bounded `ProcessRunner` calls only. Timeouts must be ≤3 seconds.

- [ ] **Step 5: Run tests**

Run: `swift test --filter DesktopRuntimeDiagnosticsTests`

Expected: PASS.

### Task 3: Enumerate app-server methods safely

**Files:**
- Create: `Sources/CodexSwitch/Services/DesktopRuntimeReloadClient.swift`
- Create: `Tests/CodexSwitchTests/DesktopRuntimeReloadClientTests.swift`

- [ ] **Step 1: Add protocol probe result types**

```swift
enum DesktopReloadCapability: Sendable, Equatable {
    case available(method: String)
    case appServerUnavailable
    case noSupportedMethod(probedMethods: [String])
    case failed(String)
}
```

- [ ] **Step 2: Probe only read-only or no-op RPCs first**

Candidate methods to test in order, with tiny timeouts:
- `account/status`
- `account/get`
- `session/get`
- `auth/status`
- known existing `account/login/start` only as a compatibility baseline

Do not send new tokens in discovery.

- [ ] **Step 3: Log protocol errors, not secrets**

Structured log example:

```text
DESKTOP_RELOAD_PROBE method=account/status result=method_not_found
```

Never log access tokens or auth payloads.

- [ ] **Step 4: Run probe against live app only when user has quit/restarted into official app**

Manual command is not enough; verify through CodexSwitch UI/log and live app-server port.

---

## Chunk 3: Implement External Desktop Reload Client

### Task 4: Build token reload through supported runtime method

**Files:**
- Modify: `Sources/CodexSwitch/Services/DesktopRuntimeReloadClient.swift`
- Modify: `Sources/CodexSwitch/Services/DesktopAppConnector.swift`
- Test: `Tests/CodexSwitchTests/DesktopRuntimeReloadClientTests.swift`

- [ ] **Step 1: Define reload result**

```swift
enum DesktopReloadResult: Sendable, Equatable {
    case reloaded(method: String)
    case noDesktopRuntime
    case unsupported
    case failed(String)
}
```

- [ ] **Step 2: Preserve current `account/login/start` as the first implementation attempt**

Existing behavior already sends:

```json
{
  "method": "account/login/start",
  "id": 1,
  "params": {
    "type": "chatgptAuthTokens",
    "accessToken": "...",
    "chatgptAccountId": "...",
    "chatgptPlanType": "..."
  }
}
```

Refactor it into `DesktopRuntimeReloadClient.reloadAuth(account:port:)` so all callers get structured outcomes.

- [ ] **Step 3: Add response classification tests**

Inputs:
- success JSON-RPC response
- JSON-RPC method-not-found error
- transport closed
- timeout

Expected:
- success -> `.reloaded(method: "account/login/start")`
- method not found -> `.unsupported`
- transport closed -> `.failed("transport closed")`

- [ ] **Step 4: Add fallback method hooks without enabling them blindly**

Support a method list internally, but only enable methods proven by probe. Do not guess mutating RPC names.

- [ ] **Step 5: Run focused tests**

Run: `swift test --filter DesktopRuntimeReloadClientTests`

Expected: PASS.

### Task 5: If no RPC exists, define the upstream hook request

**Files:**
- Create: `docs/desktop-external-hot-swap-upstream-hook.md`

- [ ] **Step 1: Document minimal upstream hook**

Required app-server RPC:

```json
{
  "method": "auth/reloadFromDisk",
  "params": { "reason": "external-auth-json-updated" }
}
```

Expected behavior:
- re-read `~/.codex/auth.json`
- refresh active account/token caches
- trigger same UI invalidation as login/logout
- do not restart app-server
- do not touch plugin runtime

- [ ] **Step 2: Define acceptance criteria**

Acceptance:
- With official signed Codex.app, CodexSwitch writes new auth file, calls RPC, current desktop session uses new account.
- Computer Use `list_apps` still returns app list afterward.
- Browser/Computer Use plugin registration remains present.

---

## Chunk 4: Integrate Swap Flow And Status UI

### Task 6: Replace desktop patch readiness with external reload readiness

**Files:**
- Modify: `Sources/CodexSwitch/Services/CLIStatusChecker.swift`
- Modify: `Sources/CodexSwitch/Views/PopoverContentView.swift`
- Modify: `Sources/CodexSwitch/Views/SettingsView.swift`
- Test: `Tests/CodexSwitchTests/DesktopStatusTests.swift`

- [ ] **Step 1: Add status labels**

Labels:
- `Codex desktop app connected: External reload ready`
- `Codex desktop app connected: Computer Use ready; external reload unavailable`
- `Codex.app signing must be restored for Computer Use`

- [ ] **Step 2: Remove green-ready state for ASAR mutation**

Any state that depends on `authPatchInstalled` or `bundledCLIHotSwapInstalled` must be secondary/deprecated, not the primary desktop readiness signal.

- [ ] **Step 3: Add tests for label truthfulness**

Test matrix:
- official app + plugin compatible + reload capability available -> healthy
- official app + plugin compatible + reload unavailable -> warning, not healthy
- local-signed app -> blocker

- [ ] **Step 4: Run UI/status tests**

Run: `swift test --filter DesktopStatusTests`

Expected: PASS.

### Task 7: Use external reload in swap execution

**Files:**
- Modify: `Sources/CodexSwitch/App/AppDelegate.swift`
- Modify: `Sources/CodexSwitch/Services/SwapLog.swift`
- Test: `Tests/CodexSwitchTests/SwapEngineTests.swift` or new focused service test if AppDelegate is too integrated

- [ ] **Step 1: Add log events**

Add safe logs:

```text
DESKTOP_EXTERNAL_RELOAD_ATTEMPT account=<redacted/account-id-prefix> method=<method>
DESKTOP_EXTERNAL_RELOAD_SUCCESS method=<method>
DESKTOP_EXTERNAL_RELOAD_FAILED reason=<reason>
```

- [ ] **Step 2: Replace direct `DesktopAppConnector.tryInjectTokens` call path**

Flow:
1. `SwapEngine.writeAuthFile(for:)`
2. `SwapEngine.signalCodexReload()` for CLI only
3. `DesktopRuntimeReloadClient.reloadAuth(account:)` for desktop
4. Update UI with honest success/failure

- [ ] **Step 3: Do not block account swap on desktop reload failure**

If desktop reload fails:
- auth file still changed
- CLI still reloads
- CodexSwitch shows desktop reload warning
- user is not told desktop hot-swap succeeded

- [ ] **Step 4: Run swap tests**

Run: `swift test --filter SwapEngineTests`

Expected: PASS.

---

## Chunk 5: Recovery, Diagnostics, And Regression Harness

### Task 8: Add official app recovery flow as an explicit user action

**Files:**
- Create: `Sources/CodexSwitch/Services/OfficialCodexAppRestorer.swift`
- Modify: `Sources/CodexSwitch/Views/SettingsView.swift`
- Test: `Tests/CodexSwitchTests/OfficialCodexAppRestorerTests.swift`

- [ ] **Step 1: Add restorer plan-only checks**

Implement dry-run methods:
- current app Team ID
- official DMG version
- official DMG Team ID
- whether Codex.app is running

- [ ] **Step 2: Add UI button only when blocked**

Button: `Restore Official Codex.app Signing`

Rules:
- disabled while Codex.app is running
- explains this preserves plugins but desktop reload needs external path
- never auto-restores without user action

- [ ] **Step 3: Add tests for no-surprise behavior**

Expected:
- restorer refuses while app running
- restorer refuses if DMG Team ID is not `2DC432GLL2`
- restorer never launches from background timer

### Task 9: Live verification checklist

**Files:**
- Create: `docs/runbooks/codex-desktop-external-hot-swap-verification.md`

- [ ] **Step 1: Verify official signing**

Run:

```bash
codesign -dv /Applications/Codex.app 2>&1 | egrep 'Identifier=|TeamIdentifier='
spctl --assess --type execute -vv /Applications/Codex.app
```

Expected: `TeamIdentifier=2DC432GLL2`, accepted.

- [ ] **Step 2: Verify plugins**

In a Codex session with Computer Use exposed:
- `mcp__computer_use__.list_apps` returns app list
- `mcp__computer_use__.get_app_state {"app":"Finder"}` returns screenshot/accessibility tree

Do not make verification depend on ColorControlMac specifically.

- [ ] **Step 3: Verify desktop reload**

Procedure:
1. Pick account A active in Codex.app.
2. Force CodexSwitch swap to account B.
3. Confirm CodexSwitch logs `DESKTOP_EXTERNAL_RELOAD_SUCCESS`.
4. Send message in Codex.app and confirm it uses account B.
5. Re-run Computer Use `list_apps`.

Expected: account changes without plugin breakage.

- [ ] **Step 4: Verify failure honesty**

Disable/reject app-server connection temporarily.

Expected:
- CodexSwitch does not show desktop green.
- CLI hot-swap still works.
- Computer Use remains intact.

---

## Execution Notes

- Do not patch or re-sign `/Applications/Codex.app` as part of normal desktop hot-swap work.
- Do not use Headroom in desktop routing.
- Do not install alpha Codex CLI globally.
- Do not kill live Codex.app from CodexSwitch or from implementation sessions unless the user explicitly asks.
- If no supported external reload RPC exists, stop and pursue the upstream hook. Do not resurrect ASAR mutation as the default path.
