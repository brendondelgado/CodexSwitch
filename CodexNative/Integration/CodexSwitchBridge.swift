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
