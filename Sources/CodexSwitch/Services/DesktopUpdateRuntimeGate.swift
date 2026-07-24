import Darwin
import Foundation

enum DesktopUpdateRuntimeReadiness: Equatable, Sendable {
    case ready
    case running
    case unavailable
}

struct DesktopUpdateRuntimeGate: Sendable {
    private static let hostExecutables = [
        "/applications/chatgpt.app/contents/macos/chatgpt",
        "/applications/codex.app/contents/macos/codex",
    ]

    let processRunner: DesktopUpdaterProcessRunner
    let processExecutablePath: @Sendable (Int32) -> String?

    init(
        processRunner: DesktopUpdaterProcessRunner = DesktopUpdaterProcessRunner(),
        processExecutablePath: @escaping @Sendable (Int32) -> String? = {
            liveExecutablePath(pid: $0)
        }
    ) {
        self.processRunner = processRunner
        self.processExecutablePath = processExecutablePath
    }

    func readiness(isCancelled: () -> Bool = { Task.isCancelled })
        -> DesktopUpdateRuntimeReadiness {
        if isCancelled() { return .unavailable }
        let host = processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: [
                "-fl",
                "(ChatGPT|Codex)",
            ],
            timeout: 2,
            isCancelled: isCancelled
        )
        if isCancelled() { return .unavailable }
        let appServer = processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: [
                "-fl",
                "app-server",
            ],
            timeout: 2,
            isCancelled: isCancelled
        )
        return Self.classify(
            host: host,
            appServer: appServer,
            processExecutablePath: processExecutablePath
        )
    }

    func blocksActivation(isCancelled: () -> Bool = { Task.isCancelled }) -> Bool {
        readiness(isCancelled: isCancelled) != .ready
    }

    static func classify(
        host: CodexDesktopTrustCommandResult,
        appServer: CodexDesktopTrustCommandResult,
        processExecutablePath: (@Sendable (Int32) -> String?)? = nil
    ) -> DesktopUpdateRuntimeReadiness {
        guard probeCompleted(host), probeCompleted(appServer) else { return .unavailable }
        let hostResult = classifyProbe(host) { line in
            if let processExecutablePath {
                return classifyResolvedHostLine(
                    line,
                    processExecutablePath: processExecutablePath
                )
            }
            return isDesktopHostLine(line) ? .match : .ambiguous
        }
        let appServerResult = classifyProbe(appServer) { line in
            if let processExecutablePath {
                return classifyResolvedAppServerLine(
                    line,
                    processExecutablePath: processExecutablePath
                )
            }
            return isAppServerLine(line) ? .match : .ambiguous
        }
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
        classifyLine: (Substring) -> ProbeMatch
    ) -> ProbeMatch {
        let lines = result.standardOutput.split(whereSeparator: \.isNewline).filter {
            !String($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if result.terminationStatus == 1 {
            return lines.isEmpty ? .noMatch : .ambiguous
        }
        guard !lines.isEmpty else { return .ambiguous }
        var foundMatch = false
        for line in lines {
            switch classifyLine(line) {
            case .match:
                foundMatch = true
            case .noMatch:
                continue
            case .ambiguous:
                return .ambiguous
            }
        }
        return foundMatch ? .match : .noMatch
    }

    private static func classifyResolvedHostLine(
        _ line: Substring,
        processExecutablePath: (Int32) -> String?
    ) -> ProbeMatch {
        guard let pid = processID(in: line),
              let executable = processExecutablePath(pid)?.lowercased() else {
            return .ambiguous
        }
        return hostExecutables.contains(executable) ? .match : .noMatch
    }

    private static func classifyResolvedAppServerLine(
        _ line: Substring,
        processExecutablePath: (Int32) -> String?
    ) -> ProbeMatch {
        guard line.lowercased().contains("app-server"),
              let pid = processID(in: line),
              let executable = processExecutablePath(pid)?.lowercased() else {
            return .ambiguous
        }
        guard executable.contains("/applications/chatgpt.app/contents/")
                || executable.contains("/applications/codex.app/contents/") else {
            return .noMatch
        }
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        return executableName == "codex" || executableName == "codex-app-server"
            ? .match
            : .ambiguous
    }

    private static func processID(in line: Substring) -> Int32? {
        guard let first = line.split(whereSeparator: \.isWhitespace).first else {
            return nil
        }
        return Int32(first)
    }

    private static func liveExecutablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        let pathBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard !pathBytes.isEmpty else { return nil }
        return URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
            .resolvingSymlinksInPath()
            .path
    }

    private static func isDesktopHostLine(_ line: Substring) -> Bool {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return false }
        let executable = String(fields[1]).lowercased()
        return hostExecutables.contains(executable)
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
        guard executable.contains("/applications/chatgpt.app/contents/")
                || executable.contains("/applications/codex.app/contents/") else {
            return false
        }
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
        if executableName == "codex-app-server" { return true }
        return executableName == "codex" && command.dropFirst().contains("app-server")
    }
}
