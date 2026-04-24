import Foundation
import Darwin.POSIX
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "SwapEngine")

enum SwapEngine {
    private static let codexAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath
    private static let proCapacityMultiplier = 6.7
    private static let proThroughputBonus = 15.0
    private static let freeCapacityMultiplier = 0.1
    private static let freeThroughputPenalty = -20.0

    struct SighupProcessSnapshot: Equatable {
        let pid: Int32
        let commandLine: String
        let executablePath: String
        let controllingTTYDevice: UInt32
        let terminalProcessGroup: UInt32
        let startTime: Date
    }

    private static func normalizedPlanType(for account: CodexAccount) -> String? {
        account.planType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func planCapacityMultiplier(for account: CodexAccount) -> Double {
        switch normalizedPlanType(for: account) {
        case "pro":
            return proCapacityMultiplier
        case "free":
            return freeCapacityMultiplier
        default:
            return 1.0
        }
    }

    private static func planThroughputBonus(for account: CodexAccount) -> Double {
        switch normalizedPlanType(for: account) {
        case "pro":
            return proThroughputBonus
        case "free":
            return freeThroughputPenalty
        default:
            return 0
        }
    }

    /// Score an account for swap eligibility. Higher = better candidate.
    /// Returns -1 for ineligible accounts (no data, both windows exhausted).
    static func score(_ account: CodexAccount) -> Double {
        guard let snapshot = account.quotaSnapshot else { return -1 }
        let fiveHr = snapshot.fiveHour
        let weekly = snapshot.weekly
        let capacityMultiplier = planCapacityMultiplier(for: account)
        let throughputBonus = planThroughputBonus(for: account)

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
            var score = proximity * 15 + weekly.remainingPercent * 0.1 + throughputBonus
            if weekly.remainingPercent < 20 {
                score *= 0.5
            }
            return score
        }

        // Primary: 5-hour remaining, normalized by effective plan capacity.
        // Pro accounts are more valuable because they have materially more runway
        // and faster inference, so modestly lower percentages should still win.
        var s = fiveHr.remainingPercent * capacityMultiplier

        // Weight weekly remaining — low weekly is a significant penalty
        s += weekly.remainingPercent * 0.3
        s += throughputBonus

        // Penalize accounts with very low weekly (< 20%) even if 5h is high
        if weekly.remainingPercent < 20 {
            s *= 0.5
        }

        return max(0.1, s)
    }

    /// Select the best account to swap to from candidates (excluding currently active)
    static func selectOptimalAccount(from accounts: [CodexAccount]) -> CodexAccount? {
        accounts
            .filter { !$0.isActive }
            .filter { score($0) > 0 }
            .max { score($0) < score($1) }
    }

