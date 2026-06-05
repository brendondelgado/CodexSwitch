import Foundation
import Darwin.POSIX
import os

private let logger = Logger(subsystem: "com.codexswitch", category: "SwapEngine")

private final class ExecutableHotSwapSupportCache: @unchecked Sendable {
    private struct Entry {
        let modifiedAt: Date?
        let supportsHotSwap: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func get(path: String, modifiedAt: Date?) -> Bool? {
        lock.withLock {
            guard let entry = entries[path],
                  entry.modifiedAt == modifiedAt else {
                return nil
            }
            return entry.supportsHotSwap
        }
    }

    func set(path: String, modifiedAt: Date?, supportsHotSwap: Bool) {
        lock.withLock {
            entries[path] = Entry(modifiedAt: modifiedAt, supportsHotSwap: supportsHotSwap)
        }
    }
}

enum SwapEngine {
    private static let codexAuthPath = NSString("~/.codex/auth.json").expandingTildeInPath
    private static let resetTieFiveHourTolerance = 2.0
    private static let resetTieWeeklyTolerance = 5.0
    private nonisolated static let hotSwapSupportCache = ExecutableHotSwapSupportCache()

    /// Score an account for swap eligibility. Higher = better candidate.
    /// Returns -1 for ineligible accounts (no data, both windows exhausted).
    static func score(_ account: CodexAccount) -> Double {
        guard let snapshot = account.realQuotaSnapshot else { return -1 }
        let fiveHr = snapshot.fiveHour
        let weekly = snapshot.weekly

        guard !snapshot.hasExpiredExhaustedWindow() else {
            return -1
        }

        // HARD EXCLUSION: Weekly exhausted = completely unusable until weekly resets
        if weekly.isExhausted { return -1 }

        let planBase = planPriorityBase(for: account)

        // 5h exhausted but weekly has capacity — score by time until 5h resets.
        // Closer to reset = higher score. An account resetting in 10 min is much
        // better than one resetting in 4 hours, but both are valid candidates.
        if fiveHr.isExhausted {
            let hoursUntilReset = max(0, fiveHr.timeUntilReset / 3600)
            let maxHours: Double = 5  // 5h window duration
            // proximity: 1.0 when resetting now → 0.0 when resetting in 5h
            let proximity = max(0, 1 - (hoursUntilReset / maxHours))
            return planBase + proximity * 100 + weekly.remainingPercent * 0.3
        }

        // Primary: 5-hour remaining (0-100)
        var s = planBase + fiveHr.remainingPercent

        // Weight weekly remaining — low weekly is a significant penalty
        s += weekly.remainingPercent * 0.3

        // Penalize accounts with very low weekly (< 20%) even if 5h is high
        if weekly.remainingPercent < 20 {
            s -= 50
        }

        return s
    }

    static func isImmediatelyUsable(_ account: CodexAccount) -> Bool {
        guard let snapshot = account.realQuotaSnapshot else { return false }
        return score(account) > 0
            && !snapshot.fiveHour.shouldAutoSwapAway
            && !snapshot.weekly.shouldAutoSwapAway
    }

    private static func planPriorityBase(for account: CodexAccount) -> Double {
        switch account.planPriority {
        case 4:
            return 15_000 // Pro: fastest inference and largest allowance
        case 3:
            return 10_000 // Pro Lite: above Plus, below full Pro
        case 2:
            return 5_000 // Plus/team/business: normal paid working pool
        default:
            return 100 // Free: usable only after paid accounts are spent/resetting
        }
    }

    /// Select the best account to swap to from candidates (excluding currently active)
    static func selectOptimalAccount(from accounts: [CodexAccount]) -> CodexAccount? {
        accounts
            .filter { !$0.isActive }
            .filter { isImmediatelyUsable($0) }
            .reduce(nil) { best, account in
                guard let best else { return account }
                return isBetterCandidate(account, than: best) ? account : best
            }
    }

