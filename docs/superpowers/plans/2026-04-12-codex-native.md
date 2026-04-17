# CodexNative Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS app that replaces the Electron-based Codex desktop app with WKWebView + the same React frontend, eliminating Chromium and reducing memory usage by ~80%.

**Architecture:** SwiftUI app shell wraps a WKWebView that loads OpenAI's React frontend (extracted from the Electron asar). A JavaScript shim (`preload-shim.js`) replaces the `window.electronBridge` API so the React code doesn't know it's not in Electron. The Rust `codex app-server` is spawned with `--listen ws://127.0.0.1:0` so the React frontend connects directly via WebSocket — no Swift bridging needed for the core IPC. CodexSwitch communicates via `DistributedNotificationCenter`.

**Tech Stack:** Swift 6.0, SwiftUI, WebKit (WKWebView), JavaScript (preload shim), Bash (asar extraction)

**Spec:** `docs/superpowers/specs/2026-04-12-codex-performance-design.md`

---

## File Structure

```
Sources/CodexNative/
├── App/
│   ├── CodexNativeApp.swift          — @main entry point, app lifecycle
│   └── AppDelegate.swift             — NSApplicationDelegate, window management, menus
├── WebView/
│   ├── WebViewContainer.swift        — SwiftUI WKWebView wrapper
│   ├── WebViewCoordinator.swift      — WKNavigationDelegate + WKUIDelegate
│   └── ElectronBridge.swift          — WKScriptMessageHandler, shims Electron APIs
├── AppServer/
│   ├── AppServerManager.swift        — Spawns/manages the Rust app-server process
│   └── AppServerPortDiscovery.swift  — Reads the dynamically assigned WebSocket port
├── Integration/
│   └── CodexSwitchBridge.swift       — DistributedNotificationCenter listener for hot-swap
└── Resources/
    └── preload-shim.js               — JavaScript Electron API replacement

scripts/
└── extract-codex-frontend.sh         — Extracts React frontend from Codex.app asar

Tests/CodexNativeTests/
├── AppServerManagerTests.swift
├── ElectronBridgeTests.swift
└── AppServerPortDiscoveryTests.swift
```

---

### Task 1: Asar Extraction Script

**Files:**
- Create: `scripts/extract-codex-frontend.sh`
- Create: `Sources/CodexNative/Resources/codex-web/.gitkeep`

This must run first — everything else needs the extracted React frontend.

- [ ] **Step 1: Create the extraction script**

```bash
cat > scripts/extract-codex-frontend.sh << 'SCRIPT'
#!/bin/bash
# Extract React frontend from Codex.app for CodexNative
set -euo pipefail

CODEX_APP="${CODEX_APP:-/Applications/Codex.app}"
ASAR="$CODEX_APP/Contents/Resources/app.asar"
OUTPUT="${1:-Sources/CodexNative/Resources/codex-web}"

if [ ! -f "$ASAR" ]; then
    echo "ERROR: $ASAR not found. Install Codex.app first."
    exit 1
fi

echo "Extracting from $ASAR..."

# Create temp dir for extraction
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Extract asar
npx --yes asar extract "$ASAR" "$TMPDIR/extracted"

# Clear existing output (except .gitkeep)
find "$OUTPUT" -mindepth 1 -not -name '.gitkeep' -delete 2>/dev/null || true
mkdir -p "$OUTPUT/assets"

# Copy webview assets (the React frontend)
cp -r "$TMPDIR/extracted/webview/"* "$OUTPUT/"

# Read Codex version
VERSION=$(defaults read "$CODEX_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "unknown")
BUILD=$(defaults read "$CODEX_APP/Contents/Info" CFBundleVersion 2>/dev/null || echo "unknown")

# Write version marker
echo "{\"version\": \"$VERSION\", \"build\": \"$BUILD\", \"extracted_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$OUTPUT/codex-version.json"

echo "Frontend extracted: Codex $VERSION (build $BUILD)"
echo "Output: $OUTPUT"
echo "Assets: $(ls "$OUTPUT/assets/" | wc -l | tr -d ' ') files"
SCRIPT
chmod +x scripts/extract-codex-frontend.sh
```

- [ ] **Step 2: Run the extraction**

