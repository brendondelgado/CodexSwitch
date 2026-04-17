import Foundation
import Darwin.POSIX
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "SwapEngine")

enum SwapEngine {
    private static let codexAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath
    private static let sighupVerifiedExecPath = NSString("~/.codexswitch/sighup-verified-exec").expandingTildeInPath
    private static let sighupVerifiedTuiPath = NSString("~/.codexswitch/sighup-verified-tui").expandingTildeInPath
    private static let vendorCodexBinaryPath = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"

    /// Score an account for swap eligibility. Higher = better candidate.
    /// Returns -1 for ineligible accounts (no data, both windows exhausted).
    static func score(_ account: CodexAccount) -> Double {
        guard let snapshot = account.quotaSnapshot else { return -1 }
        let fiveHr = snapshot.fiveHour
        let weekly = snapshot.weekly

        // Weekly exhausted: usually unusable, BUT if weekly resets within 10 minutes,
        // score by proximity — the account is about to have full capacity.
        if weekly.isExhausted {
            let minsUntilReset = weekly.timeUntilReset / 60
            if minsUntilReset > 0 && minsUntilReset <= 10 {
                // Imminent weekly reset: score 20-30 (higher than any non-resetting account)
                // so this account gets picked as "Next Up"
                let proximity = 1 - (minsUntilReset / 10) // 1.0 at 0m → 0.0 at 10m
                return 20 + proximity * 10 + fiveHr.remainingPercent * 0.01
            }
            return -1
        }

        // 5h exhausted but weekly has capacity — score by time until 5h resets.
        // Closer to reset = higher score. An account resetting in 10 min is much
        // better than one resetting in 4 hours, but both are valid candidates.
        if fiveHr.isExhausted {
            let hoursUntilReset = max(0, fiveHr.timeUntilReset / 3600)
            let maxHours: Double = 5  // 5h window duration
            // proximity: 1.0 when resetting now → 0.0 when resetting in 5h
            let proximity = max(0, 1 - (hoursUntilReset / maxHours))
            // Score range: 0.1 (far reset) to ~19 (imminent reset + high weekly)
            return proximity * 15 + weekly.remainingPercent * 0.1
        }

        // Primary: 5-hour remaining (0-100)
        var s = fiveHr.remainingPercent

        // Prefer LOWER weekly — drain constrained accounts first, save fresh ones.
        // An account with 10% weekly should be used before one with 100% weekly,
        // because the 10% account's capacity is scarce and will be wasted otherwise.
        s += (100 - weekly.remainingPercent) * 0.3

        // Penalize if weekly is critically low (< 5%) — about to hit the wall
        if weekly.remainingPercent < 5 {
            s *= 0.5
        }

        // Pro accounts get a boost — higher rate limits and faster inference
        // mean tasks complete faster. A Pro account at the same remaining %
        // as a Plus account is a better swap target.
        if account.planType?.lowercased() == "pro" {
            s *= 1.25
        }

        return s
    }

    /// Select the best account to swap to from candidates (excluding currently active)
    static func selectOptimalAccount(from accounts: [CodexAccount]) -> CodexAccount? {
        accounts
            .filter { !$0.isActive }
            .filter { score($0) > 0 }
            .max { score($0) < score($1) }
    }

    /// Explain why a candidate was selected as next-up over alternatives
    static func explainSelection(candidate: CodexAccount, allAccounts: [CodexAccount]) -> String {
        guard let snapshot = candidate.quotaSnapshot else {
            return "Selected but no quota data available yet."
        }

        let fiveHr = snapshot.fiveHour
        let weekly = snapshot.weekly
        let candidateScore = score(candidate)

        var lines: [String] = []

        // Primary factor
        lines.append("5h: \(Int(fiveHr.remainingPercent))% | Weekly: \(Int(weekly.remainingPercent))%")

        // Weekly status
        if weekly.remainingPercent < 20 {
            lines.append("⚠ Low weekly — score penalized")
        } else if weekly.remainingPercent < 50 {
            lines.append("Weekly at \(Int(weekly.remainingPercent))% — factored into score")
        }

        // Reset proximity info
        if fiveHr.isExhausted {
            let mins = Int(fiveHr.timeUntilReset / 60)
            if mins < 60 {
                lines.append("5h resets in \(mins)m")
            } else {
                lines.append("5h resets in \(mins / 60)h \(mins % 60)m")
            }
        }

        // Compare against runners-up
        let eligible = allAccounts.filter { !$0.isActive && $0.id != candidate.id && score($0) > 0 }
        let others = eligible.sorted { score($0) > score($1) }

        if let runnerUp = others.first, let ruSnap = runnerUp.quotaSnapshot {
            let diff = Int(fiveHr.remainingPercent - ruSnap.fiveHour.remainingPercent)
            if diff > 0 {
                lines.append("+\(diff)% over next best (\(runnerUp.email.components(separatedBy: "@").first ?? "")@...)")
            } else {
                lines.append("Tied with others — weekly quota broke the tie")
            }
        }

        let excluded = allAccounts.filter { !$0.isActive && score($0) <= 0 }
        if !excluded.isEmpty {
            lines.append("\(excluded.count) account\(excluded.count == 1 ? "" : "s") excluded (exhausted or no data)")
        }

        lines.append("Score: \(String(format: "%.0f", candidateScore))")

        return lines.joined(separator: "\n")
    }

