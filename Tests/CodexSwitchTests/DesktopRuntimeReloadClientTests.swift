import Foundation
import Testing
@testable import CodexSwitch

@Suite("Desktop runtime reload client")
struct DesktopRuntimeReloadClientTests {
    @Test("safe probe methods use read-only order from protocol exploration")
    func safeProbeMethodsUseExpectedOrder() {
        #expect(DesktopRuntimeReloadClient.safeProbeMethods == [
            "getAuthStatus",
            "account/read",
            "account/status",
            "account/get",
            "session/get",
            "auth/status"
        ])
    }

    @Test("probe request avoids token refresh and token inclusion")
    func probeRequestUsesSafeParams() {
        let authStatus = DesktopRuntimeReloadClient.probeRequest(method: "getAuthStatus", id: 1)
        let authStatusParams = authStatus["params"] as? [String: Bool]
        #expect(authStatus["method"] as? String == "getAuthStatus")
        #expect(authStatusParams?["includeToken"] == false)
        #expect(authStatusParams?["refreshToken"] == false)

        let accountRead = DesktopRuntimeReloadClient.probeRequest(method: "account/read", id: 2)
        let accountReadParams = accountRead["params"] as? [String: Bool]
        #expect(accountRead["method"] as? String == "account/read")
        #expect(accountReadParams?["refreshToken"] == false)
    }

    @Test("reload request sends full account login token set")
    func reloadRequestSendsFullAccountLoginTokenSet() {
        let account = CodexAccount(
            email: "user@example.com",
            accessToken: "secret-access-token",
            refreshToken: "secret-refresh-token",
            idToken: "secret-id-token",
            accountId: "acct_123",
            planType: "pro"
        )

        let request = DesktopRuntimeReloadClient.reloadRequest(
            account: account,
            method: "account/login/start",
            id: 1
        )
        let params = request["params"] as? [String: String]

        #expect(request["method"] as? String == "account/login/start")
        #expect(request["id"] as? Int == 1)
        #expect(params?["type"] == "chatgptAuthTokens")
        #expect(params?["accessToken"] == "secret-access-token")
        #expect(params?["refreshToken"] == "secret-refresh-token")
        #expect(params?["idToken"] == "secret-id-token")
        #expect(params?["chatgptAccountId"] == "acct_123")
        #expect(params?["chatgptPlanType"] == "pro")
    }

    @Test("invalid JSON-RPC reload responses do not classify as success")
    func invalidJSONRPCDoesNotClassifyAsSuccess() {
        let plainText = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string("ok"),
            method: "account/login/start"
        )
        let missingResult = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"jsonrpc":"2.0","id":1}"#),
            method: "account/login/start"
        )
        let missingVersion = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"id":1,"result":{"ok":true}}"#),
            method: "account/login/start"
        )
        let missingID = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"jsonrpc":"2.0","result":{"ok":true}}"#),
            method: "account/login/start"
        )
        let mismatchedID = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#),
            method: "account/login/start",
            expectedID: 1
        )

        #expect(plainText == .failed("invalid json-rpc response"))
        #expect(missingResult == .failed("invalid json-rpc response"))
        #expect(missingVersion == .failed("invalid json-rpc response"))
        #expect(missingID == .failed("invalid json-rpc response"))
        #expect(mismatchedID == .failed("json-rpc response id mismatch"))
    }

    @Test("success JSON-RPC reload response classifies as reloaded")
    func successJSONRPCClassifiesAsReloaded() {
        let result = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#),
            method: "account/login/start"
        )

        #expect(result == .reloaded(method: "account/login/start"))
    }

    @Test("method-not-found JSON-RPC error classifies as unsupported")
    func methodNotFoundClassifiesAsUnsupported() {
        let result = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#),
            method: "account/login/start"
        )

        #expect(result == .unsupported)
    }

    @Test("method-not-found probe response advances unsupported probe")
    func methodNotFoundProbeClassifiesAsNoSupportedMethodForThatProbe() {
        let capability = DesktopRuntimeReloadClient.classifyCapabilityResponse(
            .string(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#),
            method: "getAuthStatus"
        )

        #expect(capability == .noSupportedMethod(probedMethods: ["getAuthStatus"]))
    }

    @Test("transport closed response classifies as failed")
    func transportClosedClassifiesAsFailed() {
        let explicit = DesktopRuntimeReloadClient.classifyReloadResponse(
            .transportClosed("server closed connection"),
            method: "account/login/start"
        )
        let urlSessionText = DesktopRuntimeReloadClient.classifyReloadResponse(
            .failure("Socket is not connected"),
            method: "account/login/start"
        )

        #expect(explicit == .failed("transport closed"))
        #expect(urlSessionText == .failed("transport closed"))
    }

    @Test("timeout and cancellation classify distinctly")
    func timeoutAndCancellationClassifyDistinctly() {
        let timeout = DesktopRuntimeReloadClient.classifyReloadResponse(
            .timeout,
            method: "account/login/start"
        )
        let cancelled = DesktopRuntimeReloadClient.classifyReloadResponse(
            .cancelled,
            method: "account/login/start"
        )

        #expect(timeout == .failed("timeout"))
        #expect(cancelled == .failed("cancelled"))
    }


    @Test("receive timeout returns promptly even when operation ignores cancellation")
    func receiveTimeoutReturnsPromptlyForNonCooperativeOperation() async {
        let started = Date()
        let cancellationFlag = LockedFlag()

        do {
            _ = try await DesktopRuntimeReloadClient.runWithTimeout(
                seconds: 0.05,
                cancel: { cancellationFlag.setTrue() },
                operation: {
                    while true {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            )
            Issue.record("Expected receive timeout to throw")
        } catch is CancellationError {
            #expect(cancellationFlag.value)
            #expect(Date().timeIntervalSince(started) < 1)
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test("generic JSON-RPC error is sanitized to message only")
    func genericJSONRPCErrorUsesMessageOnly() {
        let result = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"jsonrpc":"2.0","id":1,"error":{"code":123,"message":"reload refused"}}"#),
            method: "account/login/start"
        )

        #expect(result == .failed("reload refused"))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.withLock { stored }
    }

    func setTrue() {
        lock.withLock { stored = true }
    }
}