Run: `./scripts/extract-codex-frontend.sh`
Expected: `Frontend extracted: Codex 26.409.20454 (build 1462)` (or current version)

- [ ] **Step 3: Verify extracted files**

Run: `ls Sources/CodexNative/Resources/codex-web/index.html && cat Sources/CodexNative/Resources/codex-web/codex-version.json`
Expected: `index.html` exists, version JSON shows current Codex version

- [ ] **Step 4: Add codex-web to .gitignore**

The extracted frontend is large (~42MB) and changes per Codex version. Don't commit it.

```bash
echo "Sources/CodexNative/Resources/codex-web/*" >> .gitignore
echo "!Sources/CodexNative/Resources/codex-web/.gitkeep" >> .gitignore
```

- [ ] **Step 5: Commit**

```bash
git add scripts/extract-codex-frontend.sh Sources/CodexNative/Resources/codex-web/.gitkeep .gitignore
git commit -m "feat(native): add asar extraction script for React frontend"
```

---

### Task 2: Preload Shim (JavaScript)

**Files:**
- Create: `Sources/CodexNative/Resources/preload-shim.js`

The JavaScript shim that replaces Electron's `contextBridge.exposeInMainWorld('electronBridge', ...)`. Must be injected before the React app loads.

- [ ] **Step 1: Create the preload shim**

```bash
cat > Sources/CodexNative/Resources/preload-shim.js << 'JS'
// CodexNative preload shim — replaces Electron's contextBridge
// Injected by WKWebView before the React app loads.
//
// The React frontend expects window.electronBridge with 13 methods.
// Core IPC (sendMessageFromView) is NOT needed here because the React
// app connects directly to the app-server via WebSocket. This shim
// only handles the UI-specific Electron APIs.

(function() {
    'use strict';

    // Session ID for this app launch
    const sessionId = crypto.randomUUID();

    // Shared state (replaces Electron's shared-object IPC)
    const sharedState = {};

    // Theme tracking
    let currentTheme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';

    // Pending call IDs for async Swift responses
    const pendingCalls = new Map();
    let nextCallId = 1;

    // Called by Swift to return results from async bridge calls
    window.__codexNativeBridgeReply = function(callId, result) {
        const resolve = pendingCalls.get(callId);
        if (resolve) {
            pendingCalls.delete(callId);
            resolve(result);
        }
    };

    // Called by Swift to deliver messages from the app-server or system
    window.__codexNativeDeliverMessage = function(message) {
        window.dispatchEvent(new MessageEvent('message', { data: message }));
    };

    // Helper: call Swift and wait for response
    function callSwift(method, params) {
        return new Promise((resolve) => {
            const callId = nextCallId++;
            pendingCalls.set(callId, resolve);
            window.webkit.messageHandlers.electronBridge.postMessage({
                method: method,
                callId: callId,
                ...params
            });
        });
    }

    // Helper: fire-and-forget to Swift
    function notifySwift(method, params) {
        try {
            window.webkit.messageHandlers.electronBridge.postMessage({
                method: method,
                ...params
            });
        } catch (e) {
            console.warn('[CodexNative] Bridge notify failed:', method, e);
        }
    }

    // The bridge object — matches Electron's preload.js API surface exactly
    const bridge = {
        // === Core IPC ===
        // sendMessageFromView: The React app uses this for Electron IPC.
        // In CodexNative, the React frontend connects to the app-server
        // directly via WebSocket (same as VS Code extension mode).
        // We still need to handle non-WebSocket messages (shared-object-set, log-message).
        sendMessageFromView: async (msg) => {
            if (msg.type === 'shared-object-set') {
                sharedState[msg.key] = msg.value;
                return;
            }
            if (msg.type === 'log-message') {
                // Route logs to Swift for native logging
                notifySwift('log', { level: msg.level, message: msg.message });
                return;
            }
            // Forward other messages to Swift
            notifySwift('sendMessageFromView', { payload: msg });
        },

        sendWorkerMessageFromView: async (workerId, msg) => {
            notifySwift('sendWorkerMessageFromView', { workerId, payload: msg });
        },

        subscribeToWorkerMessages: (workerId, callback) => {
            const handler = (event) => {
                const data = event.data;
                if (data && data.__workerMessage && data.workerId === workerId) {
                    callback(data.payload);
                }
            };
            window.addEventListener('message', handler);
            return () => window.removeEventListener('message', handler);
        },

        // === UI APIs ===
        showContextMenu: async (items) => {
            return callSwift('showContextMenu', { items });
        },

        showApplicationMenu: async (menuId, x, y) => {
            notifySwift('showApplicationMenu', { menuId, x, y });
        },

        getPathForFile: (file) => {
            // WKWebView doesn't expose full file paths for security.
            // Return the filename — drag-drop file access is handled separately.
            return file.name || null;
        },

        // === Theme ===
        getSystemThemeVariant: () => currentTheme,

        subscribeToSystemThemeVariant: (callback) => {
            const mq = window.matchMedia('(prefers-color-scheme: dark)');
            const handler = (e) => {
                currentTheme = e.matches ? 'dark' : 'light';
                callback();
            };
            mq.addEventListener('change', handler);
            return () => mq.removeEventListener('change', handler);
        },

        // === State ===
        getSharedObjectSnapshotValue: (key) => sharedState[key],

        // === Diagnostics ===
        getSentryInitOptions: () => ({
            disabled: true,
            codexAppSessionId: sessionId
        }),
        getAppSessionId: () => sessionId,
        getBuildFlavor: () => 'prod',
        getFastModeRolloutMetrics: async () => ({}),
        triggerSentryTestError: async () => {},
    };

    // Expose to the React app — same names as Electron's contextBridge
    window.codexWindowType = 'electron';
    window.electronBridge = bridge;

    // Log unknown method calls for debugging
    window.electronBridge = new Proxy(bridge, {
        get(target, prop) {
            if (prop in target) return target[prop];
            console.warn(`[CodexNative] Unknown electronBridge method: ${String(prop)}`);
            return (...args) => {
                console.warn(`[CodexNative] Called unknown method: ${String(prop)}`, args);
                return Promise.resolve(undefined);
            };
        }
    });

    console.log('[CodexNative] Preload shim loaded, session:', sessionId);
})();
JS
```

