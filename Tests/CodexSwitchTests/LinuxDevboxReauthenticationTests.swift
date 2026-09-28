import Foundation
import Testing
@testable import CodexSwitch

@Suite("Targeted reauthentication delivery")
struct LinuxDevboxReauthenticationTests {
    @Test("An acknowledgement cannot erase a newer reauthentication")
    func staleAcknowledgement() {
        let pending = ["account": "new", "unrelated": "other"]
        #expect(LinuxDevboxReauthentication.acknowledge(
            pending, accountID: "account", fingerprint: "old"
        ) == pending)
        #expect(LinuxDevboxReauthentication.acknowledge(
            pending, accountID: "account", fingerprint: "new"
        ) == ["unrelated": "other"])
    }

    @Test("Pending metadata survives a defaults reload without storing tokens")
    func durableQueue() throws {
        let suite = "reauth-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = [UUID().uuidString: String(repeating: "a", count: 64)]
        defaults.set(queue, forKey: LinuxDevboxReauthentication.queueKey)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(reopened.dictionary(forKey: LinuxDevboxReauthentication.queueKey) as? [String: String] == queue)
    }

    @Test("A private input file reaches the child without command-line credentials")
    func privateStandardInput() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("synthetic-credential".utf8).write(to: path)
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        try FileManager.default.removeItem(at: path)
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/cat"), timeout: 3,
            standardInput: handle
        )
        #expect(result.terminationStatus == 0)
        #expect(result.stdoutString == "synthetic-credential")
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}
