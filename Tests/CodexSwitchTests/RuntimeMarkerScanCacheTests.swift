import Darwin
import Foundation
import Testing
@testable import CodexSwitch

struct RuntimeMarkerScanCacheTests {
    @Test(arguments: [true, false])
    func unchangedFilesScanOnlyOnce(expected: Bool) throws {
        try withFixture { url in
            let cache = RuntimeMarkerScanCache()
            var scans = 0
            for _ in 0..<100 {
                #expect(cache.result(at: url.path, chunkSize: 17) { _ in
                    scans += 1
                    return expected
                } == expected)
            }
            #expect(scans == 1)
        }
    }

    @Test func mutationWithRestoredModificationTimeInvalidates() throws {
        try withFixture { url in
            let cache = RuntimeMarkerScanCache()
            let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]!
            #expect(cache.result(at: url.path, chunkSize: 17) { _ in true })
            let writer = try FileHandle(forWritingTo: url)
            try writer.write(contentsOf: Data("changed".utf8))
            try writer.close()
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            var rescanned = false
            #expect(!cache.result(at: url.path, chunkSize: 17) { _ in
                rescanned = true
                return false
            })
            #expect(rescanned)
        }
    }

    @Test func atomicReplacementAndPermissionChangesInvalidate() throws {
        try withFixture { url in
            let cache = RuntimeMarkerScanCache()
            #expect(cache.result(at: url.path, chunkSize: 17) { _ in true })
            try Data("fixture".utf8).write(to: url, options: .atomic)
            #expect(!cache.result(at: url.path, chunkSize: 17) { _ in false })
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            #expect(cache.result(at: url.path, chunkSize: 17) { _ in true })
        }
    }

    @Test func mutationDuringScanFailsClosedAndIsNotCached() throws {
        try withFixture { url in
            let cache = RuntimeMarkerScanCache()
            #expect(!cache.result(at: url.path, chunkSize: 17) { _ in
                try! Data("replacement".utf8).write(to: url, options: .atomic)
                return true
            })
            var rescanned = false
            #expect(cache.result(at: url.path, chunkSize: 17) { _ in
                rescanned = true
                return true
            })
            #expect(rescanned)
        }
    }

    @Test func missingLinkedAndNonregularPathsNeverUseCachedSuccess() throws {
        try withFixture { url in
            let cache = RuntimeMarkerScanCache()
            #expect(cache.result(at: url.path, chunkSize: 17) { _ in true })
            try FileManager.default.removeItem(at: url)
            #expect(!cache.result(at: url.path, chunkSize: 17) { _ in true })
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/dev/null")
            #expect(!cache.result(at: url.path, chunkSize: 17) { _ in true })
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            #expect(!cache.result(at: url.path, chunkSize: 17) { _ in true })
        }
    }

    @Test func readFailureAndInvalidChunkSizeAreNotCached() throws {
        try withFixture { url in
            let cache = RuntimeMarkerScanCache()
            #expect(!cache.result(at: url.path, chunkSize: 0) { _ in true })
            #expect(!cache.result(at: url.path, chunkSize: 17) { _ in nil })
            #expect(cache.result(at: url.path, chunkSize: 17) { _ in true })
        }
    }

    @Test func cacheIsBoundedAndScanConfigurationIsPartOfKey() throws {
        try withFixture { url in
            let cache = RuntimeMarkerScanCache(capacity: 2)
            for size in [1, 2, 3] {
                #expect(cache.result(at: url.path, chunkSize: size) { _ in true })
            }
            var scans = 0
            #expect(cache.result(at: url.path, chunkSize: 2) { _ in scans += 1; return true })
            #expect(cache.result(at: url.path, chunkSize: 1) { _ in scans += 1; return true })
            #expect(scans == 1)
        }
    }

    @Test func markerIdentityIsPartOfKey() throws {
        try withFixture { url in
            let cache = RuntimeMarkerScanCache()
            #expect(cache.result(at: url.path, marker: "present", chunkSize: 17) { _ in true })
            #expect(!cache.result(at: url.path, marker: "absent", chunkSize: 17) { _ in false })
        }
    }

    @Test(arguments: [1, 2, 7, 16, 64])
    func desktopScannerHandlesLongOverlappingAndUTF8Markers(chunkSize: Int) throws {
        try withFixture { url in
            let marker = "aaaaabbbbaaaaab\u{00E9}"
            try Data((String(repeating: "a", count: 67) + marker + "tail").utf8).write(to: url)
            #expect(DesktopPatchManager.fileContainsMarker(marker, at: url.path, chunkSize: chunkSize))
            #expect(!DesktopPatchManager.fileContainsMarker("aaaaabbbbaaaaac", at: url.path, chunkSize: chunkSize))
            #expect(!DesktopPatchManager.fileContainsMarker("", at: url.path, chunkSize: chunkSize))
            try Data("plain replacement".utf8).write(to: url)
            #expect(!DesktopPatchManager.fileContainsMarker(marker, at: url.path, chunkSize: chunkSize))
        }
    }

    @Test func concurrentChecksShareOneScan() throws {
        try withFixture { url in
            let cache = RuntimeMarkerScanCache()
            let count = ScanCount()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                #expect(cache.result(at: url.path, chunkSize: 17) { _ in
                    count.increment()
                    Thread.sleep(forTimeInterval: 0.01)
                    return true
                })
            }
            #expect(count.value == 1)
        }
    }

    @Test func optionalInstalledRuntimeBenchmark() {
        guard let path = ProcessInfo.processInfo.environment["CODEXSWITCH_RUNTIME_SCAN_BENCHMARK"] else {
            return
        }
        let start = Date()
        let result = CodexVersionChecker.binaryFileHasRequiredRuntimeMarkers(at: path)
        let cold = Date().timeIntervalSince(start)
        let warmStart = Date()
        for _ in 0..<100 {
            #expect(CodexVersionChecker.binaryFileHasRequiredRuntimeMarkers(at: path) == result)
        }
        let warm = Date().timeIntervalSince(warmStart)
        print("Runtime marker benchmark: cold=\(cold)s, 100 cached=\(warm)s, result=\(result)")
    }

    @Test func optionalInstalledDesktopBenchmark() {
        guard let path = ProcessInfo.processInfo.environment["CODEXSWITCH_DESKTOP_SCAN_BENCHMARK"] else {
            return
        }
        let start = Date()
        let result = DesktopPatchManager.authPatchMarkersPresent(at: path)
        let cold = Date().timeIntervalSince(start)
        let warmStart = Date()
        for _ in 0..<100 {
            #expect(DesktopPatchManager.authPatchMarkersPresent(at: path) == result)
        }
        print("Desktop marker benchmark: cold=\(cold)s, 100 cached=\(Date().timeIntervalSince(warmStart))s, result=\(result)")
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("runtime")
        try Data("fixture".utf8).write(to: url)
        try body(url)
    }

    private final class ScanCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
}
