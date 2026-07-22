import Foundation
import Testing
@testable import CodexSwitch

@Suite("Desktop runtime reload client")
struct DesktopRuntimeReloadClientTests {
    private static let successfulStrictSummary = CodexReloadSummary(
        discoveredRuntimeCount: 1,
        acknowledgedRuntimeCount: 1
    )

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

    @Test("desktop connections initialize before account RPCs")
    func initializationRequestUsesCurrentAppServerContract() {
        let request = DesktopRuntimeReloadClient.initializationRequest(id: 0)
        let params = request["params"] as? [String: Any]
        let clientInfo = params?["clientInfo"] as? [String: String]
        let capabilities = params?["capabilities"] as? [String: Bool]

        #expect(request["method"] as? String == "initialize")
        #expect(request["id"] as? Int == 0)
        #expect(clientInfo?["name"] == "codexswitch")
        #expect(clientInfo?["title"] == "CodexSwitch")
        #expect(clientInfo?["version"]?.isEmpty == false)
        #expect(capabilities?["experimentalApi"] == true)
    }

    @Test("initialize accepts current response envelope without jsonrpc member")
    func initializationAcceptsCurrentEnvelope() {
        let result = DesktopRuntimeReloadClient.classifyInitializationResponse(
            .string(#"{"id":0,"result":{"userAgent":"codex-cli"}}"#)
        )

        #expect(result == .success)
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
        let currentEnvelope = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"id":1,"result":{"ok":true}}"#),
            method: "account/login/start"
        )
        let wrongVersion = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"jsonrpc":"1.0","id":1,"result":{"ok":true}}"#),
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
        #expect(currentEnvelope == .failed("desktop account identity not verified"))
        #expect(wrongVersion == .failed("invalid json-rpc response"))
        #expect(missingID == .failed("invalid json-rpc response"))
        #expect(mismatchedID == .failed("json-rpc response id mismatch"))
    }

    @Test("generic login success does not classify as reloaded without identity verification")
    func genericLoginSuccessDoesNotClassifyAsReloaded() {
        let result = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#),
            method: "account/login/start"
        )

        #expect(result == .failed("desktop account identity not verified"))
    }

    @Test("reload succeeds only after exact account identity and strict ACK convergence")
    func reloadRequiresMatchingChatGPTAccount() async throws {
        let (client, sender) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":" USER@EXAMPLE.COM ","planType":" PRO ","chatgptAccountId":"acct_123"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .reloaded(
            method: "account/login/start",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        ))
        let requests = await sender.recordedRequests()
        try #require(requests.count == 2)
        #expect(requestMethod(in: requests[0].payload) == "account/login/start")
        #expect(requestMethod(in: requests[1].payload) == "account/read")
        #expect(requests.allSatisfy { $0.port == 9223 })

        let verificationParams = requestParams(in: requests[1].payload) as? [String: Bool]
        #expect(verificationParams?["refreshToken"] == false)
    }

    @Test("Current desktop ACK is reused without another JSON-RPC notification")
    func currentAcknowledgementSuppressesRepeatedDesktopReload() async {
        let strictReloadCalls = LockedFlag()
        let account = makeAccount()
        let expectedFingerprint = SwapEngine.completeTokenFingerprint(for: account)
        let (client, sender) = makeClient(
            responses: [],
            alreadyAcknowledgedRuntimePIDs: { discovery, accountID, fingerprint, _ in
                #expect(accountID == "acct_123")
                #expect(fingerprint == expectedFingerprint)
                return Set(discovery.targets.map { $0.process.identity.pid })
            },
            strictReload: { _, _, _, _, _ in
                strictReloadCalls.setTrue()
                return Self.successfulStrictSummary
            }
        )

        let result = await client.reloadAuth(account: account)
        let requests = await sender.recordedRequests()

        #expect(result == .reloaded(
            method: DesktopRuntimeReloadClient.existingAcknowledgementMethod,
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        ))
        #expect(requests.isEmpty)
        #expect(!strictReloadCalls.value)
    }

    @Test("Only desktop runtimes without a target-account ACK are notified")
    func partialAcknowledgementReloadsOnlyMissingRuntime() async throws {
        let strictSocketPorts = LockedTestState<[UInt16]>([])
        let (client, sender) = makeClient(
            responses: [
                .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
                .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro","chatgptAccountId":"acct_123"},"requiresOpenaiAuth":true}}"#),
            ],
            runtimePIDs: [42, 43],
            alreadyAcknowledgedRuntimePIDs: { _, _, _, _ in [42] },
            strictReload: { discovery, socketBindings, _, _, _ in
                strictSocketPorts.update { ports in
                    ports = socketBindings.map(\.port)
                }
                return CodexReloadSummary(
                    discoveredRuntimeCount: discovery.targets.count,
                    acknowledgedRuntimeCount: discovery.targets.count
                )
            }
        )

        let result = await client.reloadAuth(account: makeAccount())
        let requests = await sender.recordedRequests()

        #expect(result == .reloaded(
            method: "account/login/start",
            discoveredRuntimeCount: 2,
            acknowledgedRuntimeCount: 2
        ))
        try #require(requests.count == 2)
        #expect(requests.allSatisfy { $0.port == 9_224 })
        #expect(strictSocketPorts.read() == [9_224])
    }

    @Test("A later desktop failure does not reload an already converged runtime")
    func laterFailureRetriesOnlyTheMissingRuntime() async throws {
        let acknowledgedPIDs = LockedTestState<Set<Int32>>([])
        let strictReloadedPIDs = LockedTestState<[Int32]>([])
        let (firstClient, firstSender) = makeClient(
            responses: [
                .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
                .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro","chatgptAccountId":"acct_123"},"requiresOpenaiAuth":true}}"#),
                .string(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"reload refused"}}"#),
            ],
            runtimePIDs: [42, 43],
            alreadyAcknowledgedRuntimePIDs: { _, _, _, _ in
                acknowledgedPIDs.read()
            },
            strictReload: { discovery, _, _, _, _ in
                let pids = discovery.targets.map { $0.process.identity.pid }
                strictReloadedPIDs.update { $0.append(contentsOf: pids) }
                acknowledgedPIDs.update { $0.formUnion(pids) }
                return CodexReloadSummary(
                    discoveredRuntimeCount: pids.count,
                    acknowledgedRuntimeCount: pids.count
                )
            }
        )

        let firstResult = await firstClient.reloadAuth(account: makeAccount())
        let firstRequests = await firstSender.recordedRequests()

        #expect(firstResult == .failed(
            "reload refused",
            discoveredRuntimeCount: 2,
            acknowledgedRuntimeCount: 1
        ))
        #expect(firstRequests.map(\.port) == [9_223, 9_223, 9_224])
        #expect(acknowledgedPIDs.read() == [42])

        let (retryClient, retrySender) = makeClient(
            responses: [
                .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
                .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro","chatgptAccountId":"acct_123"},"requiresOpenaiAuth":true}}"#),
            ],
            runtimePIDs: [42, 43],
            alreadyAcknowledgedRuntimePIDs: { _, _, _, _ in
                acknowledgedPIDs.read()
            },
            strictReload: { discovery, _, _, _, _ in
                let pids = discovery.targets.map { $0.process.identity.pid }
                strictReloadedPIDs.update { $0.append(contentsOf: pids) }
                acknowledgedPIDs.update { $0.formUnion(pids) }
                return CodexReloadSummary(
                    discoveredRuntimeCount: pids.count,
                    acknowledgedRuntimeCount: pids.count
                )
            }
        )

        let retryResult = await retryClient.reloadAuth(account: makeAccount())
        let retryRequests = await retrySender.recordedRequests()

        #expect(retryResult == .reloaded(
            method: "account/login/start",
            discoveredRuntimeCount: 2,
            acknowledgedRuntimeCount: 2
        ))
        #expect(retryRequests.map(\.port) == [9_224, 9_224])
        #expect(strictReloadedPIDs.read() == [42, 43])
    }

    @Test("Expired authorization stops desktop reload before its next effect")
    func authorizationExpiryStopsDesktopReload() async throws {
        let authorized = LockedTestState(true)
        let strictReloadCalls = LockedFlag()
        let (client, sender) = makeClient(
            responses: [
                .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            ],
            requestDidSend: { requestCount in
                if requestCount == 1 {
                    authorized.update { $0 = false }
                }
            },
            strictReload: { _, _, _, _, _ in
                strictReloadCalls.setTrue()
                return Self.successfulStrictSummary
            }
        )

        let result = await client.reloadAuth(
            account: makeAccount(),
            authorizeEffect: { authorized.read() }
        )
        let requests = await sender.recordedRequests()

        #expect(result == .failed(
            "desktop reload authorization expired",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
        try #require(requests.count == 1)
        #expect(requestMethod(in: requests[0].payload) == "account/login/start")
        #expect(!strictReloadCalls.value)
    }

    @Test("Strict reload failure preserves full discovery and per-runtime ACK counts")
    func strictReloadFailurePreservesPartialCounts() async {
        let (client, _) = makeClient(
            responses: [
                .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
                .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro","chatgptAccountId":"acct_123"},"requiresOpenaiAuth":true}}"#),
            ],
            strictReload: { _, _, _, _, _ in
                CodexReloadSummary(
                    discoveredRuntimeCount: 1,
                    acknowledgedRuntimeCount: 0
                )
            }
        )

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "strict desktop reload incomplete acknowledged=0/1",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("reload accepts current app-server responses without jsonrpc member")
    func reloadAcceptsCurrentAppServerEnvelope() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .reloaded(
            method: "account/login/start",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        ))
    }

    @Test("matching account ID verifies when target email is unavailable")
    func reloadUsesMatchingAccountIDWhenTargetEmailIsUnavailable() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"pro","chatgptAccountId":"acct_123"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount(email: ""))

        #expect(result == .reloaded(
            method: "account/login/start",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        ))
    }

    @Test(
        "account IDs with surrounding or embedded whitespace fail before convergence",
        arguments: [" acct_123", "acct_123 ", "acct 123"]
    )
    func reloadRejectsWhitespaceBearingAccountIDs(responseAccountID: String) async {
        let escapedID = responseAccountID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(
                #"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"pro","chatgptAccountId":""#
                    + escapedID
                    + #""},"requiresOpenaiAuth":true}}"#
            )
        ])

        let result = await client.reloadAuth(account: makeAccount(email: ""))

        #expect(result == .failed(
            "desktop account ID is invalid",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("account ID comparison is case sensitive")
    func reloadRejectsCaseChangedAccountID() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"pro","chatgptAccountId":"Acct_123"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount(email: ""))

        #expect(result == .failed(
            "desktop account ID mismatch",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("conflicting account ID aliases are ambiguous")
    func reloadRejectsConflictingAccountIDAliases() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"pro","chatgptAccountId":"acct_123","accountId":"acct_other"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount(email: ""))

        #expect(result == .failed(
            "desktop account identity is ambiguous",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test(
        "invalid target account IDs fail before socket mutation",
        arguments: ["", " acct_123", "acct_123 ", "acct 123"]
    )
    func reloadRejectsInvalidTargetAccountID(accountID: String) async {
        let strictCalls = LockedTestState(0)
        let (client, sender) = makeClient(
            responses: [],
            strictReload: { _, _, _, _, _ in
                strictCalls.update { $0 += 1 }
                return Self.successfulStrictSummary
            }
        )

        let result = await client.reloadAuth(
            account: makeAccount(accountID: accountID)
        )

        #expect(result == .failed("target account ID is invalid"))
        #expect(await sender.recordedRequests().isEmpty)
        #expect(strictCalls.read() == 0)
    }

    @Test("matching plan without email or account ID cannot prove convergence")
    func reloadRejectsPlanOnlyVerification() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"pro"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "desktop account identity missing",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("mismatched account ID fails even when email and plan match")
    func reloadRejectsMismatchedAccountID() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro","accountId":"acct_other"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "desktop account ID mismatch",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("reload rejects a different normalized email")
    func reloadRejectsMismatchedEmail() async {
        let (client, sender) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"other@example.com","planType":"pro"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "desktop account email mismatch",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
    }

    @Test("reload rejects inconsistent meaningful plans")
    func reloadRejectsMismatchedPlan() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"plus"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "desktop account plan mismatch",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("equivalent ChatGPT plan aliases verify as the same tier")
    func reloadAllowsEquivalentPlanAliases() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(
            account: makeAccount(planType: "ChatGPT Pro Monthly")
        )

        #expect(result == .reloaded(
            method: "account/login/start",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        ))
    }

    @Test("unknown target plan does not conflict with a meaningful server plan")
    func reloadAllowsUnknownTargetPlan() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(
            account: makeAccount(planType: "unknown")
        )

        #expect(result == .reloaded(
            method: "account/login/start",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        ))
    }

    @Test("null account verification fails closed")
    func reloadRejectsNullAccount() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "desktop account missing",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("non-ChatGPT account verification fails closed")
    func reloadRejectsWrongAccountType() async {
        let (client, _) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "desktop account is not ChatGPT",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
    }

    @Test("account verification method not found is unsupported")
    func reloadRejectsVerificationMethodNotFound() async {
        let (client, sender) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#)
        ], runtimePIDs: [42, 43, 44])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .unsupported(
            discoveredRuntimeCount: 3,
            acknowledgedRuntimeCount: 0
        ))
        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
    }

    @Test("malformed account verification response is not reloaded")
    func reloadRejectsMalformedVerificationResponse() async {
        let (client, sender) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com"},"requiresOpenaiAuth":true}}"#)
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "invalid account verification response",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
    }

    @Test("account verification timeout is not reloaded")
    func reloadRejectsVerificationTimeout() async {
        let (client, sender) = makeClient(responses: [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .timeout
        ])

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "timeout",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
        let requests = await sender.recordedRequests()
        #expect(requests.count == 2)
    }

    @Test("port ownership drift suppresses every WebSocket send and strict signal phase")
    func portReuseFailsClosedBeforeSend() async {
        let currentnessChecks = LockedTestState(0)
        let socketOwners = LockedTestState<[Int32]>([42, 42, 99])
        let strictCalls = LockedTestState(0)
        let (client, sender) = makeClient(
            responses: [],
            socketBindingIsCurrent: { binding, requiredOwnerUID in
                currentnessChecks.update { checks in
                    checks += 1
                }
                return DesktopRuntimeReloadClient.socketBindingIsCurrent(
                    binding,
                    requiredOwnerUID: requiredOwnerUID,
                    socketOwnerPID: { _ in
                        var owner: Int32?
                        socketOwners.update { remainingOwners in
                            if !remainingOwners.isEmpty {
                                owner = remainingOwners.removeFirst()
                            }
                        }
                        return owner
                    },
                    runtimeTargetIsCurrent: { _, _ in true }
                )
            },
            strictReload: { _, _, _, _, _ in
                strictCalls.update { $0 += 1 }
                return Self.successfulStrictSummary
            }
        )

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "desktop runtime binding drift",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 0
        ))
        #expect(currentnessChecks.read() == 2)
        #expect(socketOwners.read().isEmpty)
        #expect(await sender.recordedRequests().isEmpty)
        #expect(strictCalls.read() == 0)
    }

    @Test("Pre-admission failure preserves all discovered runtime counts")
    func preAdmissionFailurePreservesDiscoveredCounts() async {
        let (client, sender) = makeClient(
            responses: [],
            runtimePIDs: [42, 43, 44],
            missingSocketBindingPIDs: [44]
        )

        let result = await client.reloadAuth(account: makeAccount())

        #expect(result == .failed(
            "desktop runtime socket binding incomplete",
            discoveredRuntimeCount: 3,
            acknowledgedRuntimeCount: 0
        ))
        #expect(await sender.recordedRequests().isEmpty)
    }

    @Test("PID admission covers typed desktop discovery through strict ACK completion")
    func overlappingDesktopReloadsSerializeBeforeTypedDiscovery() async {
        let firstEnteredACKWait = TestSemaphore()
        let releaseFirstACKWait = TestSemaphore()
        let secondContended = TestSemaphore()
        let secondDiscoveryRuns = LockedTestState(0)
        let gate = CodexReloadAttemptGate { _ in secondContended.signal() }
        let responses: [DesktopRuntimeWebSocketEvent] = [
            .string(#"{"jsonrpc":"2.0","id":1,"result":{"type":"chatgptAuthTokens"}}"#),
            .string(#"{"jsonrpc":"2.0","id":2,"result":{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro","chatgptAccountId":"acct_123"},"requiresOpenaiAuth":true}}"#),
        ]
        let (firstClient, _) = makeClient(
            responses: responses,
            gate: gate,
            strictReload: { _, _, _, _, _ in
                firstEnteredACKWait.signal()
                releaseFirstACKWait.wait()
                return Self.successfulStrictSummary
            }
        )
        let (secondClient, secondSender) = makeClient(
            responses: responses,
            gate: gate,
            runtimeDiscoveryDidRun: {
                secondDiscoveryRuns.update { $0 += 1 }
            }
        )
        let account = makeAccount()

        let firstTask = Task {
            await firstClient.reloadAuth(account: account)
        }
        #expect(firstEnteredACKWait.wait(timeout: .now() + 2) == .success)

        let secondTask = Task {
            await secondClient.reloadAuth(account: account)
        }
        #expect(secondContended.wait(timeout: .now() + 2) == .success)
        #expect(secondDiscoveryRuns.read() == 0)
        #expect(await secondSender.recordedRequests().isEmpty)

        releaseFirstACKWait.signal()
        let firstResult = await firstTask.value
        let secondResult = await secondTask.value

        #expect(firstResult == .reloaded(
            method: "account/login/start",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        ))
        #expect(secondResult == .reloaded(
            method: "account/login/start",
            discoveredRuntimeCount: 1,
            acknowledgedRuntimeCount: 1
        ))
        #expect(secondDiscoveryRuns.read() == 1)
        #expect(await secondSender.recordedRequests().count == 2)
    }

    @Test("method-not-found JSON-RPC error classifies as unsupported")
    func methodNotFoundClassifiesAsUnsupported() {
        let result = DesktopRuntimeReloadClient.classifyReloadResponse(
            .string(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#),
            method: "account/login/start"
        )

        #expect(result == .unsupported())
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
        let clock = ContinuousClock()
        let started = clock.now
        let cancellationFlag = LockedFlag()

        do {
            _ = try await DesktopRuntimeReloadClient.runWithTimeout(
                seconds: 0.05,
                cancel: { cancellationFlag.setTrue() },
                operation: {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                            continuation.resume(returning: ())
                        }
                    }
                }
            )
            Issue.record("Expected receive timeout to throw")
        } catch is CancellationError {
            #expect(cancellationFlag.value)
            #expect(started.duration(to: clock.now) < .seconds(1))
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

    private func makeAccount(
        email: String = "user@example.com",
        accountID: String = "acct_123",
        planType: String? = "pro"
    ) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "secret-access-token",
            refreshToken: "secret-refresh-token",
            idToken: "secret-id-token",
            accountId: accountID,
            planType: planType
        )
    }

    private func makeClient(
        responses: [DesktopRuntimeWebSocketEvent],
        runtimePIDs: [Int32] = [42],
        missingSocketBindingPIDs: Set<Int32> = [],
        gate: CodexReloadAttemptGate = CodexReloadAttemptGate(),
        runtimeDiscoveryDidRun: (@Sendable () -> Void)? = nil,
        requestDidSend: (@Sendable (Int) -> Void)? = nil,
        socketBindingIsCurrent: @escaping @Sendable (
            CodexDesktopRuntimeSocketBinding,
            UInt32
        ) -> Bool = { _, _ in true },
        alreadyAcknowledgedRuntimePIDs: @escaping @Sendable (
            CodexRuntimeDiscoverySnapshot,
            String,
            String,
            UInt32
        ) -> Set<Int32> = { _, _, _, _ in [] },
        strictReload: @escaping @Sendable (
            CodexRuntimeDiscoverySnapshot,
            [CodexDesktopRuntimeSocketBinding],
            CodexReloadAdmission,
            UInt32,
            @Sendable () -> Bool
        ) -> CodexReloadSummary = { _, _, _, _, _ in
            DesktopRuntimeReloadClientTests.successfulStrictSummary
        }
    ) -> (DesktopRuntimeReloadClient, StubDesktopRuntimeRequestSender) {
        let targets = runtimePIDs.map { runtimeTarget(pid: $0) }
        let portsByPID = Dictionary(uniqueKeysWithValues: targets.enumerated().map {
            index, target in
            (target.process.identity.pid, UInt16(9_223 + index))
        })
        let sender = StubDesktopRuntimeRequestSender(
            responses: responses,
            requestDidSend: requestDidSend
        )
        let client = DesktopRuntimeReloadClient(
            requestSender: { payload, port in
                await sender.send(payload: payload, port: port)
            },
            dependencies: DesktopRuntimeReloadDependencies(
                requiredOwnerUID: 501,
                gate: gate,
                preliminaryDiscovery: {
                    .snapshot(CodexPGrepProcessSnapshot(
                        pids: targets.map(\.process.identity.pid),
                        isComplete: true
                    ))
                },
                runtimeDiscovery: { _, _ in
                    runtimeDiscoveryDidRun?()
                    return CodexRuntimeDiscoverySnapshot(
                        targets: targets,
                        isComplete: true
                    )
                },
                socketBinding: { target in
                    let pid = target.process.identity.pid
                    guard !missingSocketBindingPIDs.contains(pid),
                          let port = portsByPID[pid] else {
                        return nil
                    }
                    return CodexDesktopRuntimeSocketBinding(target: target, port: port)
                },
                socketBindingIsCurrent: socketBindingIsCurrent,
                alreadyAcknowledgedRuntimePIDs: alreadyAcknowledgedRuntimePIDs,
                strictReload: strictReload
            )
        )
        return (client, sender)
    }

    private func runtimeTarget(pid: Int32 = 42) -> CodexRuntimeTarget {
        let path = "/Users/me/.local/share/codexswitch/prepared-codex/0.144.1/codex"
        let identity = CodexSignalProcessIdentity(
            pid: pid,
            ownerUID: 501,
            executablePath: path,
            startSeconds: 1_000,
            startMicroseconds: 12
        )
        return CodexRuntimeTarget(
            process: CodexIdentityBoundProcess(
                identity: identity,
                kernelExecutableIdentity: CodexKernelExecutableIdentity(
                    canonicalPath: path,
                    device: 7,
                    inode: 10_000 + UInt64(pid)
                ),
                arguments: [path, "app-server", "--analytics-default-enabled"]
            ),
            runtimeKind: .externalAppServer
        )
    }

    private func requestMethod(in payload: String) -> String? {
        requestObject(in: payload)?["method"] as? String
    }

    private func requestParams(in payload: String) -> Any? {
        requestObject(in: payload)?["params"]
    }

    private func requestObject(in payload: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    }
}

private struct CapturedDesktopRuntimeRequest: Sendable {
    let payload: String
    let port: UInt16
}

private actor StubDesktopRuntimeRequestSender {
    private var responses: [DesktopRuntimeWebSocketEvent]
    private var requests: [CapturedDesktopRuntimeRequest] = []
    private let requestDidSend: (@Sendable (Int) -> Void)?

    init(
        responses: [DesktopRuntimeWebSocketEvent],
        requestDidSend: (@Sendable (Int) -> Void)? = nil
    ) {
        self.responses = responses
        self.requestDidSend = requestDidSend
    }

    func send(payload: String, port: UInt16) -> DesktopRuntimeWebSocketEvent {
        requests.append(CapturedDesktopRuntimeRequest(payload: payload, port: port))
        requestDidSend?(requests.count)
        guard !responses.isEmpty else {
            return .failure("unexpected request")
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [CapturedDesktopRuntimeRequest] {
        requests
    }
}

private final class LockedTestState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    func read() -> Value {
        lock.withLock { stored }
    }

    func update(_ operation: (inout Value) -> Void) {
        lock.withLock { operation(&stored) }
    }
}

private final class TestSemaphore: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() {
        semaphore.wait()
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
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
