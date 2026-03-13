import Foundation
import Darwin.POSIX
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "SwapEngine")

enum SwapEngine {
    private static let codexAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath

    /// Score an account for swap eligibility. Higher = better candidate.
    /// Returns -1 for ineligible accounts (no data, both windows exhausted).
    static func score(_ account: CodexAccount) -> Double {
        guard let snapshot = account.quotaSnapshot else { return -1 }
        let fiveHr = snapshot.fiveHour
        let weekly = snapshot.weekly

        // HARD EXCLUSION: Weekly exhausted = completely unusable until weekly resets
        if weekly.isExhausted { return -1 }

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

        // Weight weekly remaining — low weekly is a significant penalty
        s += weekly.remainingPercent * 0.3

        // Penalize accounts with very low weekly (< 20%) even if 5h is high
        if weekly.remainingPercent < 20 {
            s *= 0.5
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
        let verifiedPath = NSString("~/.codexswitch/sighup-verified").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: verifiedPath) else {
            logger.info("SIGHUP not verified by installed codex binary — skipping")
            SwapLog.append(.sighupSkipped(reason: "sighup-verified not found"))
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

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // pgrep -lf output: "PID command args..."
            // Only match actual codex binary, not CodexSwitch or editors
            guard trimmed.contains("/codex") || trimmed.hasSuffix(" codex") else { continue }
            guard !trimmed.contains("CodexSwitch") && !trimmed.contains("pgrep") else { continue }

            guard let pid = Int32(trimmed.split(separator: " ").first ?? "") else { continue }

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

        if signaled == 0 && skippedTooNew == 0 {
            logger.info("No codex CLI processes found to signal")
            SwapLog.append(.sighupSkipped(reason: "no codex processes found"))
        }
        logger.info("SIGHUP summary: signaled=\(signaled) skippedTooNew=\(skippedTooNew)")
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
