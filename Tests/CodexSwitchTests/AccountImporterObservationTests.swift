import Darwin
import Foundation
import Testing
@testable import CodexSwitch

@Suite("External auth observation")
struct AccountImporterObservationTests {
    @Test("Raw relative dot traversal and NUL paths are rejected before standardization")
    func lexicalTraversalPathsFailClosed() {
        let unsafePaths = [
            "relative/auth.json",
            ".",
            "..",
            "/tmp/../auth.json",
            "/tmp/./auth.json",
            "/tmp//auth.json",
            "/tmp/auth\0.json",
        ]

        for path in unsafePaths {
            guard case .invalid(.unsafeAncestor) = AccountImporter.observeCurrentAccount(
                from: path
            ) else {
                Issue.record("Expected unsafe raw path rejection for \(String(reflecting: path))")
                continue
            }
        }
    }

    @Test("Absent auth is distinct from invalid and unreadable auth")
    func typedAbsenceAndUnreadableOutcomes() throws {
        let root = try makeSecureTestDirectoryURL(prefix: "codexswitch-auth-observation")
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("missing.json")
        guard case .absent = AccountImporter.observeCurrentAccount(from: absent.path) else {
            Issue.record("Expected an absent observation")
            return
        }

        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blockingFile)
        chmod(blockingFile.path, 0o600)
        let child = blockingFile.appendingPathComponent("auth.json")
        guard case .unreadable(.readFailed) = AccountImporter.observeCurrentAccount(
            from: child.path
        ) else {
            Issue.record("Expected an unreadable observation")
            return
        }
    }

    @Test("Valid secure auth is decoded without promoting it")
    func validSecureAuthObservation() throws {
        let url = try temporaryAuthURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuth(to: url)

        guard case .valid(let account) = AccountImporter.observeCurrentAccount(
            from: url.path
        ) else {
            Issue.record("Expected valid auth")
            return
        }
        #expect(account.accountId == "provider-account")
        #expect(account.accessToken == "access")
        #expect(!account.isActive)
    }

    @Test("Corrupt wrong-mode and symlinked auth fail closed")
    func invalidAuthOutcomes() throws {
        let url = try temporaryAuthURL()
        let root = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("not-json".utf8).write(to: url)
        chmod(url.path, 0o600)
        guard case .invalid(.malformed) = AccountImporter.observeCurrentAccount(from: url.path) else {
            Issue.record("Expected malformed auth rejection")
            return
        }

        try writeAuth(to: url)
        chmod(url.path, 0o644)
        guard case .invalid(.wrongMode) = AccountImporter.observeCurrentAccount(from: url.path) else {
            Issue.record("Expected wrong-mode auth rejection")
            return
        }

        chmod(url.path, 0o600)
        let link = root.appendingPathComponent("auth-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        guard case .invalid(.symlink) = AccountImporter.observeCurrentAccount(from: link.path) else {
            Issue.record("Expected symlink auth rejection")
            return
        }
    }

    @Test("Replacing an opened ancestor cannot redirect auth observation")
    func ancestorSwapFailsClosed() throws {
        let url = try temporaryAuthURL()
        let root = url.deletingLastPathComponent()
        let movedRoot = root.appendingPathExtension("opened")
        let attackerRoot = root.appendingPathExtension("attacker")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
            try? FileManager.default.removeItem(at: attackerRoot)
        }
        try writeAuth(to: url)
        try FileManager.default.createDirectory(at: attackerRoot, withIntermediateDirectories: true)
        chmod(attackerRoot.path, 0o700)
        try writeAuth(to: attackerRoot.appendingPathComponent("auth.json"))

        let observation = AccountImporter.observeCurrentAccount(
            from: url.path,
            testHooks: .init(afterOpeningAncestors: {
                try! FileManager.default.moveItem(at: root, to: movedRoot)
                try! FileManager.default.createSymbolicLink(
                    at: root,
                    withDestinationURL: attackerRoot
                )
            })
        )

        guard case .invalid(.ancestorChanged) = observation else {
            Issue.record("Expected an ancestor-rebinding rejection")
            return
        }
    }

    @Test("Unrelated ancestor directory content churn preserves a valid observation")
    func ancestorContentChurnRemainsValid() throws {
        let url = try temporaryAuthURL()
        let root = url.deletingLastPathComponent()
        let unrelated = root.appendingPathComponent("unrelated-session-write")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeAuth(to: url)

        let observation = AccountImporter.observeCurrentAccount(
            from: url.path,
            testHooks: .init(afterOpeningAncestors: {
                try! Data("unrelated".utf8).write(to: unrelated)
            })
        )

        guard case .valid(let account) = observation else {
            Issue.record("Unrelated directory churn must not invalidate auth identity")
            return
        }
        #expect(account.accountId == "provider-account")
    }

    @Test("A concurrent auth rewrite invalidates the descriptor read")
    func concurrentRewriteFailsClosed() throws {
        let url = try temporaryAuthURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuth(to: url)
        let replacement = try encodedAuth(
            accountId: "provider-account-rewritten",
            accessToken: "replacement-access"
        )

        let observation = AccountImporter.observeCurrentAccount(
            from: url.path,
            testHooks: .init(afterReadingBeforeProof: {
                try! replacement.write(to: url, options: .atomic)
                chmod(url.path, 0o600)
            })
        )

        guard case .invalid(.changedDuringRead) = observation else {
            Issue.record("Expected a concurrent-rewrite rejection")
            return
        }
    }

    private func temporaryAuthURL() throws -> URL {
        try makeSecureTestDirectoryURL(prefix: "codexswitch-auth-observation")
            .appendingPathComponent("auth.json")
    }

    private func writeAuth(to url: URL) throws {
        try encodedAuth().write(to: url)
        chmod(url.path, 0o600)
    }

    private func encodedAuth(
        accountId: String = "provider-account",
        accessToken: String = "access"
    ) throws -> Data {
        let auth = AuthFile(
            authMode: "chatgpt",
            openaiApiKey: nil,
            tokens: AuthTokens(
                idToken: "id",
                accessToken: accessToken,
                refreshToken: "refresh",
                accountId: accountId
            ),
            lastRefresh: "2026-07-13T00:00:00Z"
        )
        return try JSONEncoder().encode(auth)
    }
}
