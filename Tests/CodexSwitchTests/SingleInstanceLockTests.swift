import Foundation
import Testing
@testable import CodexSwitch

@Suite("SingleInstanceLock")
struct SingleInstanceLockTests {
    @Test("Second lock cannot acquire until first releases")
    func secondLockCannotAcquireUntilFirstReleases() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswitch-single-instance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("app.lock").path
        let first = SingleInstanceLock(path: path)
        let second = SingleInstanceLock(path: path)

        #expect(first.acquire(pid: 111))
        #expect(!second.acquire(pid: 222))

        first.release()

        #expect(second.acquire(pid: 222))
    }
}
