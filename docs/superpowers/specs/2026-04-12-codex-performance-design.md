# Codex Desktop Performance: CodexNative + Upstream Fixes

**Date**: 2026-04-12
**Status**: Design approved, pending implementation plan

## Problem

The Codex desktop app (Electron) suffers from progressive memory growth and performance degradation:
- Long conversations accumulate hundreds of React component trees in memory
- Over hours of use, the app becomes sluggish and consumes 2-4GB+ RAM
- Chromium's multi-process architecture (main + renderer + GPU + utility) has baseline overhead of ~400MB before any conversation data
- `MallocNanoZone=0` in Info.plist shows OpenAI already tried to mitigate memory fragmentation

## Solution: Two Parallel Paths

### Path A: Fix Root Causes Upstream (PR to OpenAI)

Profile the Electron app, identify specific memory leaks, fix them in the React source, and PR to OpenAI's open-source repo. Benefits all Codex users.

**Fix 1: Message Virtualization**
- Current: 500-turn conversation = 500 React component trees in memory (markdown ASTs, syntax highlighting, diff renderers)
- Fix: Virtualized list rendering — only ~15 visible messages exist in the React tree
- Library: `react-virtuoso` (handles variable-height items, sticky headers, auto-scroll)
- Impact: ~70-80% memory reduction for long conversations

**Fix 2: React Query Cache Eviction**
- Current: every opened conversation stays in React Query cache indefinitely with full turn data
- Fix: Set `gcTime` (garbage collection) and `staleTime` on conversation queries; limit cache to ~5 most recent conversations
- Impact: prevents multi-GB cache accumulation over hours

**Fix 3: Lazy Tool Output Loading**
- Current: large tool call results (file contents, command outputs, diffs) stay in memory as part of turn data
- Fix: Store tool outputs in SQLite (already available via better-sqlite3), keep only summaries in React state, fetch full content on scroll-into-view
- Impact: significant for coding sessions with many file reads/writes

**Fix 4: Conversation Switch Cleanup**
- Current: switching conversations unmounts components but parsed data (markdown ASTs, highlighted code blocks) isn't released
- Fix: Clear memoization caches and parsed AST refs on conversation unmount
- Impact: prevents accumulation across conversation switches

**Approach:**
1. Profile with Chrome DevTools (Memory tab) to confirm these are the actual leaks
2. Take heap snapshots before/after long conversations to measure
3. Implement fixes in the extracted React source
4. Verify memory reduction with before/after benchmarks
5. PR to github.com/openai/codex with benchmark data

### Path B: CodexNative — Native macOS App

Replace the Electron shell with a native Swift app using WKWebView, eliminating Chromium entirely. WKWebView uses the system WebKit process (~80% less memory than Chromium).

## CodexNative Architecture

### System Overview

```
┌────────────────────────────────────────────┐
│  CodexSwitch.app (menu bar)                │
│  Account management, quota, hot-swap       │
│  Communicates with CodexNative via          │
│  distributed notifications                 │
├────────────────────────────────────────────┤
│  CodexNative.app (main window)             │
│  SwiftUI shell + WKWebView                 │
│  Loads OpenAI's React frontend             │
│  ElectronBridge shims Electron APIs        │
├────────────────────────────────────────────┤
│  codex app-server (Rust binary)            │
│  Spawned as child process by CodexNative   │
│  JSON-RPC over stdio                       │
│  Agent loop, tools, sandbox, MCP, plugins  │
└────────────────────────────────────────────┘
```

### App Bundle

```
CodexNative.app/
├── Contents/
│   ├── MacOS/CodexNative           (~1MB Swift binary)
│   ├── Resources/
│   │   ├── codex-web/              (extracted React frontend)
│   │   │   ├── index.html
│   │   │   ├── assets/             (JS/CSS bundles)
│   │   │   └── preload-shim.js     (ElectronBridge replacement)
│   │   └── codex                   (Rust app-server binary)
│   └── Info.plist
```

**Total bundle size: ~25-30MB** (vs 316MB Electron)

