import Foundation
import Darwin.POSIX
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "SwapEngine")

enum SwapEngine {
    private static let codexAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath

    /// Score an account for swap eligibility. Higher = better candidate.
    /// Returns -1 for ineligible accounts (exhausted, no data).
    static func score(_ account: CodexAccount) -> Double {
        guard let snapshot = account.quotaSnapshot else { return -1 }
        let fiveHr = snapshot.fiveHour
        let weekly = snapshot.weekly

        // HARD EXCLUSIONS: Can't use account at all if either limit is fully exhausted
        if weekly.isExhausted { return -1 }  // Weekly at 0% = completely unusable
        if fiveHr.isExhausted && weekly.isExhausted { return -1 }

        // If 5h is exhausted but weekly still has capacity, only consider if
        // the 5h window resets soon (within 30 minutes)
        if fiveHr.isExhausted {
            if fiveHr.timeUntilReset > 1800 { return -1 }
            // Near reset — give a small score proportional to proximity
            let proximityBonus = (1800 - fiveHr.timeUntilReset) / 1800 * 15
            return proximityBonus + weekly.remainingPercent * 0.1
        }

        // Primary: 5-hour remaining (0-100)
        var s = fiveHr.remainingPercent

        // Weight weekly remaining more heavily — low weekly is a significant penalty
        // Weekly at 50% should be a meaningful reduction vs weekly at 100%
        s += weekly.remainingPercent * 0.3

        // Penalize accounts with very low weekly (< 20%) even if 5h is high
        if weekly.remainingPercent < 20 {
            s *= 0.5  // Halve the score — prefer accounts with more weekly runway
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

        // Reset proximity bonus
        if fiveHr.isExhausted && fiveHr.timeUntilReset < 1800 {
            let mins = Int(fiveHr.timeUntilReset / 60)
            lines.append("5h window resets in \(mins)m — near-reset bonus applied")
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
    /// Safety filters:
    ///   1. Only signals processes started AFTER the SIGHUP fork was installed
    ///      (pre-fork binaries would be KILLED by unhandled SIGHUP).
    ///   2. Only signals processes running for >10 seconds (newly-started processes
    ///      haven't registered their SIGHUP handler yet and would be killed).
    static func signalCodexReload() {
        guard let forkInstallTime = forkInstallDate() else {
            logger.info("SIGHUP fork not installed — skipping signal (auth.json was still updated)")
            SwapLog.append(.sighupSkipped(reason: "fork not installed"))
            return
        }

        let now = Date()
        let minAge: TimeInterval = 10  // Process must be running at least 10s

        // Get all codex process PIDs with their start times
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,lstart,comm"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("Failed to run ps: \(error.localizedDescription)")
            SwapLog.append(.sighupSkipped(reason: "ps failed: \(error.localizedDescription)"))
            return
        }
        // Read pipe BEFORE waitUntilExit — ps output with full paths can exceed
        // the 64KB pipe buffer (~80KB on this machine), causing a deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var signaled = 0
        var skippedOld = 0
        var skippedTooNew = 0

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Only match lines ending with "codex" command
            guard trimmed.hasSuffix("/codex") || trimmed.hasSuffix(" codex") else { continue }
            // Skip our own CodexSwitch process and pgrep/ps
            guard !trimmed.contains("CodexSwitch") && !trimmed.contains("pgrep") && !trimmed.contains("/bin/ps") else { continue }

            // Parse PID (first column) and start time (next 5 tokens)
            let parts = trimmed.split(separator: " ", maxSplits: 6)
            guard parts.count >= 6,
                  let pid = Int32(parts[0]) else { continue }

            // LSTART format: "Wed Mar 12 15:30:00 2026" (5 tokens: parts[1..5])
            let startStr = parts[1..<6].joined(separator: " ")
            if let startDate = dateFormatter.date(from: startStr) {
                if startDate < forkInstallTime {
                    skippedOld += 1
                    logger.warning("Skipping pid \(pid) (started \(startStr) — before fork install, would kill)")
                    SwapLog.append(.sighupSkipped(reason: "pid \(pid) started before fork (\(startStr))"))
                } else if now.timeIntervalSince(startDate) < minAge {
                    skippedTooNew += 1
                    logger.info("Skipping pid \(pid) (started \(startStr) — too new, handler may not be registered)")
                    SwapLog.append(.sighupSkipped(reason: "pid \(pid) started <10s ago"))
                } else {
                    kill(pid, SIGHUP)
                    signaled += 1
                    logger.info("SIGHUP → pid \(pid) (started \(startStr) — after fork install)")
                    SwapLog.append(.sighupSent(pid: pid, startedAt: startStr))
                }
            } else {
                skippedOld += 1
                logger.warning("Skipping pid \(pid) — could not parse start time")
                SwapLog.append(.sighupSkipped(reason: "pid \(pid) unparseable start time"))
            }
        }

        if signaled == 0 && skippedOld == 0 && skippedTooNew == 0 {
            logger.info("No codex CLI processes found to signal")
            SwapLog.append(.sighupSkipped(reason: "no codex processes found"))
        }
        logger.info("SIGHUP summary: signaled=\(signaled) skippedOld=\(skippedOld) skippedTooNew=\(skippedTooNew)")
    }

    /// Get the install date of the SIGHUP fork from the marker file's modification time.
    private static func forkInstallDate() -> Date? {
        let markerPath = NSString("~/.codexswitch/sighup-enabled").expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: markerPath),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modDate
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
