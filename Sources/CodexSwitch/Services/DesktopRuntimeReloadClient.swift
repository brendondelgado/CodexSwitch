import Foundation
import os

private let desktopReloadLogger = Logger(subsystem: "com.codexswitch", category: "DesktopRuntimeReload")

enum DesktopReloadCapability: Sendable, Equatable {
    case available(method: String)
    case appServerUnavailable
    case noSupportedMethod(probedMethods: [String])
    case failed(String)
}

enum DesktopReloadResult: Sendable, Equatable {
    case reloaded(method: String)
    case noDesktopRuntime
    case unsupported
    case failed(String)
}

struct CodexDesktopRuntimeSocketBinding: Sendable, Equatable {
    let target: CodexRuntimeTarget
    let port: UInt16
}

struct DesktopRuntimeReloadDependencies: Sendable {
    let requiredOwnerUID: UInt32
    let gate: CodexReloadAttemptGate
    let preliminaryDiscovery: @Sendable () -> CodexPGrepDiscoveryResult
    let runtimeDiscovery: @Sendable (
        CodexPGrepDiscoveryResult,
        UInt32
    ) -> CodexRuntimeDiscoverySnapshot
    let socketBinding: @Sendable (
        CodexRuntimeTarget
    ) -> CodexDesktopRuntimeSocketBinding?
    let socketBindingIsCurrent: @Sendable (
        CodexDesktopRuntimeSocketBinding,
        UInt32
    ) -> Bool
    let strictReload: @Sendable (
        CodexRuntimeDiscoverySnapshot,
        CodexReloadAdmission,
        UInt32
    ) -> CodexReloadSummary
}

private struct AdmittedDesktopRuntime: Sendable {
    let discovery: CodexRuntimeDiscoverySnapshot
    let socketBindings: [CodexDesktopRuntimeSocketBinding]
    let admission: CodexReloadAdmission
    let requiredOwnerUID: UInt32
}

private enum AdmittedDesktopRuntimeResult: Sendable {
    case found(AdmittedDesktopRuntime)
    case noRuntime
    case failed(String)
}

private enum DesktopRuntimeSocketError: Error {
    case bindingDrift
}

struct DesktopRuntimeReloadClient: Sendable {
    private let timeoutSeconds: TimeInterval
    private let requestSender: (@Sendable (String, UInt16) async -> DesktopRuntimeWebSocketEvent)?
    private let dependencies: DesktopRuntimeReloadDependencies

    nonisolated static let safeProbeMethods = [
        "getAuthStatus",
        "account/read",
        "account/status",
        "account/get",
        "session/get",
        "auth/status"
    ]

    nonisolated static let reloadMethods = ["account/login/start"]
    nonisolated static let verificationMethod = "account/read"

    init(
        timeoutSeconds: TimeInterval = 5,
        requestSender: (@Sendable (String, UInt16) async -> DesktopRuntimeWebSocketEvent)? = nil,
        dependencies: DesktopRuntimeReloadDependencies? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.requestSender = requestSender
        self.dependencies = dependencies ?? Self.liveDependencies()
    }

    func probeCapability() async -> DesktopReloadCapability {
        let context: AdmittedDesktopRuntime
        switch discoverAdmittedRuntime() {
        case .found(let admitted):
            context = admitted
        case .noRuntime:
            return .appServerUnavailable
        case .failed(let reason):
            return .failed(reason)
        }
        defer { context.admission.release() }
        guard let socketBinding = context.socketBindings.first else {
            return .appServerUnavailable
        }

        var probedMethods: [String] = []
        for method in Self.safeProbeMethods {
            probedMethods.append(method)
            desktopReloadLogger.info("DESKTOP_RELOAD_PROBE method=\(method, privacy: .public)")

            let request = Self.probeRequest(method: method, id: probedMethods.count)
            let event = await sendJSONRPCRequest(
                request,
                socketBinding: socketBinding,
                requiredOwnerUID: context.requiredOwnerUID
            )
            switch Self.classifyCapabilityResponse(
                event,
                method: method,
                expectedID: probedMethods.count
            ) {
            case .available(let method):
                desktopReloadLogger.info("DESKTOP_RELOAD_PROBE method=\(method, privacy: .public) result=available")
                return .available(method: method)
            case .noSupportedMethod:
                desktopReloadLogger.info("DESKTOP_RELOAD_PROBE method=\(method, privacy: .public) result=method_not_found")
                continue
            case .appServerUnavailable:
                return .appServerUnavailable
            case .failed(let reason):
                desktopReloadLogger.warning("DESKTOP_RELOAD_PROBE method=\(method, privacy: .public) result=failed reason=\(reason, privacy: .public)")
                return .failed(reason)
            }
        }

        return .noSupportedMethod(probedMethods: probedMethods)
    }