- [ ] **Step 2: Verify the shim covers all preload methods**

Run: `grep -o 'electronBridge\.[a-zA-Z]*' Sources/CodexNative/Resources/preload-shim.js | sort -u`
Expected: All 13 methods from the spec are present

- [ ] **Step 3: Commit**

```bash
git add Sources/CodexNative/Resources/preload-shim.js
git commit -m "feat(native): add preload shim replacing Electron contextBridge"
```

---

### Task 3: Swift Package Configuration

**Files:**
- Modify: `Package.swift`

Add the CodexNative target to the existing Swift package.

- [ ] **Step 1: Update Package.swift**

```swift
// Replace the entire Package.swift content:
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexSwitch",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CodexSwitch",
            path: "Sources/CodexSwitch",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CodexNative",
            path: "Sources/CodexNative",
            resources: [
                .copy("Resources/preload-shim.js"),
                .copy("Resources/codex-web"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CodexSwitchTests",
            dependencies: ["CodexSwitch"],
            path: "Tests/CodexSwitchTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CodexNativeTests",
            dependencies: ["CodexNative"],
            path: "Tests/CodexNativeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
```

- [ ] **Step 2: Create directory structure**

```bash
mkdir -p Sources/CodexNative/{App,WebView,AppServer,Integration,Resources}
mkdir -p Tests/CodexNativeTests
```

- [ ] **Step 3: Verify package resolves**

Run: `swift package describe`
Expected: Shows both `CodexSwitch` and `CodexNative` targets

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/CodexNative Tests/CodexNativeTests
git commit -m "feat(native): add CodexNative target to Swift package"
```

---

### Task 4: App Server Manager

**Files:**
- Create: `Sources/CodexNative/AppServer/AppServerManager.swift`
- Create: `Sources/CodexNative/AppServer/AppServerPortDiscovery.swift`
- Create: `Tests/CodexNativeTests/AppServerManagerTests.swift`

Spawns the Rust `codex app-server` with `--listen ws://127.0.0.1:0` and discovers the assigned port.

- [ ] **Step 1: Write the port discovery test**