### Component Design

#### 1. AppShell (SwiftUI) — `AppShell.swift`

Native macOS window management:
- `NSWindow` with standard traffic lights, resize, full-screen
- Native menu bar (File, Edit, View, Window, Help)
- Keyboard shortcut handling (Cmd+N new conversation, Cmd+W close, etc.)
- Window state persistence (position, size)
- System theme tracking (light/dark mode)

#### 2. WebViewContainer (SwiftUI) — `WebViewContainer.swift`

Wraps `WKWebView` to load the React frontend:
- Loads `codex-web/index.html` from the app bundle
- Configures `WKWebViewConfiguration` with:
  - `WKUserContentController` for message handlers
  - JavaScript injection for the ElectronBridge shim
  - File access for local workspace files
  - WebSocket access to `127.0.0.1` (app-server)
- Handles navigation (block external URLs, open in default browser)

#### 3. ElectronBridge — `ElectronBridge.swift` + `preload-shim.js`

Replaces Electron's `contextBridge.exposeInMainWorld('electronBridge', ...)` with a WKWebView-compatible shim.

**Swift side** (`ElectronBridge.swift`):
```swift
class ElectronBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else { return }
        
        switch method {
        case "sendMessageFromView":
            // Forward to app-server via stdio/WebSocket
            appServerManager.send(body["payload"])
        case "showContextMenu":
            // Build and show native NSMenu
            showNativeContextMenu(body["items"])
        case "showApplicationMenu":
            // Show native menu at coordinates
            showNativeAppMenu(body["menuId"], x: body["x"], y: body["y"])
        case "getPathForFile":
            // Return file path
            replyToJS(id: body["callId"], result: filePath)
        case "getSystemThemeVariant":
            let theme = NSApp.effectiveAppearance.name == .darkAqua ? "dark" : "light"
            replyToJS(id: body["callId"], result: theme)
        default:
            break
        }
    }
}
```

**JavaScript side** (`preload-shim.js`):
```javascript
// Injected before the React app loads
// Replaces window.electronBridge with WKWebView-compatible version

window.codexWindowType = "electron"; // React app checks this
window.electronBridge = {
    sendMessageFromView: async (msg) => {
        // Forward to Swift via WKScriptMessageHandler
        window.webkit.messageHandlers.electronBridge.postMessage({
            method: "sendMessageFromView",
            payload: msg
        });
    },
    
    getPathForFile: (file) => file.path || file.name,
    
    showContextMenu: async (items) => {
        window.webkit.messageHandlers.electronBridge.postMessage({
            method: "showContextMenu",
            items: items
        });
    },
    
    showApplicationMenu: async (menuId, x, y) => {
        window.webkit.messageHandlers.electronBridge.postMessage({
            method: "showApplicationMenu",
            menuId, x, y
        });
    },
    
    getSystemThemeVariant: () => {
        return window.matchMedia('(prefers-color-scheme: dark)').matches 
            ? 'dark' : 'light';
    },
    
    subscribeToSystemThemeVariant: (callback) => {
        const mq = window.matchMedia('(prefers-color-scheme: dark)');
        const handler = () => callback();
        mq.addEventListener('change', handler);
        return () => mq.removeEventListener('change', handler);
    },
    
    subscribeToWorkerMessages: (workerId, callback) => {
        // Subscribe via message event listener
        const handler = (event) => {
            if (event.data?.workerId === workerId) callback(event.data);
        };
        window.addEventListener('message', handler);
        return () => window.removeEventListener('message', handler);
    },
    
    sendWorkerMessageFromView: async (workerId, msg) => {
        window.webkit.messageHandlers.electronBridge.postMessage({
            method: "sendWorkerMessageFromView",
            workerId, payload: msg
        });
    },
    
    getSharedObjectSnapshotValue: (key) => {
        return window.__codexSharedState?.[key];
    },
    
    getSentryInitOptions: () => ({ disabled: true }),
    getAppSessionId: () => window.__codexSessionId,
    getBuildFlavor: () => "prod",
    getFastModeRolloutMetrics: async () => ({}),
    triggerSentryTestError: async () => {},
};
```