    func reloadAuth(account: CodexAccount) async -> DesktopReloadResult {
        guard Self.canonicalAccountIDBytes(account.accountId) != nil else {
            return .failed("target account ID is invalid")
        }

        let context: AdmittedDesktopRuntime
        switch discoverAdmittedRuntime() {
        case .found(let admitted):
            context = admitted
        case .noRuntime:
            return .noDesktopRuntime
        case .failed(let reason):
            return .failed(reason)
        }
        defer { context.admission.release() }

        let method = Self.reloadMethods[0]
        var jsonRPCResult: DesktopReloadResult = .reloaded(method: method)
        for socketBinding in context.socketBindings {
            let request = Self.reloadRequest(account: account, method: method, id: 1)
            let event = await sendJSONRPCRequest(
                request,
                socketBinding: socketBinding,
                requiredOwnerUID: context.requiredOwnerUID
            )
            let loginClassification = Self.classifyRPCEvent(event, expectedID: 1)
            if let failure = Self.reloadFailure(from: loginClassification) {
                jsonRPCResult = failure
                break
            }

            let verificationMethod = Self.verificationMethod
            desktopReloadLogger.info("DESKTOP_RELOAD_VERIFY method=\(verificationMethod, privacy: .public)")
            let verificationRequest = Self.probeRequest(method: verificationMethod, id: 2)
            let verificationEvent = await sendJSONRPCRequest(
                verificationRequest,
                socketBinding: socketBinding,
                requiredOwnerUID: context.requiredOwnerUID
            )
            let verification = Self.classifyVerificationResponse(
                verificationEvent,
                targetEmail: account.email,
                targetAccountID: account.accountId,
                targetPlanType: account.planType,
                reloadMethod: method,
                expectedID: 2
            )
            guard case .reloaded = verification else {
                jsonRPCResult = verification
                break
            }
        }

        guard case .reloaded = jsonRPCResult else {
            return jsonRPCResult
        }

        let strictSummary = dependencies.strictReload(
            context.discovery,
            context.admission,
            context.requiredOwnerUID
        )
        guard strictSummary.outcome == .allDiscoveredRuntimesAcknowledged else {
            return .failed(
                "strict desktop reload incomplete acknowledged="
                    + "\(strictSummary.acknowledgedRuntimeCount)/"
                    + "\(strictSummary.discoveredRuntimeCount)"
            )
        }
        return jsonRPCResult
    }

    nonisolated static func probeRequest(method: String, id: Int) -> [String: Any] {
        var request: [String: Any] = [
            "method": method,
            "id": id
        ]

        switch method {
        case "getAuthStatus":
            request["params"] = [
                "includeToken": false,
                "refreshToken": false
            ]
        case "account/read":
            request["params"] = [
                "refreshToken": false
            ]
        default:
            request["params"] = [:]
        }

        return request
    }

    nonisolated static func reloadRequest(account: CodexAccount, method: String, id: Int) -> [String: Any] {
        var params: [String: Any] = [
            "type": "chatgptAuthTokens",
            "accessToken": account.accessToken,
            "chatgptAccountId": account.accountId
        ]
        if !account.refreshToken.isEmpty {
            params["refreshToken"] = account.refreshToken
        }
        if !account.idToken.isEmpty {
            params["idToken"] = account.idToken
        }
        if let planType = account.planType {
            params["chatgptPlanType"] = planType
        }

        return [
            "method": method,
            "id": id,
            "params": params
        ]
    }

    nonisolated static func classifyReloadResponse(
        _ event: DesktopRuntimeWebSocketEvent,
        method _: String,
        expectedID: Int? = nil
    ) -> DesktopReloadResult {
        let classification = classifyRPCEvent(event, expectedID: expectedID)
        if let failure = reloadFailure(from: classification) {
            return failure
        }
        return .failed("desktop account identity not verified")
    }