```swift
// Tests/CodexNativeTests/AppServerManagerTests.swift
import Testing
@testable import CodexNative

@Test("Parse WebSocket port from app-server stderr")
func parsePort() {
    // The app-server prints "Listening on ws://127.0.0.1:PORT" to stderr
    let line = "Listening on ws://127.0.0.1:54321"
    let port = AppServerPortDiscovery.parsePort(from: line)
    #expect(port == 54321)
}

@Test("Parse port returns nil for non-matching lines")
func parsePortNonMatch() {
    let port = AppServerPortDiscovery.parsePort(from: "Some other log line")
    #expect(port == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CodexNativeTests`
Expected: FAIL — `AppServerPortDiscovery` not found

- [ ] **Step 3: Implement AppServerPortDiscovery**

```swift
// Sources/CodexNative/AppServer/AppServerPortDiscovery.swift
import Foundation

enum AppServerPortDiscovery {
    /// Parse the WebSocket port from an app-server log line.
    /// The app-server prints "Listening on ws://127.0.0.1:PORT" to stderr on startup.
    static func parsePort(from line: String) -> UInt16? {
        // Match "ws://127.0.0.1:PORT" or "ws://0.0.0.0:PORT"
        guard let range = line.range(of: #"ws://[\d.]+:(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = line[range]
        guard let colonIdx = match.lastIndex(of: ":") else { return nil }
        let portStr = match[match.index(after: colonIdx)...]
        return UInt16(portStr)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CodexNativeTests`
Expected: PASS

- [ ] **Step 5: Implement AppServerManager**

```swift
// Sources/CodexNative/AppServer/AppServerManager.swift
import Foundation
import os

private let logger = Logger(subsystem: "com.codexnative", category: "AppServer")

@MainActor
@Observable
final class AppServerManager {
    enum State: Equatable {
        case idle
        case starting
        case running(port: UInt16)
        case failed(error: String)
    }

    private(set) var state: State = .idle
    private var process: Process?
    private var stderrPipe: Pipe?

    /// The WebSocket URL the React frontend should connect to
    var websocketURL: URL? {
        guard case .running(let port) = state else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)")
    }

    /// Start the app-server process. Discovers the WebSocket port from stderr.
    func start(codexBinaryPath: String? = nil) {
        guard state == .idle || state != .starting else { return }
        state = .starting

        let binaryPath = codexBinaryPath ?? findCodexBinary()
        guard let binaryPath else {
            state = .failed(error: "Codex binary not found")
            logger.error("Cannot find codex binary")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "app-server",
            "--listen", "ws://127.0.0.1:0",
            "--analytics-default-enabled"
        ]

        // Inherit user's environment for PATH, HOME, etc.
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = NSString("~/.codex").expandingTildeInPath
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        self.stderrPipe = stderrPipe

        // Read stderr for port discovery + logging
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }

            for l in line.components(separatedBy: "\n") where !l.isEmpty {
                logger.info("app-server: \(l)")

                if let port = AppServerPortDiscovery.parsePort(from: l) {
                    Task { @MainActor [weak self] in
                        self?.state = .running(port: port)
                        logger.info("App-server listening on port \(port)")
                    }
                }
            }
        }

        // Auto-restart on crash
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            logger.warning("App-server exited with code \(code)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = .idle
                self.process = nil
                // Auto-restart after 1s delay
                try? await Task.sleep(for: .seconds(1))
                self.start(codexBinaryPath: binaryPath)
            }
        }

        do {
            try process.run()
            self.process = process
            logger.info("App-server started (pid \(process.processIdentifier))")
        } catch {
            state = .failed(error: error.localizedDescription)
            logger.error("Failed to start app-server: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        state = .idle
    }

    /// Find the codex binary — check common locations
    private func findCodexBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            NSString("~/.codex/bin/codex").expandingTildeInPath,
            "/usr/local/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add Sources/CodexNative/AppServer/ Tests/CodexNativeTests/
git commit -m "feat(native): add AppServerManager with port discovery"
```

---

### Task 5: Electron Bridge (Swift Side)

**Files:**
- Create: `Sources/CodexNative/WebView/ElectronBridge.swift`

Handles `WKScriptMessageHandler` calls from the preload shim.

- [ ] **Step 1: Implement ElectronBridge**

