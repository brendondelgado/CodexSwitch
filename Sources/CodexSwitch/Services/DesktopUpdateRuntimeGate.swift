import Foundation

enum DesktopUpdateRuntimeReadiness: Equatable, Sendable {
    case ready
    case running
    case unavailable
}

struct DesktopUpdateRuntimeGate: Sendable {
    private static let hostFragments = [
        "/applications/chatgpt.app/contents/",
        "/applications/codex.app/contents/",
    ]

    let processRunner: DesktopUpdaterProcessRunner

    init(processRunner: DesktopUpdaterProcessRunner = DesktopUpdaterProcessRunner()) {
        self.processRunner = processRunner
    }

    func readiness(isCancelled: () -> Bool = { Task.isCancelled })
        -> DesktopUpdateRuntimeReadiness {
        if isCancelled() { return .unavailable }
        let host = processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", "/Applications/(ChatGPT|Codex)\\.app/Contents/"],
            timeout: 2,
            isCancelled: isCancelled
        )
        if isCancelled() { return .unavailable }
        let appServer = processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", "codex.*app-server"],
            timeout: 2,
            isCancelled: isCancelled
        )
        return Self.classify(host: host, appServer: appServer)
    }

    func blocksActivation(isCancelled: () -> Bool = { Task.isCancelled }) -> Bool {
        readiness(isCancelled: isCancelled) != .ready
    }

    static func classify(
        host: CodexDesktopTrustCommandResult,
        appServer: CodexDesktopTrustCommandResult
    ) -> DesktopUpdateRuntimeReadiness {
        guard probeCompleted(host), probeCompleted(appServer) else { return .unavailable }
        let hostResult = classifyProbe(host, recognizes: isDesktopHostLine)
        let appServerResult = classifyProbe(appServer, recognizes: isAppServerLine)
        guard hostResult != .ambiguous, appServerResult != .ambiguous else {
            return .unavailable
        }
        if hostResult == .match || appServerResult == .match {
            return .running
        }
        return .ready
    }

    private enum ProbeMatch: Equatable {
        case noMatch
        case match
        case ambiguous
    }

    private static func probeCompleted(_ result: CodexDesktopTrustCommandResult) -> Bool {
        !result.timedOut && !result.cancelled && result.reaped
            && !result.stdoutTruncated && !result.stderrTruncated
            && result.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (result.terminationStatus == 0 || result.terminationStatus == 1)
    }

    private static func classifyProbe(
        _ result: CodexDesktopTrustCommandResult,
        recognizes: (Substring) -> Bool
    ) -> ProbeMatch {
        let lines = result.standardOutput.split(whereSeparator: \.isNewline).filter {
            !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if result.terminationStatus == 1 {
            return lines.isEmpty ? .noMatch : .ambiguous
        }
        guard !lines.isEmpty, lines.allSatisfy(recognizes) else { return .ambiguous }
        return .match
    }

    private static func isDesktopHostLine(_ line: Substring) -> Bool {
        let value = line.lowercased()
        guard !value.contains("codexswitch"), !value.contains(" pgrep ") else {
            return false
        }
        return hostFragments.contains { value.contains($0) }
    }

    private static func isAppServerLine(_ line: Substring) -> Bool {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return false }
        let command = fields.dropFirst().map { String($0).lowercased() }
        guard let executable = command.first,
              !executable.contains("codexswitch"),
              !command.contains("pgrep") else {
            return false
        }
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        if executableName == "codex-app-server" { return true }
        return executableName == "codex" && command.dropFirst().first == "app-server"
    }
}
