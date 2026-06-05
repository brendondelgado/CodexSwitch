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

struct DesktopRuntimeReloadClient: Sendable {
    private let port: UInt16?
    private let timeoutSeconds: TimeInterval

    nonisolated static let safeProbeMethods = [
        "getAuthStatus",
        "account/read",
        "account/status",
        "account/get",
        "session/get",
        "auth/status"
    ]

    nonisolated static let reloadMethods = ["account/login/start"]

    init(port: UInt16? = nil, timeoutSeconds: TimeInterval = 5) {
        self.port = port
        self.timeoutSeconds = timeoutSeconds
    }

    func probeCapability() async -> DesktopReloadCapability {
        guard let port = port ?? DesktopAppConnector.discoverPort() else {
            return .appServerUnavailable
        }

        var probedMethods: [String] = []
        for method in Self.safeProbeMethods {
            probedMethods.append(method)
            desktopReloadLogger.info("DESKTOP_RELOAD_PROBE method=\(method, privacy: .public)")

            let request = Self.probeRequest(method: method, id: probedMethods.count)
            let event = await sendJSONRPCRequest(request, port: port)
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
        guard let port = port ?? DesktopAppConnector.discoverPort() else {
            return .noDesktopRuntime
        }
        return await reloadAuth(account: account, port: port)
    }

    func reloadAuth(account: CodexAccount, port: UInt16) async -> DesktopReloadResult {
        let method = Self.reloadMethods[0]
        let request = Self.reloadRequest(account: account, method: method, id: 1)
        let event = await sendJSONRPCRequest(request, port: port)
        return Self.classifyReloadResponse(event, method: method, expectedID: 1)
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
        method: String,
        expectedID: Int? = nil
    ) -> DesktopReloadResult {
        switch classifyRPCEvent(event, expectedID: expectedID) {
        case .success:
            return .reloaded(method: method)
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

    private func sendJSONRPCRequest(_ request: [String: Any], port: UInt16) async -> DesktopRuntimeWebSocketEvent {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return .failure("failed to serialize json-rpc request")
        }

        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .default)
        defer { session.finishTasksAndInvalidate() }

        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        do {
            let response = try await Self.runWithTimeout(
                seconds: timeoutSeconds,
                cancel: { wsTask.cancel(with: .goingAway, reason: nil) },
                operation: {
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
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            let didResume = gate.resume(.failure(CancellationError()))
            if didResume {
                cancel()
                operationTask.cancel()
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    let result = await gate.wait()
                    timeoutTask.cancel()
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            _ = gate.resume(.failure(CancellationError()))
            cancel()
            operationTask.cancel()
            timeoutTask.cancel()
        }
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
