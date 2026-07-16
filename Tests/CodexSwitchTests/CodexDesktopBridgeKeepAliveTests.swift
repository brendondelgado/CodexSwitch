import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex desktop bridge keepalive")
struct CodexDesktopBridgeKeepAliveTests {
    @Test("Bridge script publishes one loopback WebSocket endpoint")
    func bridgeScriptUsesSingleManagedEndpoint() {
        let script = CodexDesktopBridgeKeepAlive.bridgeScript(
            launcherPath: "/Users/me/.local/share/codexswitch/patched-codex/codex"
        )

        #expect(script.contains("CODEX_APP_SERVER_WS_URL"))
        #expect(script.contains("ws://127.0.0.1:9223"))
        #expect(script.contains("app-server"))
        #expect(script.contains("--listen"))
        #expect(script.contains("exec \"$launcher\""))
        #expect(!script.contains("HEADROOM"))
    }

    @Test("Bridge launch agent is persistent and bounded")
    func bridgeLaunchAgentIsPersistent() {
        let plist = CodexDesktopBridgeKeepAlive.launchAgentPlist(
            scriptPath: "/Users/me/.codexswitch/bin/desktop-bridge.sh",
            standardOutputPath: "/Users/me/.codexswitch/logs/bridge.out.log",
            standardErrorPath: "/Users/me/.codexswitch/logs/bridge.err.log"
        )

        #expect(plist.contains("<string>com.codexswitch.desktop-app-server-9223</string>"))
        #expect(plist.contains("<key>RunAtLoad</key>"))
        #expect(plist.contains("<key>KeepAlive</key>"))
        #expect(plist.contains("<key>ThrottleInterval</key>"))
        #expect(plist.contains("<integer>5</integer>"))
    }

    @Test("Launch agent PID parsing requires one positive PID")
    func launchAgentPIDParsingIsUnambiguous() {
        #expect(CodexDesktopBridgeKeepAlive.launchAgentPID(from: "state = running\npid = 42\n") == 42)
        #expect(CodexDesktopBridgeKeepAlive.launchAgentPID(from: "state = waiting\n") == nil)
        #expect(
            CodexDesktopBridgeKeepAlive.launchAgentPID(
                from: "pid = 42\npid = 43\n"
            ) == nil
        )
    }

    @Test("First ACK bootstrap is limited to the exact managed bridge")
    func firstAcknowledgementBootstrapRequiresExactManagedIdentity() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let managedLauncher = home.appendingPathComponent(
            ".local/share/codexswitch/patched-codex/codex"
        ).path
        let runtime = home.appendingPathComponent(
            ".local/share/codexswitch/prepared-codex/0.144.4/runtime/codex"
        ).path
        let helper = URL(fileURLWithPath: runtime)
            .deletingLastPathComponent()
            .appendingPathComponent("codex-code-mode-host")
            .path
        let identity = CodexSignalProcessIdentity(
            pid: 42,
            ownerUID: UInt32(getuid()),
            executablePath: runtime,
            startSeconds: 1_000,
            startMicroseconds: 12
        )
        let kernelIdentity = CodexKernelExecutableIdentity(
            canonicalPath: runtime,
            device: 7,
            inode: 9
        )
        let binding = CodexReloadBinding(
            processIdentity: identity,
            kernelExecutableIdentity: kernelIdentity,
            runtimeKind: .externalAppServer,
            authFileIdentity: CodexAuthFileIdentity(
                canonicalPath: home.appendingPathComponent(".codex/auth.json").path,
                device: 8,
                inode: 10,
                accountID: "account-1",
                completeTokenFingerprint: String(repeating: "c", count: 64)
            ),
            requestNonce: "nonce",
            issuedAtUnixMilliseconds: 1_000_100
        )
        let route = CodexVersionChecker.ManagedRuntimeRoute(
            managedLauncherPath: managedLauncher,
            runtimePath: runtime,
            helperPath: helper,
            runtimeSHA256: String(repeating: "a", count: 64),
            helperSHA256: String(repeating: "b", count: 64)
        )
        let fileIdentity = DesktopInstallPathIdentity(device: 7, inode: 9)

        #expect(CodexDesktopBridgeKeepAlive.firstAcknowledgementBootstrapIsAuthorized(
            binding: binding,
            socketPort: 9223,
            launchAgentPID: 42,
            bridgeFilesCurrent: true,
            route: route,
            runtimeFileIdentity: fileIdentity,
            runtimeDigest: String(repeating: "a", count: 64),
            helperDigest: String(repeating: "b", count: 64)
        ))
        #expect(!CodexDesktopBridgeKeepAlive.firstAcknowledgementBootstrapIsAuthorized(
            binding: binding,
            socketPort: 8390,
            launchAgentPID: 42,
            bridgeFilesCurrent: true,
            route: route,
            runtimeFileIdentity: fileIdentity,
            runtimeDigest: String(repeating: "a", count: 64),
            helperDigest: String(repeating: "b", count: 64)
        ))
        #expect(!CodexDesktopBridgeKeepAlive.firstAcknowledgementBootstrapIsAuthorized(
            binding: binding,
            socketPort: 9223,
            launchAgentPID: 43,
            bridgeFilesCurrent: true,
            route: route,
            runtimeFileIdentity: fileIdentity,
            runtimeDigest: String(repeating: "a", count: 64),
            helperDigest: String(repeating: "b", count: 64)
        ))
        #expect(!CodexDesktopBridgeKeepAlive.firstAcknowledgementBootstrapIsAuthorized(
            binding: binding,
            socketPort: 9223,
            launchAgentPID: 42,
            bridgeFilesCurrent: true,
            route: route,
            runtimeFileIdentity: fileIdentity,
            runtimeDigest: String(repeating: "d", count: 64),
            helperDigest: String(repeating: "b", count: 64)
        ))
    }

    @Test("Bridge installation is scheduled off the main actor")
    func bridgeInstallationRunsOffMain() async {
        let observation = AsyncStream.makeStream(of: Bool.self)
        let installTask = await MainActor.run {
            AppDelegate.installDesktopBridgeOffMainActor {
                observation.continuation.yield(Thread.isMainThread)
                observation.continuation.finish()
            }
        }

        let ranOnMainThread = await nextElement(from: observation.stream)
        await installTask.value
        #expect(ranOnMainThread == false)
    }
}
