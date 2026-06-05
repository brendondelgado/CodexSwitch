import Foundation
import Testing

@Suite("AppDelegate notifications")
struct AppDelegateNotificationTests {
    @Test("Codex app termination observer does not use ObjC selector callback")
    func codexAppTerminationObserverDoesNotUseObjCSelectorCallback() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(!source.contains("selector: #selector(codexAppDidTerminate"))
        #expect(!source.contains("@objc private func codexAppDidTerminate"))
        #expect(source.contains("handleCodexAppDidTerminate"))
        #expect(source.contains("queue: .main"))
        #expect(source.contains("scheduleDesktopPatchCheckIfNeeded(force: true)"))
    }

    @Test("Desktop patch monitor forces patch checks when installed Codex app changes")
    func desktopPatchMonitorForcesPatchChecksWhenInstalledCodexAppChanges() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(source.contains("lastDesktopPatchInstallationFingerprint"))
        #expect(source.contains("recordDesktopPatchInstallationFingerprintChange()"))
        #expect(source.contains("DesktopPatchManager.installationFingerprint()"))
        #expect(source.contains("let effectiveForce = force || installationChanged"))
        #expect(source.contains("ignoreCooldown: effectiveForce"))
        #expect(source.contains("ignorePermissionDeniedBackoff: effectiveForce"))
    }
}
