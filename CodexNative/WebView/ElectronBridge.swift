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
        Task { @MainActor [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func deliverMessage(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__codexNativeDeliverMessage(\(json));"
        Task { @MainActor [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
