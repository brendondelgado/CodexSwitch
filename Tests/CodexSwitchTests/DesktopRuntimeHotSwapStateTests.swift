import Foundation
import Testing
@testable import CodexSwitch

@Suite("Desktop runtime hot-swap state")
struct DesktopRuntimeHotSwapStateTests {
    private struct ArtifactState: Equatable {
        let device: UInt64
        let inode: UInt64
        let permissions: UInt16
        let size: UInt64
        let modifiedAt: Date
    }

    private func artifactState(at url: URL) throws -> ArtifactState {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ArtifactState(
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modifiedAt: try #require(attributes[.modificationDate] as? Date)
        )
    }

    private func runtimeEvidence(
        pid: Int32 = 42,
        observationKind: HotSwapRuntimeKind = .externalAppServer,
        acknowledgementKind: HotSwapRuntimeKind = .externalAppServer
    ) -> CodexLocalRuntimeEvidence {
        let identity = CodexSignalProcessIdentity(
            pid: pid,
            ownerUID: 501,
            executablePath: "/Users/me/.local/share/codexswitch/prepared-codex/0.144.1/codex",
            startSeconds: 1_000,
            startMicroseconds: 1
        )
        let executable = CodexKernelExecutableIdentity(
            canonicalPath: identity.executablePath,
            device: 7,
            inode: 9_001
        )
        let process = CodexIdentityBoundProcess(
            identity: identity,
            kernelExecutableIdentity: executable,
            arguments: ["codex", "app-server", "--analytics-default-enabled"]
        )
        let auth = CodexAuthFileIdentity(
            canonicalPath: "/Users/me/.codex/auth.json",
            device: 8,
            inode: 12_001,
            accountID: "account-1",
            completeTokenFingerprint: String(repeating: "a", count: 64)
        )
        let observation = CodexRuntimeObservation(
            target: CodexRuntimeTarget(process: process, runtimeKind: observationKind),
            authFileIdentity: auth
        )
        let binding = CodexReloadBinding(
            processIdentity: identity,
            kernelExecutableIdentity: executable,
            runtimeKind: acknowledgementKind,
            authFileIdentity: auth,
            requestNonce: "nonce-\(pid)",
            issuedAtUnixMilliseconds: 1_500_000
        )
        let isCLI = acknowledgementKind == .localInteractiveCLI
        return CodexLocalRuntimeEvidence(
            observation: observation,
            startupAcknowledgement: CodexReloadAcknowledgement(
                binding: binding,
                acknowledgedAtUnixMilliseconds: 1_500_100,
                loadedTokenFingerprint: auth.completeTokenFingerprint,
                activeTokenFingerprint: auth.completeTokenFingerprint,
                frontendNotified: !isCLI,
                frontendWriteCount: isCLI ? 0 : 1,
                authGeneration: isCLI ? 1 : nil,
                reconnectReady: isCLI ? true : nil
            )
        )
    }