**13 methods, categorized by implementation effort:**
- **Trivial** (return static values): `getBuildFlavor`, `getAppSessionId`, `getSentryInitOptions`, `triggerSentryTestError`, `getFastModeRolloutMetrics`, `getSharedObjectSnapshotValue` — 6 methods
- **Simple** (native API mapping): `getSystemThemeVariant`, `subscribeToSystemThemeVariant`, `getPathForFile` — 3 methods
- **Medium** (Swift ↔ JS coordination): `showContextMenu`, `showApplicationMenu` — 2 methods
- **Critical** (core IPC): `sendMessageFromView`, `subscribeToWorkerMessages`, `sendWorkerMessageFromView` — 3 methods (the message bus)

#### 4. AppServerManager — `AppServerManager.swift`

Manages the Rust `codex app-server` child process:

```swift
actor AppServerManager {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    
    func start(workspace: String) {
        let process = Process()
        process.executableURL = Bundle.main.url(forResource: "codex", withExtension: nil)
        process.arguments = ["app-server", "--analytics-default-enabled"]
        process.environment = [
            "CODEX_HOME": "~/.codex".expandingTildeInPath,
            "HOME": NSHomeDirectory()
        ]
        
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        
        // Read JSON-RPC responses from stdout
        stdoutPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            self.handleAppServerResponse(data)
        }
        
        // Auto-restart on crash
        process.terminationHandler = { [weak self] _ in
            Task { await self?.restart(workspace: workspace) }
        }
        
        try process.run()
    }
    
    func send(_ message: [String: Any]) {
        // JSON-RPC over stdin
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let line = String(data: data, encoding: .utf8) else { return }
        stdinPipe?.fileHandleForReading.write((line + "\n").data(using: .utf8)!)
    }
}
```

The app-server's JSON-RPC messages flow:
```
React frontend (in WKWebView)
    ↕ (WebSocket ws://127.0.0.1:PORT — direct, same as VS Code extension)
codex app-server (Rust, --ws-addr 127.0.0.1:0)
    ↕ (HTTPS/WebSocket)
OpenAI API
```

The React frontend already has WebSocket client code for connecting to the app-server (used in VS Code mode). By launching the app-server with `--ws-addr 127.0.0.1:0` instead of stdio, the React code connects directly — no Swift bridging needed for the primary message channel. The ElectronBridge only handles the ~7 non-trivial Electron API shims (menus, theme, file paths), not the core IPC.

#### 5. CodexSwitch Integration — `CodexSwitchBridge.swift`

Communication between CodexSwitch and CodexNative:

```swift
// CodexSwitch posts this after writing auth.json
DistributedNotificationCenter.default().post(
    name: .init("com.codexswitch.accountSwapped"),
    object: nil,
    userInfo: ["email": newAccount.email]
)

// CodexNative listens and reloads auth in the WebView
DistributedNotificationCenter.default().addObserver(
    forName: .init("com.codexswitch.accountSwapped"),
    object: nil, queue: .main
) { notification in
    // The app-server's file watcher detects auth.json change in ~2s
    // But we can also trigger immediate reload in the React frontend:
    webView.evaluateJavaScript("""
        window.dispatchEvent(new MessageEvent('message', {
            data: { type: 'account-login-completed', success: true }
        }));
    """)
}
```

No process kill, no SIGHUP, no WebSocket reconnect. The app-server's file watcher handles auth reload; the JavaScript injection handles UI refresh.

### Build System

#### Asar Extraction Script — `scripts/extract-codex-frontend.sh`

