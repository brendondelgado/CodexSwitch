import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "DesktopApp")

/// Connects to a running Codex desktop app via its local WebSocket server
/// and injects auth tokens using the JSON-RPC `account/login/start` method.
enum DesktopAppConnector {

    /// Discover the WebSocket port of a running Codex app-server.
    /// The app-server binds to 127.0.0.1 on a dynamic port.
    nonisolated static func discoverPort() -> UInt16? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            logger.error("lsof failed: \(error.localizedDescription)")
            return nil
        }

        // Read pipe data BEFORE waitUntilExit to avoid deadlock if output fills buffer
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // Look for Codex desktop app listening on 127.0.0.1.
        // The Electron-based Codex app shows as "Codex" or "Electron" process names
        // with a Codex-related path in the lsof output.
        for line in output.components(separatedBy: "\n") {
            let lower = line.lowercased()
            // Skip our own CodexSwitch and CLI processes
            guard !lower.contains("codexswitch") else { continue }
            // Match "codex" directly, or "electron" only if the line also
            // references a Codex-specific path (avoids matching other Electron apps)
            let isCodexProcess = lower.contains("codex")
            let isCodexElectron = lower.contains("electron") && (
                lower.contains("codex.app") || lower.contains("/codex/")
            )
            guard isCodexProcess || isCodexElectron else { continue }
            // Format: "Electron 1234 user  12u  IPv4 ... TCP 127.0.0.1:PORT (LISTEN)"
            if let portMatch = line.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression) {
                let portStr = line[portMatch]
                    .components(separatedBy: ":")
                    .last ?? ""
                if let port = UInt16(portStr) {
                    logger.info("Found Codex app-server on port \(port)")
                    return port
                }
            }
        }

        logger.debug("No Codex app-server found listening")
        return nil
    }

    /// Inject auth tokens into the running Codex desktop app via WebSocket JSON-RPC.
    /// Returns true on success.
    static func injectTokens(
        accessToken: String,
        chatgptAccountId: String,
        planType: String?,
        port: UInt16
    ) async -> Bool {
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .default)
        defer { session.finishTasksAndInvalidate() }
        let wsTask = session.webSocketTask(with: url)
        wsTask.resume()

        // Build JSON-RPC request matching Codex protocol v2
        var params: [String: Any] = [
            "type": "chatgptAuthTokens",
            "accessToken": accessToken,
            "chatgptAccountId": chatgptAccountId
        ]
        if let planType {
            params["chatgptPlanType"] = planType
        }

        let request: [String: Any] = [
            "method": "account/login/start",
            "id": 1,
            "params": params
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.error("Failed to serialize login request")
            wsTask.cancel(with: .goingAway, reason: nil)
            return false
        }

        do {
            try await wsTask.send(.string(jsonString))
            logger.info("Sent account/login/start to Codex desktop app on port \(port)")

            // Wait for response (with timeout)
            let response = try await withTimeout(seconds: 5) {
                try await wsTask.receive()
            }

            switch response {
            case .string(let text):
                logger.info("Desktop app response: \(text.prefix(200))")
                wsTask.cancel(with: .normalClosure, reason: nil)
                // Check for error in response
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["error"] != nil {
                    logger.error("Desktop app returned error: \(text.prefix(200))")
                    return false
                }
                return true
            case .data(let data):
                logger.info("Desktop app response (binary): \(data.count) bytes")
                wsTask.cancel(with: .normalClosure, reason: nil)
                return true
            @unknown default:
                wsTask.cancel(with: .normalClosure, reason: nil)
                return true
            }
        } catch {
            logger.error("WebSocket error: \(error.localizedDescription)")
            wsTask.cancel(with: .goingAway, reason: nil)
            return false
        }
    }

    /// Try to inject tokens into any running Codex desktop app instance.
    /// Returns true if a desktop app was found and tokens were injected.
    static func tryInjectTokens(for account: CodexAccount) async -> Bool {
        guard let port = discoverPort() else {
            logger.debug("No Codex desktop app running — skipping injection")
            return false
        }

        return await injectTokens(
            accessToken: account.accessToken,
            chatgptAccountId: account.accountId,
            planType: account.planType,
            port: port
        )
    }

    /// Async timeout helper
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