    @Test("Goal capability accepts the slash command or the goal RPC pair")
    func goalCapabilitySupportsCurrentRuntimeMarkers() {
        #expect(
            DesktopPatchManager.binaryDataHasGoalSupport(
                Data("Usage: /goal <objective>".utf8)
            )
        )
        #expect(
            DesktopPatchManager.binaryDataHasGoalSupport(
                Data("Pursuing goal thread/goal/set".utf8)
            )
        )
        #expect(
            !DesktopPatchManager.binaryDataHasGoalSupport(
                Data("Pursuing goal".utf8)
            )
        )
    }

    @Test("Desktop readiness consumes only complete typed runtime evidence")
    func typedRuntimeEvidenceControlsReadiness() {
        let ready = CodexLocalRuntimeEvidenceSnapshot(
            runtimes: [runtimeEvidence()],
            isComplete: true
        )
        #expect(DesktopPatchManager.runtimeHotSwapState(from: ready) == .ready)

        let incomplete = CodexLocalRuntimeEvidenceSnapshot(
            runtimes: [runtimeEvidence()],
            isComplete: false
        )
        #expect(DesktopPatchManager.runtimeHotSwapState(from: incomplete) == .unknown)
        #expect(DesktopPatchManager.runtimeHotSwapState(
            from: CodexLocalRuntimeEvidenceSnapshot(runtimes: [], isComplete: true)
        ) == .unknown)

        let wrongKind = CodexLocalRuntimeEvidenceSnapshot(
            runtimes: [runtimeEvidence(observationKind: .localInteractiveCLI)],
            isComplete: true
        )
        #expect(DesktopPatchManager.runtimeHotSwapState(from: wrongKind) == .unknown)
    }

    @Test("Desktop safe-quit blocks unified and legacy bundle-ID hosts")
    func desktopSafeQuitBlocksAllDesktopHosts() {
        #expect(
            DesktopPatchManager.desktopSafeQuitIsBlocked(
                runningHostBundleIdentifiers: ["com.openai.codex"],
                appServerProcessListOutput: ""
            )
        )
        #expect(
            DesktopPatchManager.desktopSafeQuitIsBlocked(
                runningHostBundleIdentifiers: ["com.openai.chat"],
                appServerProcessListOutput: ""
            )
        )
    }

    @Test("Desktop safe-quit blocks every classified account-bearing app-server")
    func desktopSafeQuitBlocksClassifiedAppServers() {
        let processLines = [
            "100 /Applications/ChatGPT.app/Contents/Resources/codex app-server --analytics-default-enabled",
            "101 /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled",
            "102 /Users/me/.local/share/codexswitch/prepared-codex/0.144.1/codex -c features.code_mode_host=true app-server --analytics-default-enabled",
            "103 /Users/me/.local/share/codexswitch/patched-codex/codex app-server --analytics-default-enabled",
            "104 /Users/me/Developer/codex/codex-rs/target/fork-release/codex app-server --analytics-default-enabled",
            "105 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex app-server --analytics-default-enabled",
        ]

        for processLine in processLines {
            #expect(
                DesktopPatchManager.desktopSafeQuitIsBlocked(
                    runningHostBundleIdentifiers: [],
                    appServerProcessListOutput: processLine
                )
            )
        }
    }

    @Test("Desktop safe-quit ignores helper-only leftovers")
    func desktopSafeQuitIgnoresHelperOnlyLeftovers() {
        let output = """
        200 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/browser_crashpad_handler --database=/tmp/Crashpad
        201 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer) --type=renderer
        202 /Users/me/.local/share/codexswitch/prepared-codex/0.144.1/codex-code-mode-host
        203 /Users/me/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
        """

        #expect(
            !DesktopPatchManager.desktopSafeQuitIsBlocked(
                runningHostBundleIdentifiers: [],
                appServerProcessListOutput: output
            )
        )
    }

    @Test("Production desktop readiness is read-only for incomplete and invalid evidence")
    func typedReadinessDoesNotMutateArtifacts() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswitch-readonly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let root = home.appendingPathComponent(".codexswitch", isDirectory: true)
        let ackDirectory = root.appendingPathComponent("hotswap-ack", isDirectory: true)
        let requestDirectory = root.appendingPathComponent("hotswap-request", isDirectory: true)
        try FileManager.default.createDirectory(at: ackDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true)

        let ack = ackDirectory.appendingPathComponent("42.json")
        let request = requestDirectory.appendingPathComponent("42.json")
        let ackBytes = Data("ack-sentinel".utf8)
        let requestBytes = Data("request-sentinel".utf8)
        try ackBytes.write(to: ack)
        try requestBytes.write(to: request)
        let beforePaths = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let rootBefore = try artifactState(at: root)
        let ackDirectoryBefore = try artifactState(at: ackDirectory)
        let requestDirectoryBefore = try artifactState(at: requestDirectory)
        let ackBefore = try artifactState(at: ack)
        let requestBefore = try artifactState(at: request)

        let runtime = runtimeEvidence()
        let binding = runtime.startupAcknowledgement.binding
        let requestArtifact = try JSONEncoder().encode(
            CodexReloadRequestArtifact(binding: binding)
        )
        let acknowledgementArtifact = try JSONEncoder().encode(
            runtime.startupAcknowledgement
        )
        func validatedEvidence(
            requestData: Data,
            requestModifiedAt: Int64,
            acknowledgementModifiedAt: Int64,
            maximumAge: Int64
        ) -> CodexLocalRuntimeEvidenceSnapshot {
            let request = CodexSecureFileSnapshot(
                canonicalPath: "/Users/me/.codexswitch/hotswap-request/42.json",
                device: 9,
                inode: 20_001,
                data: requestData,
                modifiedAtUnixMilliseconds: requestModifiedAt
            )
            let acknowledgement = CodexSecureFileSnapshot(
                canonicalPath: "/Users/me/.codexswitch/hotswap-ack/42.json",
                device: 9,
                inode: 20_002,
                data: acknowledgementArtifact,
                modifiedAtUnixMilliseconds: acknowledgementModifiedAt
            )
            let validated = SwapEngine.validatedReloadAcknowledgement(
                request: request,
                acknowledgement: acknowledgement,
                currentBinding: binding,
                expectedBinding: nil,
                nowUnixMilliseconds: 1_500_200,
                maximumArtifactAgeMilliseconds: maximumAge,
                maximumFutureSkewMilliseconds: 30_000
            )
            return SwapEngine.localRuntimeEvidenceSnapshot(
                discoverySnapshot: CodexRuntimeDiscoverySnapshot(
                    targets: [runtime.observation.target],
                    isComplete: true
                ),
                observationProvider: { _ in runtime.observation },
                startupAcknowledgementProvider: { _ in validated },
                observationIsCurrent: { _ in true }
            )
        }
        let evidenceCases = [
            CodexLocalRuntimeEvidenceSnapshot(runtimes: [], isComplete: false),
            validatedEvidence(
                requestData: Data("{".utf8),
                requestModifiedAt: 1_500_150,
                acknowledgementModifiedAt: 1_500_150,
                maximumAge: 1_000
            ),
            validatedEvidence(
                requestData: requestArtifact,
                requestModifiedAt: 1_500_050,
                acknowledgementModifiedAt: 1_500_150,
                maximumAge: 50
            ),
        ]

        for evidence in evidenceCases {
            let state = DesktopPatchManager.runtimeHotSwapState(
                homeDirectory: home,
                runtimeEvidenceProvider: { runtimeKind, observedHome in
                    #expect(runtimeKind == .externalAppServer)
                    #expect(observedHome == home)
                    return evidence
                }
            )
            #expect(state == .unknown)
        }

        #expect(try Data(contentsOf: ack) == ackBytes)
        #expect(try Data(contentsOf: request) == requestBytes)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() == beforePaths)
        #expect(try artifactState(at: root) == rootBefore)
        #expect(try artifactState(at: ackDirectory) == ackDirectoryBefore)
        #expect(try artifactState(at: requestDirectory) == requestDirectoryBefore)
        #expect(try artifactState(at: ack) == ackBefore)
        #expect(try artifactState(at: request) == requestBefore)
    }

}
