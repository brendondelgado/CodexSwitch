import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex browser session repair")
struct CodexBrowserSessionRepairTests {
    @Test("Old codex browser partition is stale")
    func oldPartitionIsStale() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let partition = root.appendingPathComponent("codex-browser-app")
        try makePartition(at: partition)

        let now = Date(timeIntervalSince1970: 2_000_000)
        try setModificationDate(now.addingTimeInterval(-8 * 24 * 60 * 60), under: partition)

        let status = CodexBrowserSessionRepair.stalePartitionStatus(
            partitionPath: partition.path,
            now: now
        )

        #expect(status.exists)
        #expect(status.isStale)
    }

    @Test("Fresh codex browser partition is not stale")
    func freshPartitionIsNotStale() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let partition = root.appendingPathComponent("codex-browser-app")
        try makePartition(at: partition)

        let now = Date(timeIntervalSince1970: 2_000_000)
        try setModificationDate(now.addingTimeInterval(-60 * 60), under: partition)

        let status = CodexBrowserSessionRepair.stalePartitionStatus(
            partitionPath: partition.path,
            now: now
        )

        #expect(status.exists)
        #expect(!status.isStale)
    }

    @Test("Repair backs up stale partition when Codex is not running")
    func repairBacksUpStalePartition() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let partition = root.appendingPathComponent("codex-browser-app")
        let backupRoot = root.appendingPathComponent("backups")
        try makePartition(at: partition)

        let now = Date(timeIntervalSince1970: 2_000_000)
        try setModificationDate(now.addingTimeInterval(-8 * 24 * 60 * 60), under: partition)

        let result = CodexBrowserSessionRepair.repairStalePartitionIfSafe(
            partitionPath: partition.path,
            backupRoot: backupRoot.path,
            now: now,
            isCodexAppRunning: { false }
        )

        guard case .repaired(let backupPath) = result else {
            Issue.record("Expected repair, got \(result)")
            return
        }

        #expect(!FileManager.default.fileExists(atPath: partition.path))
        #expect(FileManager.default.fileExists(atPath: backupPath))
        #expect(FileManager.default.fileExists(atPath: (backupPath as NSString).appendingPathComponent("Cookies")))
    }

    @Test("Repair defers while Codex is running")
    func repairDefersWhileCodexIsRunning() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let partition = root.appendingPathComponent("codex-browser-app")
        let backupRoot = root.appendingPathComponent("backups")
        try makePartition(at: partition)

        let now = Date(timeIntervalSince1970: 2_000_000)
        try setModificationDate(now.addingTimeInterval(-8 * 24 * 60 * 60), under: partition)

        let result = CodexBrowserSessionRepair.repairStalePartitionIfSafe(
            partitionPath: partition.path,
            backupRoot: backupRoot.path,
            now: now,
            isCodexAppRunning: { true }
        )

        #expect(result == .skipped(reason: "codex_app_running"))
        #expect(FileManager.default.fileExists(atPath: partition.path))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-browser-session-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePartition(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("cookie-db".utf8).write(to: url.appendingPathComponent("Cookies"))
        let localStorage = url.appendingPathComponent("Local Storage/leveldb")
        try FileManager.default.createDirectory(at: localStorage, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: localStorage.appendingPathComponent("000001.log"))
    }

    private func setModificationDate(_ date: Date, under root: URL) throws {
        let fileManager = FileManager.default
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
        }
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
    }
}
