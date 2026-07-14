import Testing
@testable import CodexSwitch

@Suite("CLI status checker")
struct CLIStatusCheckerTests {
    private func runtimeEvidence(
        pid: Int32 = 42,
        observationRuntimeKind: HotSwapRuntimeKind = .localInteractiveCLI,
        acknowledgementRuntimeKind: HotSwapRuntimeKind = .localInteractiveCLI,
        accountID: String = "account-1"
    ) -> CodexLocalRuntimeEvidence {
        let identity = CodexSignalProcessIdentity(
            pid: pid,
            ownerUID: 501,
            executablePath: "/Users/me/.local/share/codexswitch/prepared-codex/codex",
            startSeconds: 1_000,
            startMicroseconds: 1
        )
        let process = CodexIdentityBoundProcess(
            identity: identity,
            kernelExecutableIdentity: CodexKernelExecutableIdentity(
                canonicalPath: identity.executablePath,
                device: 7,
                inode: 9_042
            ),
            arguments: ["codex", "resume", "thread-42"]
        )
        let auth = CodexAuthFileIdentity(
            canonicalPath: "/Users/me/.codex/auth.json",
            device: 8,
            inode: 12_001,
            accountID: accountID,
            completeTokenFingerprint: String(repeating: "a", count: 64)
        )
        let observation = CodexRuntimeObservation(
            target: CodexRuntimeTarget(
                process: process,
                runtimeKind: observationRuntimeKind
            ),
            authFileIdentity: auth
        )
        let binding = CodexReloadBinding(
            processIdentity: identity,
            kernelExecutableIdentity: process.kernelExecutableIdentity,
            runtimeKind: acknowledgementRuntimeKind,
            authFileIdentity: auth,
            requestNonce: "nonce-42",
            issuedAtUnixMilliseconds: 1_500_000
        )
        let isCLI = acknowledgementRuntimeKind == .localInteractiveCLI
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

    @Test("Account-swap invalidation prevents an older refresh from publishing")
    func accountSwapInvalidationRejectsStaleRefreshGeneration() throws {
        var gate = CLIStatusRefreshGeneration()
        let accountARefreshCandidate = gate.begin()
        let accountARefresh = try #require(accountARefreshCandidate)

        gate.invalidate()
        let accountBRefreshCandidate = gate.begin()
        let accountBRefresh = try #require(accountBRefreshCandidate)

        let staleRefreshCompleted = gate.complete(accountARefresh)
        #expect(!staleRefreshCompleted)
        #expect(gate.inFlightGeneration == accountBRefresh)
        let currentRefreshCompleted = gate.complete(accountBRefresh)
        #expect(currentRefreshCompleted)
        #expect(gate.inFlightGeneration == nil)
    }

    @Test("CLI status copy distinguishes local Mac sessions from VPS remote sessions")
    func cliStatusCopyDistinguishesLocalMacSessionsFromVPSRemoteSessions() {
        #expect(CLIStatus.cliNotRunning.label == "Mac CLI — No local session detected")
        #expect(CLIStatus.hotSwapMissing.label == "Mac CLI — Connected: restart local CLI to activate hot-swap")
    }

    @Test("CLI process detection ignores desktop app-server and helpers")
    func cliProcessDetectionIgnoresDesktopProcesses() {
        let output = """
        30351 /Applications/Codex.app/Contents/MacOS/Codex
        30437 /Applications/Codex.app/Contents/Frameworks/Codex Helper (Renderer).app/Contents/MacOS/Codex Helper (Renderer) --type=renderer
        58182 /Applications/Codex.app/Contents/Resources/codex app-server --analytics-default-enabled
        65703 /Applications/CodexSwitch.app/Contents/MacOS/CodexSwitch
        """

        for commandLine in output.components(separatedBy: "\n") where !commandLine.isEmpty {
            #expect(!CLIStatusChecker.isCodexCLICommandLine(commandLine))
        }
    }

    @Test("CLI process detection ignores desktop code-mode helpers")
    func cliProcessDetectionIgnoresDesktopCodeModeHelpers() {
        let output = """
        19401 /Users/brendondelgado/.local/share/codexswitch/prepared-codex/0.144.1/codex-code-mode-host
        """

        #expect(!CLIStatusChecker.isCodexCLICommandLine(output))
    }

    @Test("CLI process detection ignores launcher parents and keeps native sessions")
    func cliProcessDetectionKeepsNativeSessions() {
        let accepted = [
            "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex",
            "/Users/me/.local/share/codexswitch/remote-client/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex resume --yolo",
            "/Users/me/.local/share/codexswitch/patched-codex/codex resume --yolo",
            "/Users/me/.local/share/codexswitch/prepared-codex/0.128.0/codex resume --yolo",
            "/Users/me/Developer/codex/codex-rs/target/fork-release/codex resume thread --yolo",
        ]
        let rejected = [
            "/Users/me/.local/bin/headroom wrap codex",
            "node /opt/homebrew/bin/codex",
            "/Users/me/Developer/codex/codex-rs/target/fork-release/codex --remote ws://127.0.0.1:18390 resume thread",
            "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex exec --ephemeral review",
            "/Users/me/.git-ai/bin/git-ai checkpoint codex --hook-input stdin",
        ]

        #expect(accepted.allSatisfy(CLIStatusChecker.isCodexCLICommandLine))
        #expect(!rejected.contains(where: CLIStatusChecker.isCodexCLICommandLine))
    }

    @Test("CLI readiness requires a complete typed runtime evidence snapshot")
    func cliReadinessRequiresCompleteTypedEvidence() {
        let evidence = runtimeEvidence()
        let incomplete = CodexLocalRuntimeEvidenceSnapshot(
            runtimes: [evidence],
            isComplete: false
        )
        #expect(!CLIStatusChecker.codexCLIRuntimeEvidenceIsHotSwapReady(incomplete).ready)
        #expect(incomplete.runtimes.isEmpty)

        let ready = CLIStatusChecker.codexCLIRuntimeEvidenceIsHotSwapReady(
            CodexLocalRuntimeEvidenceSnapshot(runtimes: [evidence], isComplete: true)
        )
        #expect(ready.ready)
    }

    @Test("CLI readiness reports the blocking process")
    func cliReadinessReportsBlockingProcess() {
        let readiness = CLIStatusChecker.codexCLIRuntimeEvidenceIsHotSwapReady(
            CodexLocalRuntimeEvidenceSnapshot(
                runtimes: [runtimeEvidence(acknowledgementRuntimeKind: .externalAppServer)],
                isComplete: true
            ),
            detailProvider: { pid, _ in
                "pid=\(pid) incompleteEvidence=true"
            }
        )

        #expect(readiness.ready == false)
        #expect(readiness.detail == "pid=42 incompleteEvidence=true")
    }

    @Test("CLI status evaluates injected observational evidence without bootstrapping")
    func cliStatusUsesOnlyInjectedRuntimeEvidence() {
        let readySnapshot = CodexLocalRuntimeEvidenceSnapshot(
            runtimes: [runtimeEvidence(accountID: "account-1")],
            isComplete: true
        )
        var evidenceReads = 0

        let noAccount = CLIStatusChecker.cliCheckResult(activeAccountId: nil) {
            evidenceReads += 1
            return readySnapshot
        }
        #expect(noAccount == CLICheckResult(status: .noActiveAccount, detail: nil))
        #expect(evidenceReads == 0)

        let ready = CLIStatusChecker.cliCheckResult(activeAccountId: "account-1") {
            evidenceReads += 1
            return readySnapshot
        }
        #expect(ready == CLICheckResult(status: .ready, detail: nil))
        #expect(evidenceReads == 1)

        let mismatch = CLIStatusChecker.cliCheckResult(activeAccountId: "account-2") {
            evidenceReads += 1
            return readySnapshot
        }
        #expect(mismatch == CLICheckResult(status: .authMismatch, detail: nil))
        #expect(evidenceReads == 2)

        let inconsistent = CodexLocalRuntimeEvidenceSnapshot(
            runtimes: [
                runtimeEvidence(pid: 42, accountID: "account-1"),
                runtimeEvidence(pid: 43, accountID: "account-2"),
            ],
            isComplete: true
        )
        let inconsistentResult = CLIStatusChecker.cliCheckResult(activeAccountId: "account-1") {
            inconsistent
        }

        #expect(inconsistentResult.status == .hotSwapMissing)
    }

    @Test("Desktop status reports connected patched app as ready")
    func desktopStatusReportsConnectedPatchedAppAsReady() {
        let status = DesktopAppStatus(
            isRunning: true,
            port: 49_999,
            hotSwapReady: true,
            patchInstalled: true,
            patchMessage: "Desktop app is ready."
        )

        #expect(status.label == "Codex desktop app connected (port 49999): Auto-swap ready")
        #expect(status.isHealthy)
    }
}
