import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex desktop native-child coordinator")
struct CodexDesktopNativeChildCoordinatorTests {
    @Test("Retirement clears the override and unloads only the legacy job")
    func retirementTargetsOnlyLegacyArtifacts() {
        var commands: [[String]] = []
        var removed: [String] = []
        let result = CodexDesktopNativeChildCoordinator.retireLegacyBridge(
            jobLoaded: { true },
            run: { executable, arguments, _ in
                #expect(executable.path == "/bin/launchctl")
                commands.append(arguments)
                return ProcessRunResult(
                    terminationStatus: 0,
                    stdout: Data(),
                    stderr: Data(),
                    timedOut: false
                )
            },
            removeGeneratedFile: { url in
                removed.append(url.lastPathComponent)
                return true
            }
        )

        #expect(result.success)
        #expect(commands == [
            ["unsetenv", "CODEX_APP_SERVER_WS_URL"],
            ["bootout", "gui/\(getuid())/com.codexswitch.desktop-app-server-9223"],
        ])
        #expect(removed.isEmpty)
    }

    @Test("Legacy artifact inventory is closed and contains no prepared CLI")
    func legacyArtifactInventoryIsClosed() {
        let files = CodexDesktopNativeChildCoordinator.legacyGeneratedFiles(
            home: URL(fileURLWithPath: "/Users/me")
        ).map(\.path)
        #expect(files == [
            "/Users/me/Library/LaunchAgents/com.codexswitch.desktop-app-server-9223.plist",
            "/Users/me/.codexswitch/bin/codexswitch-desktop-app-server-9223.sh",
        ])
        #expect(files.allSatisfy { !$0.contains("prepared-codex") })
    }

    @Test("First native ACK requires exact stdio invocation and canonical ancestry")
    func nativeBootstrapRequiresOfficialAncestry() {
        let binding = nativeBinding(pid: 42)
        let parents: [Int32: Int32] = [42: 41, 41: 40]
        let paths: [Int32: String] = [
            41: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
            40: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        ]
        #expect(CodexDesktopNativeChildCoordinator.authorizesFirstAcknowledgementBootstrap(
            binding: binding,
            arguments: ["codex", "app-server", "--listen", "stdio://"],
            parentPID: { parents[$0] },
            executablePath: { paths[$0] },
            signatureStatus: { _ in .officialOpenAI }
        ))
        #expect(!CodexDesktopNativeChildCoordinator.authorizesFirstAcknowledgementBootstrap(
            binding: binding,
            arguments: ["codex", "app-server", "--listen", "ws://127.0.0.1:9223"],
            parentPID: { parents[$0] },
            executablePath: { paths[$0] },
            signatureStatus: { _ in .officialOpenAI }
        ))
        #expect(!CodexDesktopNativeChildCoordinator.authorizesFirstAcknowledgementBootstrap(
            binding: binding,
            arguments: ["codex", "app-server", "--listen", "stdio://"],
            parentPID: { $0 == 42 ? 41 : 1 },
            executablePath: { _ in "/bin/zsh" },
            signatureStatus: { _ in .officialOpenAI }
        ))
    }

    private func nativeBinding(pid: Int32) -> CodexReloadBinding {
        let runtime = "/Users/me/.local/share/codexswitch/prepared-codex/current/codex"
        return CodexReloadBinding(
            processIdentity: CodexSignalProcessIdentity(
                pid: pid,
                ownerUID: UInt32(getuid()),
                executablePath: runtime,
                startSeconds: 1_000,
                startMicroseconds: 1
            ),
            kernelExecutableIdentity: CodexKernelExecutableIdentity(
                canonicalPath: runtime,
                device: 7,
                inode: 9
            ),
            runtimeKind: .officialDesktopStdioChild,
            authFileIdentity: CodexAuthFileIdentity(
                canonicalPath: "/Users/me/.codex/auth.json",
                device: 8,
                inode: 10,
                accountID: "account-1",
                completeTokenFingerprint: String(repeating: "a", count: 64)
            ),
            requestNonce: "nonce",
            issuedAtUnixMilliseconds: 1_000_100
        )
    }
}
