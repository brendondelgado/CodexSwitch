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