```swift
// Sources/CodexNative/WebView/ElectronBridge.swift
import AppKit
import WebKit
import os

private let logger = Logger(subsystem: "com.codexnative", category: "ElectronBridge")

final class ElectronBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            logger.warning("Invalid bridge message: \(String(describing: message.body))")
            return
        }

        let callId = body["callId"] as? Int

        switch method {
        case "showContextMenu":
            handleShowContextMenu(body["items"], callId: callId)
        case "showApplicationMenu":
            handleShowApplicationMenu(body)
        case "log":
            handleLog(body)
        case "sendMessageFromView":
            handleSendMessage(body)
        default:
            logger.debug("Unhandled bridge method: \(method)")
        }
    }

    // MARK: - Handlers

    private func handleShowContextMenu(_ items: Any?, callId: Int?) {
        guard let items = items as? [[String: Any]] else { return }

        Task { @MainActor in
            let menu = NSMenu()
            for (index, item) in items.enumerated() {
                if let label = item["label"] as? String {
                    let menuItem = NSMenuItem(title: label, action: #selector(contextMenuAction(_:)), keyEquivalent: "")
                    menuItem.target = self
                    menuItem.tag = index
                    if let accelerator = item["accelerator"] as? String {
                        menuItem.keyEquivalent = accelerator
                    }
                    if item["type"] as? String == "separator" {
                        menu.addItem(.separator())
                    } else {
                        menu.addItem(menuItem)
                    }
                }
            }

            if let webView, let window = webView.window {
                let location = window.mouseLocationOutsideOfEventStream
                menu.popUp(positioning: nil, at: location, in: webView)
            }

            // Reply with selected index (or -1 if cancelled)
            if let callId {
                replyToJS(callId: callId, result: -1)
            }
        }
    }

    @objc private func contextMenuAction(_ sender: NSMenuItem) {
        // Deliver selection to React via postMessage
        deliverMessage(["type": "context-menu-selection", "index": sender.tag])
    }

    private func handleShowApplicationMenu(_ body: [String: Any]) {
        // Application menu is handled natively by the SwiftUI menu bar
        logger.debug("showApplicationMenu: \(body["menuId"] as? String ?? "unknown")")
    }

    private func handleLog(_ body: [String: Any]) {
        let level = body["level"] as? String ?? "debug"
        let msg = body["message"] as? String ?? ""
        switch level {
        case "error": logger.error("[React] \(msg)")
        case "warning": logger.warning("[React] \(msg)")
        case "info": logger.info("[React] \(msg)")
        default: logger.debug("[React] \(msg)")
        }
    }

    private func handleSendMessage(_ body: [String: Any]) {
        // Non-WebSocket messages from the React app (shared-object-set, etc.)
        guard let payload = body["payload"] as? [String: Any] else { return }
        let type = payload["type"] as? String ?? ""
        logger.debug("sendMessageFromView: \(type)")
    }

    // MARK: - JS Communication

    func replyToJS(callId: Int, result: Any) {
        let resultJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: result),
           let str = String(data: data, encoding: .utf8) {
            resultJSON = str
        } else if let str = result as? String {
            resultJSON = "'\(str)'"
        } else {
            resultJSON = String(describing: result)
        }

        let js = "window.__codexNativeBridgeReply(\(callId), \(resultJSON));"
        Task { @MainActor in
            try? await webView?.evaluateJavaScript(js)
        }
    }

    func deliverMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__codexNativeDeliverMessage(\(json));"
        Task { @MainActor in
            try? await webView?.evaluateJavaScript(js)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/CodexNative/WebView/ElectronBridge.swift
git commit -m "feat(native): add ElectronBridge WKScriptMessageHandler"
```

---

### Task 6: WebView Container

**Files:**
- Create: `Sources/CodexNative/WebView/WebViewContainer.swift`
- Create: `Sources/CodexNative/WebView/WebViewCoordinator.swift`

The SwiftUI view that wraps WKWebView, injects the preload shim, and loads the React frontend.

- [ ] **Step 1: Implement WebViewCoordinator**

```swift
// Sources/CodexNative/WebView/WebViewCoordinator.swift
import WebKit
import os

private let logger = Logger(subsystem: "com.codexnative", category: "WebView")

final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }

        // Allow local file:// URLs (our React frontend)
        if url.isFileURL { return .allow }

        // Allow WebSocket connections to localhost (app-server)
        if url.scheme == "ws" || url.scheme == "wss" { return .allow }

        // Allow localhost HTTP (health checks, etc.)
        if url.host == "127.0.0.1" || url.host == "localhost" { return .allow }

        // External URLs: open in default browser, don't navigate
        NSWorkspace.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.info("React frontend loaded")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logger.error("Navigation failed: \(error.localizedDescription)")
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Open target="_blank" links in default browser
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}
```

