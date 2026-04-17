// Sources/CodexNative/AppServer/AppServerManager.swift
import Foundation
import os

private let logger = Logger(subsystem: "com.codexnative", category: "AppServer")

@MainActor
@Observable
final class AppServerManager {
    enum State: Equatable {
        case idle
        case starting
        case running(port: UInt16)
        case failed(error: String)
    }

    private(set) var state: State = .idle
    private var process: Process?
    private var stderrPipe: Pipe?

    /// The WebSocket URL the React frontend should connect to
    var websocketURL: URL? {
        guard case .running(let port) = state else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)")
    }

    /// Start the app-server process. Discovers the WebSocket port from stderr.
    func start(codexBinaryPath: String? = nil) {
        guard state == .idle || state != .starting else { return }
        state = .starting

        let binaryPath = codexBinaryPath ?? findCodexBinary()
        guard let binaryPath else {
            state = .failed(error: "Codex binary not found")
            logger.error("Cannot find codex binary")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "app-server",
            "--listen", "ws://127.0.0.1:0",
            "--analytics-default-enabled"
        ]

        // Inherit user's environment for PATH, HOME, etc.
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = NSString("~/.codex").expandingTildeInPath
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        self.stderrPipe = stderrPipe

        // Read stderr for port discovery + logging
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }

            for l in line.components(separatedBy: "\n") where !l.isEmpty {
                logger.info("app-server: \(l)")

                if let port = AppServerPortDiscovery.parsePort(from: l) {
                    Task { @MainActor [weak self] in
                        self?.state = .running(port: port)
                        logger.info("App-server listening on port \(port)")
                    }
                }
            }
        }

        // Auto-restart on crash
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            logger.warning("App-server exited with code \(code)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = .idle
                self.process = nil
                // Auto-restart after 1s delay
                try? await Task.sleep(for: .seconds(1))
                self.start(codexBinaryPath: binaryPath)
            }
        }

        do {
            try process.run()
            self.process = process
            logger.info("App-server started (pid \(process.processIdentifier))")
        } catch {
            state = .failed(error: error.localizedDescription)
            logger.error("Failed to start app-server: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        state = .idle
    }

    /// Find the codex binary — check common locations
    private func findCodexBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            NSString("~/.codex/bin/codex").expandingTildeInPath,
            "/usr/local/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