    /// Decide whether the current active account should yield to a candidate.
    /// We still swap immediately for exhausted/invalid active accounts, but we
    /// also allow a better Pro account to reclaim the active slot from a Plus
    /// account because Pro offers materially better throughput and runway.
    static func shouldSwap(
        from active: CodexAccount,
        to candidate: CodexAccount,
        manualOverrideAccountId: UUID? = nil
    ) -> Bool {
        guard active.id != candidate.id else { return false }
        guard let candidateSnapshot = candidate.quotaSnapshot,
              !candidateSnapshot.fiveHour.isExhausted,
              !candidateSnapshot.weekly.isExhausted else {
            return false
        }

        let activeSnapshot = active.quotaSnapshot
        let activeExhausted = activeSnapshot.map { $0.fiveHour.isExhausted || $0.weekly.isExhausted } ?? false
        if activeExhausted || score(active) <= 0 {
            return true
        }

        if manualOverrideAccountId == active.id {
            return false
        }

        let candidateScore = score(candidate)
        let activeScore = score(active)
        guard candidateScore > activeScore else { return false }

        return normalizedPlanType(for: candidate) == "pro"
            && normalizedPlanType(for: active) != "pro"
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
        if normalizedPlanType(for: candidate) == "pro" {
            lines.append("Pro plan preferred for higher capacity and faster inference")
        } else if normalizedPlanType(for: candidate) == "free" {
            lines.append("Free plan deprioritized because limits are much lower")
        }

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
    /// Only sends if the current install is known to support SIGHUP — either
    /// via runtime verification markers written by the fork or via a matching
    /// recorded patched-install state.
    static func shouldSignalCodexProcess(
        _ process: SighupProcessSnapshot,
        now: Date = Date(),
        minAge: TimeInterval = 10
    ) -> Bool {
        guard process.controllingTTYDevice != 0, process.terminalProcessGroup != 0 else {
            return false
        }

        guard now.timeIntervalSince(process.startTime) >= minAge else {
            return false
        }

        let executablePath = process.executablePath.lowercased()
        let executableName = URL(fileURLWithPath: process.executablePath)
            .lastPathComponent
            .lowercased()

        guard executableName == "codex" || executableName.hasPrefix("codex-") else {
            return false
        }

        guard !executablePath.contains(".app/contents/") else {
            return false
        }

        return true
    }

    static func signalCodexReload() {
        let install = CodexInstallLocator.locate()
        let currentVersion = CodexInstallLocator.currentVersion()
        let hasVerifiedMarker = CodexSighupMarkers.hasVerifiedMarker()
        let hasMatchingPatchedState = install.map {
            CodexPatchStateStore.matchesCurrentInstall(
                currentVersion: currentVersion,
                currentInstall: $0
            )
        } ?? false

        guard hasVerifiedMarker || hasMatchingPatchedState else {
            logger.info("SIGHUP not verified by installed codex binary — skipping")
            SwapLog.append(.sighupSkipped(reason: "sighup verification markers not found"))
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
        var skippedIneligible = 0

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let pid = Int32(trimmed.split(separator: " ").first ?? "") else { continue }
            guard let snapshot = sighupProcessSnapshot(pid: pid, commandLine: trimmed) else {
                skippedIneligible += 1
                continue
            }

            if now.timeIntervalSince(snapshot.startTime) < minAge {
                skippedTooNew += 1
                logger.info("Skipping pid \(pid) — started <10s ago")
                SwapLog.append(.sighupSkipped(reason: "pid \(pid) started <10s ago"))
                continue
            }

            guard shouldSignalCodexProcess(snapshot, now: now, minAge: minAge) else {
                skippedIneligible += 1
                continue
            }

            kill(snapshot.pid, SIGHUP)
            signaled += 1
            logger.info("SIGHUP → pid \(snapshot.pid)")
            SwapLog.append(.sighupSent(pid: snapshot.pid, startedAt: ""))
        }

        if signaled == 0 && skippedTooNew == 0 && skippedIneligible == 0 {
            logger.info("No codex-related processes found to inspect")
            SwapLog.append(.sighupSkipped(reason: "no codex processes found"))
        } else if signaled == 0 {
            logger.info("No eligible interactive codex CLI processes found to signal")
            SwapLog.append(.sighupSkipped(reason: "no eligible codex cli processes found"))
        }
        logger.info("SIGHUP summary: signaled=\(signaled) skippedTooNew=\(skippedTooNew) skippedIneligible=\(skippedIneligible)")
    }

    private static func sighupProcessSnapshot(
        pid: Int32,
        commandLine: String
    ) -> SighupProcessSnapshot? {
        var info = proc_bsdinfo()
        let infoSize = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard infoSize == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            return nil
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathSize = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathSize > 0 else {
            return nil
        }

        let pathLength = pathBuffer.firstIndex(of: 0) ?? Int(pathSize)
        let path = String(
            decoding: pathBuffer.prefix(pathLength).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let startTime = Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                + (TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        )

        return SighupProcessSnapshot(
            pid: pid,
            commandLine: commandLine,
            executablePath: path,
            controllingTTYDevice: info.e_tdev,
            terminalProcessGroup: info.e_tpgid,
            startTime: startTime
        )
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
