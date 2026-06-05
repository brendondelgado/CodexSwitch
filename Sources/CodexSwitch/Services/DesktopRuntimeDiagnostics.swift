import Foundation

struct DesktopRuntimeDiagnostics: Sendable, Equatable {
    let appServerPID: Int32?
    let appServerPath: String?
    let websocketPort: UInt16?
    let codexAppTeamIdentifier: String?
    let codexAppAcceptedByGatekeeper: Bool
    let computerUsePluginCompatible: Bool
    let lastReloadError: String?

    /// Runs bounded subprocess diagnostics synchronously; call off UI/main hot paths.
    nonisolated static func current() -> DesktopRuntimeDiagnostics {
        let pgrepResult = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", "codex.*app-server"],
            timeout: 3
        )
        let processes = pgrepResult.timedOut ? [] : parseAppServerProcesses(fromPGrepOutput: pgrepResult.stdoutString)
        let desktopProcess = processes.first { $0.classification == .desktopAppServer }

        let lsofResult = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n"],
            timeout: 3
        )
        let port = lsofResult.timedOut
            ? nil
            : parseWebSocketPort(fromLsofOutput: lsofResult.stdoutString, appServerPID: desktopProcess?.pid)

        let teamIdentifier = codeSignatureTeamIdentifier(at: codexAppPath)
        let gatekeeperAccepted = spctlAccepts(path: codexAppPath)

        return DesktopRuntimeDiagnostics(
            appServerPID: desktopProcess?.pid,
            appServerPath: desktopProcess?.executablePath,
            websocketPort: port,
            codexAppTeamIdentifier: teamIdentifier,
            codexAppAcceptedByGatekeeper: gatekeeperAccepted,
            computerUsePluginCompatible: DesktopPatchManager.bundledComputerUsePluginSignatureCompatible(),
            lastReloadError: nil
        )
    }

    nonisolated static func parseAppServerProcesses(fromPGrepOutput output: String) -> [DesktopRuntimeAppServerProcess] {
        output.components(separatedBy: "\n").compactMap { line in
            parseAppServerProcessLine(line)
        }
    }

    nonisolated static func parseAppServerProcessLine(_ line: String) -> DesktopRuntimeAppServerProcess? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }

        let commandLine = String(parts[1])
        let lower = commandLine.lowercased()
        guard lower.contains(" app-server") else { return nil }
        guard !lower.contains("codexswitch"), !lower.contains("pgrep") else { return nil }

        let executablePath = executablePath(fromAppServerCommandLine: commandLine)
        let classification = classifyAppServerPath(executablePath ?? commandLine)
        guard classification != .other else { return nil }

        return DesktopRuntimeAppServerProcess(
            pid: pid,
            executablePath: executablePath,
            commandLine: commandLine,
            classification: classification
        )
    }

    nonisolated static func classifyAppServerPath(_ path: String) -> DesktopRuntimeAppServerClassification {
        let lower = path.lowercased()
        if lower.contains("/applications/codex.app/contents/resources/codex") {
            return .desktopAppServer
        }
        if lower.contains("/developer/codex/codex-rs/target/fork-release/codex") {
            return .desktopAppServer
        }
        if lower.contains("/developer/codex/codex-rs/target/release/codex") {
            return .desktopAppServer
        }
        if lower.contains("/@openai/codex/")
            && lower.contains("/vendor/")
            && lower.contains("/codex/codex") {
            return .vendorCLIAppServer
        }
        if lower.contains("/opt/homebrew/bin/codex") || lower.contains("/usr/local/bin/codex") {
            return .vendorCLIAppServer
        }
        return .other
    }

    nonisolated static func parseWebSocketPort(fromLsofOutput output: String, appServerPID: Int32?) -> UInt16? {
        guard let appServerPID else { return nil }
        return parseListeningPorts(fromLsofOutput: output).first { entry in
            return entry.pid == appServerPID
        }?.port
    }

    nonisolated static func parseListeningPorts(fromLsofOutput output: String) -> [DesktopRuntimeListeningPort] {
        output.components(separatedBy: "\n").compactMap { line in
            parseListeningPortLine(line)
        }
    }

    private nonisolated static let codexAppPath = "/Applications/Codex.app"

    private nonisolated static func executablePath(fromAppServerCommandLine commandLine: String) -> String? {
        guard let range = commandLine.range(of: " app-server") else { return nil }
        let beforeAppServer = String(commandLine[..<range.lowerBound])
        if beforeAppServer.hasPrefix("node ") {
            return beforeAppServer.split(separator: " ", maxSplits: 1).last.map(String.init)
        }
        return beforeAppServer
    }

    private nonisolated static func parseListeningPortLine(_ line: String) -> DesktopRuntimeListeningPort? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.localizedCaseInsensitiveContains("(LISTEN)") else { return nil }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let pid = Int32(parts[1]) else { return nil }
        guard let port = tcpPort(from: trimmed) else { return nil }

        return DesktopRuntimeListeningPort(
            command: String(parts[0]),
            pid: pid,
            port: port,
            line: trimmed
        )
    }

    private nonisolated static func tcpPort(from line: String) -> UInt16? {
        let pattern = /(?:localhost|127\.0\.0\.1|\*|\[::1\]|::1):(\d+)/
        guard let match = line.firstMatch(of: pattern) else { return nil }
        return UInt16(match.output.1)
    }

    private nonisolated static func codeSignatureTeamIdentifier(at path: String) -> String? {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", path],
            timeout: 3
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            return nil
        }

        let output = result.stdoutString + "\n" + result.stderrString
        for line in output.components(separatedBy: "\n") {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            return String(line.dropFirst("TeamIdentifier=".count))
        }
        return nil
    }

    private nonisolated static func spctlAccepts(path: String) -> Bool {
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", path],
            timeout: 3
        )
        return !result.timedOut && result.terminationStatus == 0
    }
}

struct DesktopRuntimeAppServerProcess: Sendable, Equatable {
    let pid: Int32
    let executablePath: String?
    let commandLine: String
    let classification: DesktopRuntimeAppServerClassification
}

enum DesktopRuntimeAppServerClassification: Sendable, Equatable {
    case desktopAppServer
    case vendorCLIAppServer
    case other
}

struct DesktopRuntimeListeningPort: Sendable, Equatable {
    let command: String
    let pid: Int32
    let port: UInt16
    let line: String
}