    nonisolated static func classifyVerificationResponse(
        _ event: DesktopRuntimeWebSocketEvent,
        targetEmail: String,
        targetAccountID: String,
        targetPlanType: String?,
        reloadMethod: String,
        expectedID: Int? = nil
    ) -> DesktopReloadResult {
        let classification = classifyRPCEvent(event, expectedID: expectedID)
        if let failure = reloadFailure(from: classification) {
            return failure
        }

        switch accountReadAccount(from: event) {
        case .found(let account):
            guard account.type == "chatgpt" else {
                return .failed("desktop account is not ChatGPT")
            }

            let targetEmail = normalizedEmail(targetEmail)
            guard let targetAccountID = canonicalAccountIDBytes(targetAccountID) else {
                return .failed("target account ID is invalid")
            }
            let responseEmail = normalizedEmail(account.email)
            var responseAccountIDs: Set<Data> = []
            for responseAccountID in account.accountIDs {
                guard let canonical = canonicalAccountIDBytes(responseAccountID) else {
                    return .failed("desktop account ID is invalid")
                }
                responseAccountIDs.insert(canonical)
            }
            guard responseAccountIDs.count <= 1 else {
                return .failed("desktop account identity is ambiguous")
            }

            var matchedIdentity = false
            if let responseAccountID = responseAccountIDs.first {
                guard targetAccountID == responseAccountID else {
                    return .failed("desktop account ID mismatch")
                }
                matchedIdentity = true
            }
            if let targetEmail, let responseEmail {
                guard targetEmail == responseEmail else {
                    return .failed("desktop account email mismatch")
                }
                matchedIdentity = true
            }
            guard matchedIdentity else {
                return .failed("desktop account identity missing")
            }

            if let targetPlan = normalizedMeaningfulPlan(targetPlanType),
               let responsePlan = normalizedMeaningfulPlan(account.planType),
               targetPlan != responsePlan {
                return .failed("desktop account plan mismatch")
            }

            return .reloaded(method: reloadMethod)
        case .missing:
            return .failed("desktop account missing")
        case .malformed:
            return .failed("invalid account verification response")
        }
    }

    private nonisolated static func reloadFailure(
        from classification: DesktopRuntimeRPCClassification
    ) -> DesktopReloadResult? {
        switch classification {
        case .success:
            return nil
        case .methodNotFound:
            return .unsupported
        case .transportClosed:
            return .failed("transport closed")
        case .timeout:
            return .failed("timeout")
        case .cancelled:
            return .failed("cancelled")
        case .failed(let reason):
            return .failed(reason)
        }
    }

    nonisolated static func classifyCapabilityResponse(
        _ event: DesktopRuntimeWebSocketEvent,
        method: String,
        expectedID: Int? = nil
    ) -> DesktopReloadCapability {
        switch classifyRPCEvent(event, expectedID: expectedID) {
        case .success:
            return .available(method: method)
        case .methodNotFound:
            return .noSupportedMethod(probedMethods: [method])
        case .transportClosed:
            return .failed("transport closed")
        case .timeout:
            return .failed("timeout")
        case .cancelled:
            return .failed("cancelled")
        case .failed(let reason):
            return .failed(reason)
        }
    }

    nonisolated static func classifyRPCEvent(
        _ event: DesktopRuntimeWebSocketEvent,
        expectedID: Int? = nil
    ) -> DesktopRuntimeRPCClassification {
        switch event {
        case .string(let text):
            return classifyJSONRPCPayload(Data(text.utf8), fallbackText: text, expectedID: expectedID)
        case .data(let data):
            return classifyJSONRPCPayload(data, fallbackText: nil, expectedID: expectedID)
        case .transportClosed:
            return .transportClosed
        case .failure(let reason):
            let lower = reason.lowercased()
            if lower.contains("cancel") {
                return .cancelled
            }
            if lower.contains("timed out") || lower.contains("timeout") {
                return .timeout
            }
            if lower.contains("closed") || lower.contains("socket is not connected") {
                return .transportClosed
            }
            return .failed(reason)
        case .timeout:
            return .timeout
        case .cancelled:
            return .cancelled
        }
    }

    private nonisolated static func classifyJSONRPCPayload(
        _ data: Data,
        fallbackText: String?,
        expectedID: Int?
    ) -> DesktopRuntimeRPCClassification {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let fallbackText, fallbackText.lowercased().contains("method not found") {
                return .methodNotFound
            }
            return .failed("invalid json-rpc response")
        }

        guard object["jsonrpc"] as? String == "2.0",
              let responseID = object["id"] as? Int else {
            return .failed("invalid json-rpc response")
        }
        if let expectedID, responseID != expectedID {
            return .failed("json-rpc response id mismatch")
        }

        guard let error = object["error"] else {
            return object.keys.contains("result") ? .success : .failed("invalid json-rpc response")
        }

