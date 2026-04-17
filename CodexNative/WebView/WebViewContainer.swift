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