    /// Generate auth.json data for a given account
    static func generateAuthFileData(for account: CodexAccount) throws -> Data {
        let authFile = AuthFile(
            authMode: "chatgpt",
            openaiApiKey: nil,
            tokens: AuthTokens(
                idToken: account.idToken,
                accessToken: account.accessToken,
                refreshToken: account.refreshToken,
                accountId: account.accountId
            ),
            lastRefresh: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(authFile)
    }

    /// Send SIGHUP to running Codex CLI processes so they reload auth.json.
    /// Only sends if ~/.codexswitch/sighup-verified exists — written by the
    /// SIGHUP-capable binary on startup after registering the signal handler.
    static func signalCodexReload() {
        guard isCurrentInstalledCodexSighupVerified() else {
            logger.info("SIGHUP not verified for current installed codex binary — skipping")
            SwapLog.append(.sighupSkipped(reason: "sighup verification stale or missing"))
            return
        }

        let now = Date()
        let minAge: TimeInterval = 10  // Process must be running at least 10s

        // Find all codex processes via pgrep (simpler, no LSTART parsing needed)
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-lf", "codex"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("Failed to run pgrep: \(error.localizedDescription)")
            SwapLog.append(.sighupSkipped(reason: "pgrep failed"))
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        var signaled = 0
        var skippedTooNew = 0

        for pid in signalableCodexProcessIDs(from: output) {
            // Check process age via /proc or kill(0) — use proc_pidinfo alternative on macOS
            // Simple approach: check if process started recently via sysctl
            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            if size > 0 {
                let startTime = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
                if now.timeIntervalSince(startTime) < minAge {
                    skippedTooNew += 1
                    logger.info("Skipping pid \(pid) — started <10s ago")
                    SwapLog.append(.sighupSkipped(reason: "pid \(pid) started <10s ago"))
                    continue
                }
            }

            kill(pid, SIGHUP)
            signaled += 1
            logger.info("SIGHUP → pid \(pid)")
            SwapLog.append(.sighupSent(pid: pid, startedAt: ""))
        }

        // Also SIGHUP the Codex app-server process. The fork's SIGHUP handler
        // reloads auth AND sends AccountUpdated/AccountLoginCompleted notifications
        // to the Electron frontend, triggering a seamless account switch in the UI.
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().contains("codex app-server") else { continue }
            guard let pid = Int32(trimmed.split(separator: " ").first ?? "") else { continue }

            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            if size > 0 {
                let startTime = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
                if now.timeIntervalSince(startTime) < minAge { continue }
            }

            kill(pid, SIGHUP)
            signaled += 1
            logger.info("SIGHUP → app-server pid \(pid)")
            SwapLog.append(.sighupSent(pid: pid, startedAt: "app-server"))
        }

        if signaled == 0 && skippedTooNew == 0 {
            logger.info("No codex CLI processes found to signal")
            SwapLog.append(.sighupSkipped(reason: "no codex processes found"))
        }
        logger.info("SIGHUP summary: signaled=\(signaled) skippedTooNew=\(skippedTooNew)")
    }

    static func isSighupVerificationCurrent(
        markerModificationDate: Date?,
        binaryModificationDate: Date?
    ) -> Bool {
        guard let markerModificationDate, let binaryModificationDate else {
            return false
        }
        return markerModificationDate >= binaryModificationDate
    }

    private static func isCurrentInstalledCodexSighupVerified() -> Bool {
        let fileManager = FileManager.default
        let binaryDate = (try? fileManager.attributesOfItem(atPath: vendorCodexBinaryPath))?[.modificationDate] as? Date

        // Check either marker file (exec or tui) — whichever is newest
        let execDate = (try? fileManager.attributesOfItem(atPath: sighupVerifiedExecPath))?[.modificationDate] as? Date
        let tuiDate = (try? fileManager.attributesOfItem(atPath: sighupVerifiedTuiPath))?[.modificationDate] as? Date
        let markerDate = [execDate, tuiDate].compactMap { $0 }.max()

        return isSighupVerificationCurrent(
            markerModificationDate: markerDate,
            binaryModificationDate: binaryDate
        )
    }