    /// Select a target for automatic failover. Unlike manual selection, this
    /// excludes accounts that are themselves close enough to depletion that they
    /// would immediately trigger another auto-swap.
    static func selectAutoSwapCandidate(from accounts: [CodexAccount]) -> CodexAccount? {
        accounts
            .filter { !$0.isActive }
            .filter { account in
                isImmediatelyUsable(account)
            }
            .reduce(nil) { best, account in
                guard let best else { return account }
                return isBetterCandidate(account, than: best) ? account : best
            }
    }

    /// Select a higher-tier account even when the active account still has
    /// quota. Pro accounts get the fastest inference, so a usable higher plan
    /// should not sit idle behind a healthy lower plan.
    static func selectPlanUpgradeCandidate(active: CodexAccount, from accounts: [CodexAccount]) -> CodexAccount? {
        accounts
            .filter { !$0.isActive && $0.id != active.id }
            .filter { $0.planPriority > active.planPriority }
            .filter { isImmediatelyUsable($0) }
            .reduce(nil) { best, account in
                guard let best else { return account }
                return isBetterCandidate(account, than: best) ? account : best
            }
    }

    static func earliestUsableReset(from accounts: [CodexAccount], now: Date = Date()) -> Date? {
        accounts
            .compactMap { account -> Date? in
                guard let snapshot = account.realQuotaSnapshot else { return nil }
                let resetCandidates = [
                    snapshot.fiveHour.shouldAutoSwapAway ? snapshot.fiveHour.resetsAt : nil,
                    snapshot.weekly.shouldAutoSwapAway ? snapshot.weekly.resetsAt : nil,
                ].compactMap { $0 }
                return resetCandidates.filter { $0 > now }.min()
            }
            .min()
    }

    private static func isBetterCandidate(_ left: CodexAccount, than right: CodexAccount) -> Bool {
        if shouldUseFiveHourResetTieBreaker(left, right) {
            let leftReset = left.realQuotaSnapshot!.fiveHour.resetsAt
            let rightReset = right.realQuotaSnapshot!.fiveHour.resetsAt
            if leftReset != rightReset {
                return leftReset < rightReset
            }
        }
        return score(left) > score(right)
    }

    private static func shouldUseFiveHourResetTieBreaker(_ left: CodexAccount, _ right: CodexAccount) -> Bool {
        guard left.planPriority == right.planPriority,
              let leftSnapshot = left.realQuotaSnapshot,
              let rightSnapshot = right.realQuotaSnapshot else {
            return false
        }

        return abs(leftSnapshot.fiveHour.remainingPercent - rightSnapshot.fiveHour.remainingPercent) <= resetTieFiveHourTolerance
            && abs(leftSnapshot.weekly.remainingPercent - rightSnapshot.weekly.remainingPercent) <= resetTieWeeklyTolerance
    }

