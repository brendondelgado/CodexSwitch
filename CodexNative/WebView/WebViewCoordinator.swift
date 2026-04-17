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
