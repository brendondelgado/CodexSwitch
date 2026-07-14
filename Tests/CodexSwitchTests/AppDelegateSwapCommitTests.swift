import Foundation
import Testing
@testable import CodexSwitch

private final class ReloadCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Account activation reload transaction")
struct AppDelegateSwapCommitTests {
    @Test("No live runtime remains configured-only")
    func noRuntimeIsConfiguredOnly() {
        let completion = AccountActivationConvergenceEvaluator.completion(
            cliReload: CodexReloadSummary(
                discoveredRuntimeCount: 0,
                acknowledgedRuntimeCount: 0
            ),
            desktopReload: .noDesktopRuntime
        )

        #expect(completion.outcome == .configuredOnly)
        #expect(completion.discoveredRuntimeCount == 0)
        #expect(completion.acknowledgedRuntimeCount == 0)
    }

    @Test("Every admitted runtime must acknowledge before runtime-current")
    func allAdmittedRuntimesConverge() {
        let completion = AccountActivationConvergenceEvaluator.completion(
            cliReload: CodexReloadSummary(
                discoveredRuntimeCount: 2,
                acknowledgedRuntimeCount: 2
            ),
            desktopReload: .reloaded(method: "account/login/start")
        )

        #expect(completion.outcome == .runtimeCurrent)
        #expect(completion.discoveredRuntimeCount == 3)
        #expect(completion.acknowledgedRuntimeCount == 3)
        #expect(completion.detail == nil)
    }

    @Test("Partial CLI acknowledgement is degraded")
    func partialCLIConvergenceRequiresRestart() {
        let completion = AccountActivationConvergenceEvaluator.completion(
            cliReload: CodexReloadSummary(
                discoveredRuntimeCount: 2,
                acknowledgedRuntimeCount: 1
            ),
            desktopReload: .reloaded(method: "account/login/start")
        )

        #expect(completion.outcome == .restartRequired)
        #expect(completion.discoveredRuntimeCount == 3)
        #expect(completion.acknowledgedRuntimeCount == 2)
        #expect(completion.detail?.contains("cli_acknowledged_1_of_2") == true)
    }

    @Test("Failed desktop transaction cannot fall through to a later signal")
    func failedDesktopStopsBeforeCLIReload() async {
        let cliCalls = ReloadCallCounter()
        let transaction = AccountActivationReloadTransaction(
            desktopReload: { _ in .failed("strict_ack_timeout") },
            cliReload: {
                cliCalls.increment()
                return CodexReloadSummary(
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 1
                )
            }
        )

        let result = await transaction.converge(
            account: makeAccount(),
            authorizeAfterDesktop: { true }
        )

        #expect(cliCalls.read() == 0)
        guard case .completed(let desktop, let completion) = result else {
            Issue.record("Expected a degraded completion")
            return
        }
        #expect(desktop == .failed("strict_ack_timeout"))
        #expect(completion.outcome == .restartRequired)
        #expect(completion.discoveredRuntimeCount == 1)
        #expect(completion.acknowledgedRuntimeCount == 0)
    }

    @Test("Unsupported desktop transaction cannot be rescued by CLI signalling")
    func unsupportedDesktopStopsBeforeCLIReload() async {
        let cliCalls = ReloadCallCounter()
        let transaction = AccountActivationReloadTransaction(
            desktopReload: { _ in .unsupported },
            cliReload: {
                cliCalls.increment()
                return CodexReloadSummary(
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 1
                )
            }
        )

        let result = await transaction.converge(
            account: makeAccount(),
            authorizeAfterDesktop: { true }
        )

        #expect(cliCalls.read() == 0)
        guard case .completed(_, let completion) = result else {
            Issue.record("Expected a degraded completion")
            return
        }
        #expect(completion.outcome == .restartRequired)
        #expect(completion.detail?.contains("desktop_json_rpc_unsupported") == true)
    }

    @Test("Ownership loss after desktop await prevents the CLI effect")
    func postDesktopAuthorizationLossStopsBeforeCLIReload() async {
        let cliCalls = ReloadCallCounter()
        let transaction = AccountActivationReloadTransaction(
            desktopReload: { _ in .reloaded(method: "account/login/start") },
            cliReload: {
                cliCalls.increment()
                return CodexReloadSummary(
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 1
                )
            }
        )

        let result = await transaction.converge(
            account: makeAccount(),
            authorizeAfterDesktop: { false }
        )

        #expect(cliCalls.read() == 0)
        guard case .cancelledAfterDesktop(.reloaded) = result else {
            Issue.record("Expected cancellation after the desktop await")
            return
        }
    }

    @Test("Auth readback verifies the complete token set")
    func authReadbackVerifiesCompleteTokenSet() throws {
        let account = makeAccount()
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-app-delegate-auth",
            fileName: "auth.json"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try SwapEngine.writeAuthFile(for: account, path: url.path)
        #expect(AppDelegate.authFileMatches(account: account, atPath: url.path))

        var mismatch = account
        mismatch.refreshToken = "different-refresh-token"
        #expect(!AppDelegate.authFileMatches(account: mismatch, atPath: url.path))
    }

    private func makeAccount() -> CodexAccount {
        CodexAccount(
            email: "swap-contract@example.com",
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: "account-id"
        )
    }
}
