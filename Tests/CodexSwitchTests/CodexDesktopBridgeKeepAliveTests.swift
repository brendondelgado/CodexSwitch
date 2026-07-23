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

    @Test("Bridge restart targets only the managed job and proves PID replacement")
    func bridgeRestartRequiresNewManagedPID() {
        var observedArguments: [String] = []
        var observedTimeout: TimeInterval?
        var pids: [Int32?] = [41, 41, nil, 42]
        var pauses = 0

        let result = CodexDesktopBridgeKeepAlive.restartLoadedBridge(
            pidProvider: {
                pids.isEmpty ? nil : pids.removeFirst()
            },
            run: { executableURL, arguments, timeout in
                #expect(executableURL.path == "/bin/launchctl")
                observedArguments = arguments
                observedTimeout = timeout
                return ProcessRunResult(
                    terminationStatus: 0,
                    stdout: Data(),
                    stderr: Data(),
                    timedOut: false
                )
            },
            pause: { _ in pauses += 1 }
        )

        #expect(result.success)
        #expect(result.attempted)
        #expect(observedArguments == [
            "kickstart",
            "-k",
            "gui/\(getuid())/com.codexswitch.desktop-app-server-9223",
        ])
        #expect(observedTimeout == 5)
        #expect(pauses == 2)
    }

    @Test("Bridge restart fails closed when launchd does not own a live bridge")
    func bridgeRestartRequiresLoadedJob() {
        var invoked = false
        let result = CodexDesktopBridgeKeepAlive.restartLoadedBridge(
            pidProvider: { nil },
            run: { _, _, _ in
                invoked = true
                return ProcessRunResult(
                    terminationStatus: 0,
                    stdout: Data(),
                    stderr: Data(),
                    timedOut: false
                )
            },
            pause: { _ in }
        )

        #expect(!result.success)
        #expect(!result.attempted)
        #expect(!invoked)
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
        let verifiedRoute = CodexManagedRuntimeTrust.VerifiedRoute(
            route: route,
            runtimeIdentity: fileIdentity
        )

        #expect(CodexDesktopBridgeKeepAlive.firstAcknowledgementBootstrapIsAuthorized(
            binding: binding,
            socketPort: 9223,
            launchAgentPID: 42,
            bridgeFilesCurrent: true,
            verifiedRoute: verifiedRoute
        ))
        #expect(CodexManagedRuntimeTrust.verifiedRouteAuthorizes(
            binding,
            verifiedRoute: verifiedRoute
        ))
        #expect(!CodexDesktopBridgeKeepAlive.firstAcknowledgementBootstrapIsAuthorized(
            binding: binding,
            socketPort: 8390,
            launchAgentPID: 42,
            bridgeFilesCurrent: true,
            verifiedRoute: verifiedRoute
        ))
        #expect(!CodexDesktopBridgeKeepAlive.firstAcknowledgementBootstrapIsAuthorized(
            binding: binding,
            socketPort: 9223,
            launchAgentPID: 43,
            bridgeFilesCurrent: true,
            verifiedRoute: verifiedRoute
        ))
        #expect(!CodexDesktopBridgeKeepAlive.firstAcknowledgementBootstrapIsAuthorized(
            binding: binding,
            socketPort: 9223,
            launchAgentPID: 42,
            bridgeFilesCurrent: true,
            verifiedRoute: CodexManagedRuntimeTrust.VerifiedRoute(
                route: route,
                runtimeIdentity: DesktopInstallPathIdentity(device: 7, inode: 10)
            )
        ))
        #expect(!CodexManagedRuntimeTrust.verifiedRouteAuthorizes(
            CodexReloadBinding(
                processIdentity: identity,
                kernelExecutableIdentity: CodexKernelExecutableIdentity(
                    canonicalPath: runtime,
                    device: 7,
                    inode: 10
                ),
                runtimeKind: .localInteractiveCLI,
                authFileIdentity: binding.authFileIdentity,
                requestNonce: "other-nonce",
                issuedAtUnixMilliseconds: 1_000_200
            ),
            verifiedRoute: verifiedRoute
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