        if let errorObject = error as? [String: Any] {
            if let code = errorObject["code"] as? Int, code == -32601 {
                return .methodNotFound
            }
            if let message = errorObject["message"] as? String,
               message.lowercased().contains("method not found") {
                return .methodNotFound
            }
            return .failed(sanitizedErrorMessage(from: errorObject))
        }

        if let errorText = error as? String {
            if errorText.lowercased().contains("method not found") {
                return .methodNotFound
            }
            return .failed(redactedErrorText(errorText))
        }

        return .failed("json-rpc error")
    }

    private nonisolated static func sanitizedErrorMessage(from errorObject: [String: Any]) -> String {
        if let message = errorObject["message"] as? String, !message.isEmpty {
            return redactedErrorText(message)
        }
        if let code = errorObject["code"] as? Int {
            return "json-rpc error \(code)"
        }
        return "json-rpc error"
    }

    private nonisolated static func accountReadAccount(
        from event: DesktopRuntimeWebSocketEvent
    ) -> AccountReadExtraction {
        let data: Data
        switch event {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let responseData):
            data = responseData
        default:
            return .malformed
        }

        guard let response = try? JSONDecoder().decode(AccountReadRPCResponse.self, from: data) else {
            return .malformed
        }
        guard let account = response.result.account else {
            return .missing
        }
        return .found(account)
    }

    private nonisolated static func normalizedEmail(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private nonisolated static func canonicalAccountIDBytes(
        _ accountID: String?
    ) -> Data? {
        SwapEngine.accountIDBytesIfCanonical(accountID)
    }

    private nonisolated static func normalizedMeaningfulPlan(_ planType: String?) -> String? {
        guard let planType else { return nil }
        var normalized = planType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard !normalized.isEmpty, normalized != "unknown" else {
            return nil
        }
        if normalized.hasPrefix("chatgpt_") {
            normalized.removeFirst("chatgpt_".count)
        }
        if normalized == "prolite" {
            return "pro_lite"
        }
        for billingSuffix in ["_monthly", "_annual", "_yearly"]
            where normalized.hasSuffix(billingSuffix) {
            normalized.removeLast(billingSuffix.count)
            break
        }
        return normalized
    }

    private static func liveDependencies() -> DesktopRuntimeReloadDependencies {
        DesktopRuntimeReloadDependencies(
            requiredOwnerUID: UInt32(getuid()),
            gate: SwapEngine.reloadAttemptGate,
            preliminaryDiscovery: {
                let result = ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
                    arguments: ["-fl", "codex.*app-server"],
                    timeout: 3
                )
                return SwapEngine.pgrepDiscoveryResult(
                    stdout: result.stdout,
                    terminationStatus: result.terminationStatus,
                    timedOut: result.timedOut
                )
            },
            runtimeDiscovery: { discoveryResult, requiredOwnerUID in
                SwapEngine.runtimeDiscoverySnapshot(
                    from: discoveryResult,
                    runtimeKind: .externalAppServer,
                    requiredOwnerUID: requiredOwnerUID
                )
            },
            socketBinding: { target in
                liveSocketBinding(for: target)
            },
            socketBindingIsCurrent: { binding, requiredOwnerUID in
                liveSocketBindingIsCurrent(
                    binding,
                    requiredOwnerUID: requiredOwnerUID
                )
            },
            strictReload: { discovery, admission, requiredOwnerUID in
                SwapEngine.signalDesktopAppServerReloadSummary(
                    admittedDiscoverySnapshot: discovery,
                    admission: admission,
                    requiredOwnerUID: requiredOwnerUID
                )
            }
        )
    }

    private func discoverAdmittedRuntime() -> AdmittedDesktopRuntimeResult {
        let discoveryResult = dependencies.preliminaryDiscovery()
        switch discoveryResult {
        case .noMatches:
            return .noRuntime
        case .failed(let reason):
            return .failed("desktop runtime discovery failed: \(reason)")
        case .snapshot:
            break
        }

        let preliminaryPIDs = SwapEngine.preliminaryReloadPIDs(from: discoveryResult)
        guard !preliminaryPIDs.isEmpty,
              preliminaryPIDs.allSatisfy({ $0 > 0 }) else {
            return .failed("desktop runtime discovery produced no admissible PID")
        }

        let admission = dependencies.gate.acquireAdmission(preliminaryPIDs)
        let discovery = dependencies.runtimeDiscovery(
            discoveryResult,
            dependencies.requiredOwnerUID
        )
        let targetPIDs = Set(discovery.targets.map { $0.process.identity.pid })
        guard discovery.isComplete,
              !discovery.targets.isEmpty,
              targetPIDs.count == discovery.targets.count,
              targetPIDs.isSubset(of: preliminaryPIDs),
              discovery.targets.allSatisfy({ target in
                  target.runtimeKind == .externalAppServer
                      && target.process.identity.ownerUID == dependencies.requiredOwnerUID
              }) else {
            admission.release()
            return discovery.isComplete && discovery.targets.isEmpty
                ? .noRuntime
                : .failed("desktop runtime identity discovery incomplete")
        }

        let bindings = discovery.targets.compactMap(dependencies.socketBinding)
        let bindingPIDs = Set(bindings.map { $0.target.process.identity.pid })
        let bindingPorts = Set(bindings.map(\.port))
        guard bindings.count == discovery.targets.count,
              bindingPIDs == targetPIDs,
              bindingPorts.count == bindings.count,
              bindings.allSatisfy({ binding in
                  binding.port > 0
                      && discovery.targets.contains(binding.target)
                      && dependencies.socketBindingIsCurrent(
                          binding,
                          dependencies.requiredOwnerUID
                      )
              }) else {
            admission.release()
            return .failed("desktop runtime socket binding incomplete")
        }

        return .found(AdmittedDesktopRuntime(
            discovery: discovery,
            socketBindings: bindings,
            admission: admission,
            requiredOwnerUID: dependencies.requiredOwnerUID
        ))
    }

    private nonisolated static func liveSocketBinding(
        for target: CodexRuntimeTarget
    ) -> CodexDesktopRuntimeSocketBinding? {
        let ports = liveListeningPorts().filter {
            $0.pid == target.process.identity.pid
        }
        guard ports.count == 1, let port = ports.first?.port else { return nil }
        return CodexDesktopRuntimeSocketBinding(target: target, port: port)
    }

    private nonisolated static func liveSocketBindingIsCurrent(
        _ binding: CodexDesktopRuntimeSocketBinding,
        requiredOwnerUID: UInt32
    ) -> Bool {
        socketBindingIsCurrent(
            binding,
            requiredOwnerUID: requiredOwnerUID,
            socketOwnerPID: { liveListeningSocketOwnerPID(port: $0) },
            runtimeTargetIsCurrent: { target, ownerUID in
                SwapEngine.runtimeTargetIsCurrent(
                    target,
                    requiredOwnerUID: ownerUID
                )
            }
        )
    }

    nonisolated static func socketBindingIsCurrent(
        _ binding: CodexDesktopRuntimeSocketBinding,
        requiredOwnerUID: UInt32,
        socketOwnerPID: (UInt16) -> Int32?,
        runtimeTargetIsCurrent: (CodexRuntimeTarget, UInt32) -> Bool
    ) -> Bool {
        let pid = binding.target.process.identity.pid
        return socketOwnerPID(binding.port) == pid
            && runtimeTargetIsCurrent(binding.target, requiredOwnerUID)
            && socketOwnerPID(binding.port) == pid
    }

    private nonisolated static func liveListeningSocketOwnerPID(port: UInt16) -> Int32? {
        let owners = Set(liveListeningPorts().filter { $0.port == port }.map(\.pid))
        return owners.count == 1 ? owners.first : nil
    }

    private nonisolated static func liveListeningPorts() -> [DesktopRuntimeListeningPort] {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n"],
            timeout: 3
        )
        guard !result.timedOut, result.terminationStatus == 0 else { return [] }
        return DesktopRuntimeDiagnostics.parseListeningPorts(
            fromLsofOutput: result.stdoutString
        ).filter { entry in
            let lower = entry.line.lowercased()
            return lower.contains("tcp 127.0.0.1:")
                || lower.contains("tcp localhost:")
                || lower.contains("tcp [::1]:")
                || lower.contains("tcp ::1:")
        }
    }

    private func sendJSONRPCRequest(
        _ request: [String: Any],
        socketBinding: CodexDesktopRuntimeSocketBinding,
        requiredOwnerUID: UInt32
    ) async -> DesktopRuntimeWebSocketEvent {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return .failure("failed to serialize json-rpc request")
        }

        if let requestSender {
            guard dependencies.socketBindingIsCurrent(
                socketBinding,
                requiredOwnerUID
            ) else {
                return .failure("desktop runtime binding drift")
            }
            return await requestSender(jsonString, socketBinding.port)
        }

        let url = URL(string: "ws://127.0.0.1:\(socketBinding.port)")!
        let session = URLSession(configuration: .default)
        defer { session.finishTasksAndInvalidate() }

        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        do {
            let response = try await Self.runWithTimeout(
                seconds: timeoutSeconds,
                cancel: { wsTask.cancel(with: .goingAway, reason: nil) },
                operation: {
                    guard dependencies.socketBindingIsCurrent(
                        socketBinding,
                        requiredOwnerUID
                    ) else {
                        throw DesktopRuntimeSocketError.bindingDrift
                    }
                    try await wsTask.send(.string(jsonString))
                    return try await wsTask.receive()
                }
            )
            wsTask.cancel(with: .normalClosure, reason: nil)

            switch response {
            case .string(let text):
                return .string(text)
            case .data(let data):
                return .data(data)
            @unknown default:
                return .failure("unknown websocket response")
            }
        } catch DesktopRuntimeSocketError.bindingDrift {
            wsTask.cancel(with: .goingAway, reason: nil)
            return .failure("desktop runtime binding drift")
        } catch is CancellationError {
            wsTask.cancel(with: .goingAway, reason: nil)
            return .timeout
        } catch {
            wsTask.cancel(with: .goingAway, reason: nil)
            return .failure(error.localizedDescription)
        }
    }

    nonisolated static func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        cancel: @Sendable @escaping () -> Void,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let gate = OneShotResultGate<T>()
        let operationTask = Task {
            do {
                _ = gate.resume(.success(try await operation()))
            } catch {
                _ = gate.resume(.failure(error))
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + max(0, seconds)
        ) {
            let didResume = gate.resume(.failure(CancellationError()))
            if didResume {
                cancel()
                operationTask.cancel()
            }
        }

        let result = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            _ = gate.resume(.failure(CancellationError()))
            cancel()
            operationTask.cancel()
        }
        return try result.get()
    }

    private nonisolated static func redactedErrorText(_ text: String) -> String {
        var redacted = text
        let patterns = [
            #"(?i)(access[_-]?token|refresh[_-]?token|id[_-]?token)[=:][^\s,}]+"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "$1=<redacted>",
                options: .regularExpression
            )
        }
        return redacted
    }
}

