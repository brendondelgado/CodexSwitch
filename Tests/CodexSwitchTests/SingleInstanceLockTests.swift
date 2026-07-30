import Foundation
import Testing
@testable import CodexSwitch

@Suite("SingleInstanceLock")
struct SingleInstanceLockTests {
    @Test("Only the primary instance may start services or flush persistence")
    func instanceRoleGatesAllCoordinatorEffects() {
        let primary = CodexSwitchInstanceRole.resolve(lockAcquired: true)
        let duplicate = CodexSwitchInstanceRole.resolve(lockAcquired: false)

        #expect(primary == .primary)
        #expect(primary.mayStartServices)
        #expect(primary.requiresTerminationPersistence)
        #expect(duplicate == .duplicate)
        #expect(!duplicate.mayStartServices)
        #expect(!duplicate.requiresTerminationPersistence)
    }

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

    @Test("App acquires ownership before finish-launch services")
    func appAcquiresOwnershipBeforeServices() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )
        let willStart = try #require(source.range(of: "func applicationWillFinishLaunching("))
        let didStart = try #require(source.range(of: "func applicationDidFinishLaunching("))
        let willBody = source[willStart.lowerBound..<didStart.lowerBound]
        let didEnd = try #require(
            source.range(
                of: "private func reconcileExternalAuthIfNeeded()",
                range: didStart.upperBound..<source.endIndex
            )
        )
        let didBody = source[didStart.lowerBound..<didEnd.lowerBound]

        #expect(willBody.contains("singleInstanceLock.acquire()"))
        #expect(didBody.contains("instanceRole.mayStartServices"))
        #expect(!didBody.contains("singleInstanceLock.acquire()"))
    }
}
