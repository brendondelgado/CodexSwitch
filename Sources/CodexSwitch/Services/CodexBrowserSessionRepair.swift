import Foundation

enum CodexBrowserSessionRepair {
    enum RepairResult: Equatable {
        case notNeeded(reason: String)
        case skipped(reason: String)
        case repaired(backupPath: String)
        case failed(String)
    }

    struct PartitionStatus: Equatable {
        let exists: Bool
        let isStale: Bool
        let newestModificationDate: Date?
        let ageSeconds: TimeInterval?
    }

    private static let defaultStaleAfter: TimeInterval = 7 * 24 * 60 * 60

    static var defaultPartitionPath: String {
        NSString("~/Library/Application Support/Codex/Partitions/codex-browser-app").expandingTildeInPath
    }

    static var defaultBackupRoot: String {
        NSString("~/.codexswitch/backups/codex-browser-app").expandingTildeInPath
    }

    static func stalePartitionStatus(
        partitionPath: String = defaultPartitionPath,
        now: Date = Date(),
        staleAfter: TimeInterval = defaultStaleAfter
    ) -> PartitionStatus {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: partitionPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return PartitionStatus(exists: false, isStale: false, newestModificationDate: nil, ageSeconds: nil)
        }

        guard let newestModificationDate = newestModificationDate(in: partitionPath) else {
            return PartitionStatus(exists: true, isStale: false, newestModificationDate: nil, ageSeconds: nil)
        }

        let ageSeconds = now.timeIntervalSince(newestModificationDate)
        return PartitionStatus(
            exists: true,
            isStale: ageSeconds >= staleAfter,
            newestModificationDate: newestModificationDate,
            ageSeconds: ageSeconds
        )
    }

    static func repairStalePartitionIfSafe(
        partitionPath: String = defaultPartitionPath,
        backupRoot: String = defaultBackupRoot,
        now: Date = Date(),
        staleAfter: TimeInterval = defaultStaleAfter,
        isCodexAppRunning: () -> Bool = { DesktopPatchManager.isCodexDesktopRuntimeRunning() }
    ) -> RepairResult {
        let status = stalePartitionStatus(
            partitionPath: partitionPath,
            now: now,
            staleAfter: staleAfter
        )
        guard status.exists else {
            return .notNeeded(reason: "partition_missing")
        }
        guard status.isStale else {
            return .notNeeded(reason: "partition_fresh")
        }
        guard !isCodexAppRunning() else {
            return .skipped(reason: "codex_app_running")
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                atPath: backupRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let backupPath = uniqueBackupPath(root: backupRoot, now: now)
            try fileManager.createDirectory(
                atPath: backupPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let destination = (backupPath as NSString).appendingPathComponent("codex-browser-app")
            try fileManager.moveItem(atPath: partitionPath, toPath: destination)
            return .repaired(backupPath: destination)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func newestModificationDate(in path: String) -> Date? {
        let fileManager = FileManager.default
        var newest: Date?

        func observe(_ candidatePath: String) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: candidatePath),
                  let modificationDate = attributes[.modificationDate] as? Date
            else {
                return
            }
            if newest.map({ modificationDate > $0 }) ?? true {
                newest = modificationDate
            }
        }

        observe(path)
        guard let enumerator = fileManager.enumerator(
            atPath: path
        ) else {
            return newest
        }
        for case let relativePath as String in enumerator {
            observe((path as NSString).appendingPathComponent(relativePath))
        }
        return newest
    }

    private static func uniqueBackupPath(root: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = (root as NSString).appendingPathComponent(formatter.string(from: now))

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: base) else {
            return base
        }

        var attempt = 1
        while true {
            let candidate = "\(base)-\(attempt)"
            if !fileManager.fileExists(atPath: candidate) {
                return candidate
            }
            attempt += 1
        }
    }
}
