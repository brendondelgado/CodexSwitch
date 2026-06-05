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
}