    /// Explain why a candidate was selected as next-up over alternatives
    static func explainSelection(candidate: CodexAccount, allAccounts: [CodexAccount]) -> String {
        guard let snapshot = candidate.realQuotaSnapshot else {
            return "Selected but no quota data available yet."
        }

        let fiveHr = snapshot.fiveHour
        let weekly = snapshot.weekly
        let candidateScore = score(candidate)

        var lines: [String] = []

        // Primary factor
        if !candidate.planLabel.isEmpty {
            lines.append("\(candidate.planLabel) priority")
        }
        lines.append("5h: \(Int(fiveHr.remainingPercent))% | Weekly: \(Int(weekly.remainingPercent))%")

        // Weekly status
        if weekly.remainingPercent < 20 {
            lines.append("⚠ Low weekly — score penalized")
        } else if weekly.remainingPercent < 50 {
            lines.append("Weekly at \(Int(weekly.remainingPercent))% — factored into score")
        }

        // Reset proximity info
        if !fiveHr.isExhausted {
            let mins = Int(max(0, fiveHr.timeUntilReset) / 60)
            lines.append("5h resets in \(mins / 60)h \(mins % 60)m")
        } else {
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

        if let runnerUp = others.first, let ruSnap = runnerUp.realQuotaSnapshot {
            let diff = Int(fiveHr.remainingPercent - ruSnap.fiveHour.remainingPercent)
            if shouldUseFiveHourResetTieBreaker(candidate, runnerUp), fiveHr.resetsAt < ruSnap.fiveHour.resetsAt {
                lines.append("Comparable quota — earlier 5h reset broke the tie")
            } else if diff > 0 {
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
    /// Only sends if a SIGHUP-capable binary wrote a verification marker.
    static func signalCodexReload() {
        guard Self.hasVerifiedSighupMarker() else {
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
        var skippedNoAck = 0

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // pgrep -lf output: "PID command args..."
            guard let pid = Int32(trimmed.split(separator: " ").first ?? "") else { continue }
            guard Self.shouldSignalCodexProcess(pid: pid, commandLine: trimmed) else { continue }

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

            let sentAt = Date()
            kill(pid, SIGHUP)
            if waitForHotSwapAck(pid: pid, since: sentAt) {
                signaled += 1
                logger.info("SIGHUP → pid \(pid) acknowledged")
                SwapLog.append(.sighupSent(pid: pid, startedAt: ""))
            } else {
                skippedNoAck += 1
                logger.info("Skipping pid \(pid) — SIGHUP sent but no live ack observed")
                SwapLog.append(.sighupSkipped(reason: "pid \(pid) did not acknowledge SIGHUP hot-swap"))
            }
        }

        if signaled == 0 && skippedTooNew == 0 && skippedNoAck == 0 {
            logger.info("No codex CLI processes found to signal")
            SwapLog.append(.sighupSkipped(reason: "no codex processes found"))
        }
        logger.info("SIGHUP summary: signaled=\(signaled) skippedTooNew=\(skippedTooNew) skippedNoAck=\(skippedNoAck)")
    }

    @discardableResult
    static func signalDesktopAppServerReload() -> Bool {
        guard Self.hasVerifiedSighupMarker() else {
            SwapLog.append(.desktopExternalReloadSkipped(reason: "sighup-verified not found"))
            return false
        }

        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-fl", "codex.*app-server"],
            timeout: 3
        )
        guard !result.timedOut, result.terminationStatus == 0 else {
            SwapLog.append(.desktopExternalReloadSkipped(reason: "desktop_app_server_not_found"))
            return false
        }

        let pids = desktopAppServerPIDsToSignal(from: result.stdoutString) { pid in
            codexProcessHasHotSwapSupport(pid: pid, logStaleProcess: true)
        }
        guard !pids.isEmpty else {
            SwapLog.append(.desktopExternalReloadSkipped(reason: "desktop_app_server_not_sighup_capable"))
            return false
        }

        var acknowledged = false
        for pid in pids {
            let sentAt = Date()
            kill(pid, SIGHUP)
            if waitForHotSwapAck(pid: pid, since: sentAt) {
                acknowledged = true
                logger.info("Desktop app-server SIGHUP → pid \(pid) acknowledged")
                SwapLog.append(.sighupSent(pid: pid, startedAt: "desktop-app-server"))
            } else {
                logger.info("Desktop app-server SIGHUP → pid \(pid) was not acknowledged")
                SwapLog.append(.desktopExternalReloadSkipped(reason: "pid \(pid) did not acknowledge SIGHUP hot-swap"))
            }
        }
        return acknowledged
    }

    nonisolated static func desktopAppServerPIDsToSignal(
        from pgrepOutput: String,
        hotSwapSupport: (Int32) -> Bool
    ) -> [Int32] {
        DesktopRuntimeDiagnostics
            .parseAppServerProcesses(fromPGrepOutput: pgrepOutput)
            .filter { $0.classification == .desktopAppServer && hotSwapSupport($0.pid) }
            .map(\.pid)
    }

    private static func hasVerifiedSighupMarker() -> Bool {
        let markerDir = NSString("~/.codexswitch").expandingTildeInPath
        let markerNames = [
            "sighup-verified",
            "sighup-verified-tui",
            "sighup-verified-exec",
        ]
        return markerNames.contains { name in
            FileManager.default.fileExists(
                atPath: (markerDir as NSString).appendingPathComponent(name)
            )
        }
    }

    private static func shouldSignalCodexProcess(pid: Int32, commandLine: String) -> Bool {
        guard !commandLine.contains("CodexSwitch"),
              !commandLine.contains("pgrep"),
              !commandLine.contains(" app-server"),
              !commandLine.contains("codex_chronicle") else {
            return false
        }
        guard !commandLineIsUnsafeCodexSighupTarget(commandLine) else {
            SwapLog.append(.sighupSkipped(reason: "pid \(pid) is a terminal/SSH wrapper; restart instead of SIGHUP"))
            return false
        }

        guard codexProcessHasHotSwapSupport(pid: pid, logStaleProcess: true) else { return false }

        return true
    }

    nonisolated static func commandLineIsUnsafeCodexSighupTarget(_ commandLine: String) -> Bool {
        let lower = commandLine.lowercased()
        return lower.contains("codex-vps")
            || lower.contains("signul_canary_actor=codex-vps")
            || lower.contains(" --remote ")
            || lower.contains("/bin/zsh")
            || lower.contains(" zsh ")
            || lower.contains("/bin/bash")
            || lower.contains(" bash ")
            || lower.contains("/usr/bin/ssh")
            || lower.contains(" ssh ")
    }

    private static func waitForHotSwapAck(pid: Int32, since: Date) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if DesktopPatchManager.desktopHotSwapAckExists(pid: pid, since: since) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    nonisolated static func codexProcessHotSwapAckExists(pid: Int32) -> Bool {
        DesktopPatchManager.desktopHotSwapAckExists(pid: pid)
    }

    nonisolated static func codexProcessHasHotSwapSupport(
        pid: Int32,
        logStaleProcess: Bool = false
    ) -> Bool {
        guard let executable = executablePath(for: pid) else { return false }
        guard (executable as NSString).lastPathComponent.lowercased().contains("codex") else {
            return false
        }
        if let executableModifiedAt = executableModificationDate(executable),
           let processStartedAt = processStartDate(pid: pid),
           executableModifiedAt.timeIntervalSince(processStartedAt) > 1 {
            if logStaleProcess {
                SwapLog.append(.sighupSkipped(reason: "pid \(pid) started before hot-swap patch; restart CLI session"))
            }
            return false
        }
        return executableHasSighupSupport(executable)
    }

    private nonisolated static func executableHasSighupSupport(_ path: String) -> Bool {
        let modifiedAt = executableModificationDate(path)
        if let cached = hotSwapSupportCache.get(path: path, modifiedAt: modifiedAt) {
            return cached
        }

        let supportsHotSwap = DesktopPatchManager.fileContainsMarker("sighup-verified", at: path)
            && DesktopPatchManager.fileContainsMarker("SIGHUP: auth reloaded", at: path)
            && DesktopPatchManager.fileContainsMarker("hotswap-ack", at: path)
            && DesktopPatchManager.fileContainsMarker("CodexSwitch rotated accounts after a usage limit", at: path)
        hotSwapSupportCache.set(path: path, modifiedAt: modifiedAt, supportsHotSwap: supportsHotSwap)
        return supportsHotSwap
    }

    private nonisolated static func executableModificationDate(_ path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }

    private nonisolated static func processStartDate(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    private nonisolated static func executablePath(for pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro that Swift may not import on
        // newer SDKs. 4096 is the documented 4 * MAXPATHLEN value.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
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