- [ ] **Step 2: Implement WebViewContainer**

```swift
// Sources/CodexNative/WebView/WebViewContainer.swift
import SwiftUI
import WebKit
import os

private let logger = Logger(subsystem: "com.codexnative", category: "WebViewContainer")

struct WebViewContainer: NSViewRepresentable {
    let appServerPort: UInt16
    let electronBridge: ElectronBridge

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Register the Electron bridge message handler
        config.userContentController.add(electronBridge, name: "electronBridge")

        // Inject preload shim before page loads
        if let shimURL = Bundle.main.url(forResource: "preload-shim", withExtension: "js"),
           let shimJS = try? String(contentsOf: shimURL) {
            let script = WKUserScript(
                source: shimJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)
        } else {
            logger.error("Failed to load preload-shim.js from bundle")
        }

        // Inject the app-server WebSocket URL so the React app knows where to connect
        let wsConfig = WKUserScript(
            source: """
                window.__CODEX_APP_SERVER_WS_URL = 'ws://127.0.0.1:\(appServerPort)';
                window.__CODEX_NATIVE = true;
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(wsConfig)

        // Allow file access for loading local frontend
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Enable developer tools in debug builds
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        electronBridge.webView = webView

        // Load the React frontend
        if let indexURL = Bundle.main.url(forResource: "codex-web/index", withExtension: "html") {
            let baseURL = indexURL.deletingLastPathComponent()
            webView.loadFileURL(indexURL, allowingReadAccessTo: baseURL)
            logger.info("Loading React frontend from \(indexURL.path)")
        } else {
            logger.error("codex-web/index.html not found in bundle")
            // Load error page
            webView.loadHTMLString("""
                <html><body style="background:#1a1a1a;color:white;font-family:system-ui;padding:40px;">
                <h1>CodexNative</h1>
                <p>React frontend not found. Run:</p>
                <pre>./scripts/extract-codex-frontend.sh</pre>
                </body></html>
            """, baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // No dynamic updates needed — the React app handles its own state
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/CodexNative/WebView/WebViewContainer.swift Sources/CodexNative/WebView/WebViewCoordinator.swift
git commit -m "feat(native): add WebView container with preload injection"
```

---

### Task 7: CodexSwitch Integration

**Files:**
- Create: `Sources/CodexNative/Integration/CodexSwitchBridge.swift`

Listens for account swap notifications from CodexSwitch via `DistributedNotificationCenter`.

- [ ] **Step 1: Implement CodexSwitchBridge**

```swift
// Sources/CodexNative/Integration/CodexSwitchBridge.swift
import Foundation
import WebKit
import os

private let logger = Logger(subsystem: "com.codexnative", category: "CodexSwitchBridge")

@MainActor
final class CodexSwitchBridge {
    private var observer: NSObjectProtocol?
    private weak var webView: WKWebView?

    static let accountSwappedNotification = NSNotification.Name("com.codexswitch.accountSwapped")

    func start(webView: WKWebView) {
        self.webView = webView

        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.accountSwappedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let email = notification.userInfo?["email"] as? String ?? "unknown"
            logger.info("Account swapped to \(email)")
            Task { @MainActor in
                self?.notifyReactOfAccountChange()
            }
        }

        logger.info("Listening for CodexSwitch account swap notifications")
    }

    func stop() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
    }

    /// Tell the React frontend that the account changed.
    /// The app-server's file watcher reloads auth.json within 2s.
    /// This JS injection triggers the React UI to refresh immediately.
    private func notifyReactOfAccountChange() {
        let js = """
            window.dispatchEvent(new MessageEvent('message', {
                data: {
                    type: 'account-login-completed',
                    success: true
                }
            }));
            window.dispatchEvent(new MessageEvent('message', {
                data: {
                    type: 'account-updated',
                    authMode: 'chatgpt'
                }
            }));
        """
        webView?.evaluateJavaScript(js) { _, error in
            if let error {
                logger.warning("Failed to notify React of account change: \(error.localizedDescription)")
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/CodexNative/Integration/CodexSwitchBridge.swift
git commit -m "feat(native): add CodexSwitch bridge for hot-swap notifications"
```

