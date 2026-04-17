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