private enum AccountReadExtraction {
    case found(AccountReadAccount)
    case missing
    case malformed
}

private struct AccountReadRPCResponse: Decodable {
    let result: AccountReadResult
}

private struct AccountReadResult: Decodable {
    let account: AccountReadAccount?
    let requiresOpenaiAuth: Bool

    private enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenaiAuth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.account) else {
            throw DecodingError.keyNotFound(
                CodingKeys.account,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "account/read result is missing account"
                )
            )
        }
        account = try container.decodeIfPresent(AccountReadAccount.self, forKey: .account)
        requiresOpenaiAuth = try container.decode(Bool.self, forKey: .requiresOpenaiAuth)
    }
}

private struct AccountReadAccount: Decodable {
    let type: String
    let email: String?
    let planType: String?
    let accountIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case type
        case email
        case planType
        case chatgptAccountId
        case accountId
        case accountIDSnake = "account_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)

        guard type == "chatgpt" else {
            email = nil
            planType = nil
            accountIDs = []
            return
        }
        guard container.contains(.email) else {
            throw DecodingError.keyNotFound(
                CodingKeys.email,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ChatGPT account is missing email"
                )
            )
        }
        email = try container.decodeIfPresent(String.self, forKey: .email)
        planType = try container.decode(String.self, forKey: .planType)
        accountIDs = try [
            container.decodeIfPresent(String.self, forKey: .chatgptAccountId),
            container.decodeIfPresent(String.self, forKey: .accountId),
            container.decodeIfPresent(String.self, forKey: .accountIDSnake),
        ].compactMap { $0 }
    }
}

enum DesktopRuntimeWebSocketEvent: Sendable, Equatable {
    case string(String)
    case data(Data)
    case transportClosed(String)
    case failure(String)
    case timeout
    case cancelled
}

enum DesktopRuntimeRPCClassification: Sendable, Equatable {
    case success
    case methodNotFound
    case transportClosed
    case timeout
    case cancelled
    case failed(String)
}

private final class OneShotResultGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<Result<T, Error>, Never>?

    func resume(_ newResult: Result<T, Error>) -> Bool {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return false
        }
        result = newResult
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: newResult)
        return true
    }

    func wait() async -> Result<T, Error> {
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