    static func signalableCodexProcessIDs(
        from output: String,
        ttyProvider: (Int32) -> String? = ttyName(for:)
    ) -> [Int32] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { signalableCodexProcessID(from: String($0), ttyProvider: ttyProvider) }
    }

    private static func signalableCodexProcessID(
        from line: String,
        ttyProvider: (Int32) -> String?
    ) -> Int32? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fields = trimmed.split(whereSeparator: \.isWhitespace)
        guard let pidField = fields.first, let pid = Int32(pidField) else { return nil }

        let commandFields = Array(fields.dropFirst())
        guard !commandFields.isEmpty else { return nil }

        let executable = commandFields[0]

        let command = commandFields.joined(separator: " ").lowercased()
        guard !command.contains("codexswitch"), !command.contains("pgrep") else { return nil }
        guard isCodexExecutable(executable) else { return nil }
        guard !isBundledDesktopCodex(executable) else { return nil }
        guard hasInteractiveTTY(pid, ttyProvider: ttyProvider) else { return nil }

        return pid
    }

    private static func isCodexExecutable(_ executable: Substring) -> Bool {
        let lower = executable.lowercased()
        return lower == "codex" || lower.hasSuffix("/codex")
    }

    private static func isBundledDesktopCodex(_ executable: Substring) -> Bool {
        let lower = executable.lowercased()
        return lower.hasSuffix("/codex") && lower.contains(".app/contents/")
    }

    private static func hasInteractiveTTY(
        _ pid: Int32,
        ttyProvider: (Int32) -> String?
    ) -> Bool {
        guard let tty = ttyProvider(pid)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !tty.isEmpty,
            tty != "??"
        else {
            return false
        }
        return true
    }

    private static func ttyName(for pid: Int32) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            logger.error("Failed to inspect tty for pid \(pid): \(error.localizedDescription)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Restart the Codex desktop app so it re-reads auth.json.
    /// The Electron frontend caches auth and doesn't pick up SIGHUP-driven backend reloads.
    static func restartCodexDesktopApp() {
        let codexAppPath = "/Applications/Codex.app"
        guard FileManager.default.fileExists(atPath: codexAppPath) else { return }

        // Check if it's running
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checkProcess.arguments = ["-f", "Codex.app/Contents/MacOS/Codex"]
        checkProcess.standardOutput = Pipe()
        checkProcess.standardError = FileHandle.nullDevice
        try? checkProcess.run()
        let checkData = (checkProcess.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        checkProcess.waitUntilExit()
        let isRunning = !(String(data: checkData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard isRunning else {
            logger.info("Codex desktop app not running — skip restart")
            return
        }

        // Kill and relaunch
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killProcess.arguments = ["Codex"]
        killProcess.standardOutput = FileHandle.nullDevice
        killProcess.standardError = FileHandle.nullDevice
        try? killProcess.run()
        killProcess.waitUntilExit()

        // Brief pause for clean shutdown
        Thread.sleep(forTimeInterval: 1.5)

        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "Codex"]
        openProcess.standardOutput = FileHandle.nullDevice
        openProcess.standardError = FileHandle.nullDevice
        try? openProcess.run()
        openProcess.waitUntilExit()

        logger.info("Codex desktop app restarted for auth reload")
        SwapLog.append(.debug("Codex desktop app restarted"))
    }

    /// Kill just the Codex app-server process (not the Electron frontend).
    /// Electron detects the child died and relaunches it, which reads fresh auth.json.
    /// This is the only reliable way to hot-swap the desktop app — the file watcher
    /// is unreliable, WebSocket injection has no port, and SIGHUP crashes stock.
    static func restartCodexAppServer() {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "codex app-server"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
            kill(pid, SIGTERM)
            logger.info("Killed app-server pid \(pid) for auth reload")
            SwapLog.append(.debug("APP_SERVER_RESTARTED pid=\(pid)"))
        }
    }

    /// Atomically write auth.json for the given account
    static func writeAuthFile(for account: CodexAccount, path: String? = nil) throws {
        let targetPath = path ?? codexAuthPath
        let tmpPath = targetPath + ".tmp"
        let data = try generateAuthFileData(for: account)

        try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)

        // Atomic rename — single syscall, no gap where file doesn't exist
        guard Darwin.rename(tmpPath, targetPath) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        // Restore permissions (600)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: targetPath
        )
    }
}