---

### Task 8: App Shell + Main Entry Point

**Files:**
- Create: `Sources/CodexNative/App/CodexNativeApp.swift`
- Create: `Sources/CodexNative/App/AppDelegate.swift`

The SwiftUI app shell that ties everything together.

- [ ] **Step 1: Implement AppDelegate**

```swift
// Sources/CodexNative/App/AppDelegate.swift
import AppKit
import os

private let logger = Logger(subsystem: "com.codexnative", category: "AppDelegate")

@MainActor
final class CodexNativeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Standard app behavior — activate on launch
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        logger.info("CodexNative launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("CodexNative shutting down")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running when window is closed (menu bar presence via CodexSwitch)
    }
}
```

- [ ] **Step 2: Implement CodexNativeApp**

```swift
// Sources/CodexNative/App/CodexNativeApp.swift
import SwiftUI
import os

private let logger = Logger(subsystem: "com.codexnative", category: "App")

@main
struct CodexNativeApp: App {
    @NSApplicationDelegateAdaptor(CodexNativeAppDelegate.self) var appDelegate

    @State private var appServerManager = AppServerManager()
    @State private var electronBridge = ElectronBridge()
    @State private var codexSwitchBridge = CodexSwitchBridge()

    var body: some Scene {
        WindowGroup {
            Group {
                switch appServerManager.state {
                case .idle, .starting:
                    startupView
                case .running(let port):
                    WebViewContainer(
                        appServerPort: port,
                        electronBridge: electronBridge
                    )
                    .frame(minWidth: 800, minHeight: 600)
                    .onAppear {
                        // Start CodexSwitch bridge once WebView is ready
                        // (bridge needs webView reference, set after first render)
                    }
                case .failed(let error):
                    errorView(error)
                }
            }
            .onAppear {
                appServerManager.start()
            }
            .onDisappear {
                codexSwitchBridge.stop()
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Native keyboard shortcuts
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    // Send to React via bridge
                    electronBridge.deliverMessage(["type": "new-conversation"])
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private var startupView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Starting Codex...")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Failed to start Codex")
                .font(.title2)
            Text(error)
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Retry") {
                appServerManager.start()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `swift build --target CodexNative 2>&1 | tail -5`
Expected: Build succeeds (may have warnings, no errors)

- [ ] **Step 4: Commit**

```bash
git add Sources/CodexNative/App/
git commit -m "feat(native): add app shell with SwiftUI entry point"
```

---

### Task 9: Build + Run Script

**Files:**
- Create: `scripts/build-codex-native.sh`

Build the app bundle, copy resources, and code sign.

- [ ] **Step 1: Create the build script**

```bash
cat > scripts/build-codex-native.sh << 'SCRIPT'
#!/bin/bash
# Build CodexNative.app — the native macOS replacement for Codex Electron
set -euo pipefail

APP_NAME="CodexNative"
APP_DIR="/Applications/$APP_NAME.app"
BUILD_DIR=".build/release"

echo "=== Building $APP_NAME ==="

# 1. Ensure React frontend is extracted
if [ ! -f "Sources/CodexNative/Resources/codex-web/index.html" ]; then
    echo "Extracting React frontend..."
    ./scripts/extract-codex-frontend.sh
fi

# 2. Build the Swift binary
swift build -c release --target CodexNative

# 3. Create app bundle
echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/CodexNative" "$APP_DIR/Contents/MacOS/CodexNative"

# Copy resources
cp -r Sources/CodexNative/Resources/codex-web "$APP_DIR/Contents/Resources/"
cp Sources/CodexNative/Resources/preload-shim.js "$APP_DIR/Contents/Resources/"

# Find and copy the codex binary for the app-server
CODEX_BIN=$(which codex 2>/dev/null || echo "/opt/homebrew/bin/codex")
if [ -f "$CODEX_BIN" ]; then
    cp "$CODEX_BIN" "$APP_DIR/Contents/Resources/codex"
    chmod 755 "$APP_DIR/Contents/Resources/codex"
fi

