import Foundation
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "DesktopApp")

/// Discovers the local WebSocket endpoint for the ChatGPT/Codex app-server.
/// Desktop auth reloads are owned by `DesktopRuntimeReloadClient`.
enum DesktopAppConnector {
    /// Discover the WebSocket port of a running Codex app-server.
    /// The app-server binds to 127.0.0.1 on a dynamic port.
    nonisolated static func discoverPort() -> UInt16? {
        let discovery = SwapEngine.desktopRuntimeDiscoverySnapshot(
            from: SwapEngine.discoverCodexProcesses(),
            requiredOwnerUID: UInt32(getuid())
        )
        guard discovery.isComplete else {
            logger.debug("Codex app-server identity discovery was incomplete")
            return nil
        }

        let lsofResult = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n"],
            timeout: 3
        )
        guard !lsofResult.timedOut, lsofResult.terminationStatus == 0 else {
            logger.debug("lsof failed or timed out while discovering Codex app-server")
            return nil
        }

        let port = discoverPort(
            appServerPIDs: discovery.targets.map { $0.process.identity.pid },
            lsofOutput: lsofResult.stdoutString
        )
        if let port {
            logger.info("Found Codex desktop app-server on port \(port)")
        } else {
            logger.debug("No Codex desktop app-server found listening")
        }
        return port
    }

    nonisolated static func discoverPort(
        appServerPIDs: [Int32],
        lsofOutput: String
    ) -> UInt16? {
        let listeningPorts = DesktopRuntimeDiagnostics.parseListeningPorts(
            fromLsofOutput: lsofOutput
        )
        return appServerPIDs.lazy.compactMap { pid in
            listeningPorts.first { $0.pid == pid }?.port
        }.first
    }

    nonisolated static func discoverPort(pgrepOutput: String, lsofOutput: String) -> UInt16? {
        let desktopPID = DesktopRuntimeDiagnostics
            .parseAppServerProcesses(fromPGrepOutput: pgrepOutput)
            .first { $0.classification == .desktopAppServer }?
            .pid
        guard let desktopPID else { return nil }
        return DesktopRuntimeDiagnostics.parseWebSocketPort(
            fromLsofOutput: lsofOutput,
            appServerPID: desktopPID
        )
    }

}