```bash
#!/bin/bash
# Extract React frontend from the latest Codex.app for CodexNative
set -euo pipefail

CODEX_APP="/Applications/Codex.app"
ASAR="$CODEX_APP/Contents/Resources/app.asar"
OUTPUT="$1"  # e.g., CodexNative/Resources/codex-web

# Extract
npx asar extract "$ASAR" "$OUTPUT/extracted"

# Copy webview assets (the React frontend)
cp -r "$OUTPUT/extracted/webview/"* "$OUTPUT/"

# Inject our preload shim
cp scripts/preload-shim.js "$OUTPUT/preload-shim.js"

# Patch index.html to load our shim before the React app
sed -i '' 's|<head>|<head><script src="preload-shim.js"></script>|' "$OUTPUT/index.html"

# Clean up
rm -rf "$OUTPUT/extracted"

echo "Frontend extracted from Codex $(defaults read "$CODEX_APP/Contents/Info" CFBundleShortVersionString)"
```

Run on each Codex update to sync the React frontend.

#### Auto-Update Pipeline

CodexSwitch already monitors Codex versions via `CodexVersionChecker`. On update:

1. Detect new Codex version (existing logic)
2. Extract React frontend from new asar (`extract-codex-frontend.sh`)
3. Copy to `CodexNative.app/Contents/Resources/codex-web/`
4. Re-sign CodexNative.app
5. Log `FRONTEND_UPDATED version=X.Y.Z`

No rebuild needed — just file copy. The React code is loaded from disk by WKWebView on each launch.

### Future: Progressive SwiftUI Migration (Phase 2-3)

Once CodexNative is stable, gradually replace WKWebView components with native SwiftUI:

1. **Protocol-driven renderer registry** — SwiftUI views keyed by JSON-RPC item type
2. **Auto-generation pipeline** — on each upstream release, use Claude to convert new React components to SwiftUI
3. **Hybrid rendering** — SwiftUI for components we've migrated, WKWebView for the rest
4. **Fallback renderer** — unknown item types display as formatted JSON until a proper renderer is built
5. **End state** — WKWebView fully replaced, zero web technology

### Performance Targets

| Metric | Electron (current) | CodexNative (Phase 1) | CodexNative (Phase 3) |
|---|---|---|---|
| Cold start | ~3s | ~1s | <0.5s |
| Memory (idle) | ~400MB | ~80MB | ~40MB |
| Memory (500-turn conversation) | ~2-4GB | ~200-400MB | ~100MB |
| Memory (8hr session) | ~3-6GB (growing) | ~300MB (stable) | ~100MB (stable) |
| App bundle size | 316MB | ~30MB | ~20MB |
| Process count | 4-6 | 2 (app + server) | 2 (app + server) |

### Distribution

**DMG installer:**
- CodexNative.app with bundled app-server binary
- First-launch setup: detect CodexSwitch, offer to install if missing
- Auto-update via Sparkle (our own feed, not OpenAI's)

**Homebrew:**
- `brew install --cask codex-native`
- Depends on `codex` (CLI) for the app-server binary
- CodexSwitch as optional dependency

### Implementation Estimate

| Component | Effort | Dependencies |
|---|---|---|
| SwiftUI app shell + window management | 1 day | None |
| WKWebView container + configuration | 1 day | App shell |
| ElectronBridge (Swift + JS shim) | 2-3 days | WKWebView |
| AppServerManager (process lifecycle) | 1 day | None |
| Asar extraction script | 0.5 day | None |
| CodexSwitch integration (notifications) | 1 day | ElectronBridge |
| Testing + debugging + polish | 2-3 days | All above |
| **Path B total** | **~10 days** | |
| Upstream profiling + fixes (Path A) | 3-5 days | Chrome DevTools |
| **Grand total** | **~2-3 weeks** | |

### Risks

1. **Electron API surface changes** — OpenAI could add new `electronBridge` methods. Mitigation: the shim logs unknown method calls; we add them as discovered.
2. **WKWebView quirks** — some React code may assume Chromium-specific behavior. Mitigation: test thoroughly; WKWebView supports modern web standards well.
3. **App-server stdio protocol** — if OpenAI changes the IPC from stdio to something Electron-specific. Mitigation: the protocol is shared with VS Code extension, unlikely to become Electron-only.
4. **React frontend size growth** — the extracted frontend is currently 42MB. Mitigation: WKWebView handles large bundles efficiently; we can tree-shake unused code.