# Write Info.plist
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CodexNative</string>
    <key>CFBundleIdentifier</key>
    <string>com.codexswitch.native</string>
    <key>CFBundleName</key>
    <string>CodexNative</string>
    <key>CFBundleDisplayName</key>
    <string>Codex</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Codex uses the microphone for voice input.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

# 4. Code sign
codesign --force --deep --sign - "$APP_DIR"
xattr -cr "$APP_DIR"

echo "=== Built: $APP_DIR ==="
echo "Bundle size: $(du -sh "$APP_DIR" | cut -f1)"
echo "Run: open -a $APP_NAME"
SCRIPT
chmod +x scripts/build-codex-native.sh
```

- [ ] **Step 2: Run the build**

Run: `./scripts/build-codex-native.sh`
Expected: `Built: /Applications/CodexNative.app` with bundle size ~30MB

- [ ] **Step 3: Launch and test**

Run: `open -a CodexNative`
Expected: Window appears with "Starting Codex..." then loads the React frontend

- [ ] **Step 4: Commit**

```bash
git add scripts/build-codex-native.sh
git commit -m "feat(native): add build script for CodexNative.app"
```

---

### Task 10: CodexSwitch — Post Swap Notifications

**Files:**
- Modify: `Sources/CodexSwitch/App/AppDelegate.swift`

Add `DistributedNotificationCenter` post in `executeSwap` so CodexNative receives hot-swap events.

- [ ] **Step 1: Add notification post to executeSwap**

In `Sources/CodexSwitch/App/AppDelegate.swift`, find `executeSwap` and add after `SwapLog.append(.swapCompleted(...))`:

```swift
// Notify CodexNative of account change (if running)
DistributedNotificationCenter.default().post(
    name: .init("com.codexswitch.accountSwapped"),
    object: nil,
    userInfo: ["email": to.email]
)
```

- [ ] **Step 2: Build CodexSwitch to verify**

Run: `swift build -c release --target CodexSwitch`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/CodexSwitch/App/AppDelegate.swift
git commit -m "feat(switch): post distributed notification on account swap for CodexNative"
```

---

### Task 11: End-to-End Testing

No new files — this is a manual verification task.

- [ ] **Step 1: Build and install everything**

```bash
./scripts/build-codex-native.sh
swift build -c release --target CodexSwitch
kill -9 $(pgrep -f "CodexSwitch.app") 2>/dev/null
cp -f .build/release/CodexSwitch /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch
codesign --force --deep --sign - /Applications/CodexSwitch.app
xattr -cr /Applications/CodexSwitch.app
open -a CodexSwitch
open -a CodexNative
```

- [ ] **Step 2: Verify React frontend loads**

Expected: CodexNative window shows the Codex chat interface (same as Electron app)

- [ ] **Step 3: Verify conversation works**

Send a test message in CodexNative. Expected: response streams in, tool calls render, code blocks highlight.

- [ ] **Step 4: Verify hot-swap**

In CodexSwitch, manually swap to a different account. Expected: CodexNative shows the new account without restart.

- [ ] **Step 5: Verify memory**

Run: `ps aux | grep CodexNative | grep -v grep` and note RSS. Compare with Codex.app RSS.
Expected: CodexNative uses ~80MB idle vs ~400MB for Electron.

- [ ] **Step 6: Commit any fixes from testing**

```bash
git add -A
git commit -m "fix(native): adjustments from end-to-end testing"
```

---

## Execution Notes

- **Tasks 1-3** have no dependencies and can run in parallel
- **Task 4** (AppServerManager) has no dependencies
- **Task 5** (ElectronBridge) has no dependencies  
- **Task 6** (WebViewContainer) depends on Tasks 4 + 5
- **Task 7** (CodexSwitchBridge) has no dependencies
- **Task 8** (App Shell) depends on Tasks 4 + 5 + 6 + 7
- **Task 9** (Build Script) depends on Task 8
- **Task 10** (CodexSwitch notification) is independent
- **Task 11** (E2E testing) depends on everything

**Parallel execution groups:**
- Group A: Tasks 1, 2, 3, 4, 5, 7, 10 (all independent)
- Group B: Task 6 (needs 4 + 5)
- Group C: Task 8 (needs all of Group A + B)
- Group D: Tasks 9, 11 (sequential, need Group C)
