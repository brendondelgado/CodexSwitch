import Darwin
import Foundation
import Testing
@testable import CodexSwitch

@Suite("Secure atomic file transaction")
struct SecureAtomicFileTransactionTests {
    @Test("Contended lock times out without mutation and later recovers")
    func contendedLockIsBoundedAndRecoverable() throws {
        let url = makeSecureTestFileURL(
            prefix: "codexswitch-lock-timeout",
            fileName: "state.json"
        )
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let initial = Data("initial".utf8)
        let replacement = Data("replacement".utf8)
        let transaction = SecureAtomicFileTransaction(
            path: url.path,
            lockAcquisitionTimeout: 0.05,
            lockRetryInterval: 0.005
        )
        try transaction.withExclusiveLock { lockedFile in
            _ = try lockedFile.replace(
                initial,
                expectedGeneration: try lockedFile.read().generation
            )
        }

        let lockPath = directory.appendingPathComponent("state.json.lock").path
        let heldDescriptor = Darwin.open(lockPath, O_RDWR | O_CLOEXEC)
        guard heldDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            _ = flock(heldDescriptor, LOCK_UN)
            Darwin.close(heldDescriptor)
        }
        guard flock(heldDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            try transaction.withExclusiveLock { lockedFile in
                _ = try lockedFile.replace(
                    replacement,
                    expectedGeneration: try lockedFile.read().generation
                )
            }
            Issue.record("Expected bounded lock timeout")
        } catch let error as SecureAtomicFileError {
            guard case .lockTimedOut(let path, let timeout) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(path == lockPath)
            #expect(timeout == 0.05)
        }
        #expect(startedAt.duration(to: clock.now) < .milliseconds(500))
        #expect(try Data(contentsOf: url) == initial)

        _ = flock(heldDescriptor, LOCK_UN)
        try transaction.withExclusiveLock { lockedFile in
            _ = try lockedFile.replace(
                replacement,
                expectedGeneration: try lockedFile.read().generation
            )
        }
        #expect(try Data(contentsOf: url) == replacement)
    }

    @Test("Auth commit uses a unique temporary and proves the complete token set")
    func authCommitIsDurableAndExact() throws {
        let url = makeSecureTestFileURL(prefix: "codexswitch-auth", fileName: "auth.json")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = account(accessToken: "complete-access")

        try SwapEngine.writeAuthFile(for: account, path: url.path)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(AuthFile.self, from: data)
        #expect(decoded.tokens.accessToken == account.accessToken)
        #expect(decoded.tokens.refreshToken == account.refreshToken)
        #expect(decoded.tokens.idToken == account.idToken)
        #expect(decoded.tokens.accountId == account.accountId)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains(where: { $0.hasPrefix(".auth.json.tmp-") }))
        #expect(names.contains("auth.json.lock"))
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        ).intValue
        #expect(mode & 0o777 == 0o600)
    }

    @Test("Auth commit rejects generation tampering while locked")
    func authCommitRejectsStaleGeneration() throws {
        let url = makeSecureTestFileURL(prefix: "codexswitch-auth-cas", fileName: "auth.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try SwapEngine.writeAuthFile(for: account(accessToken: "first"), path: url.path)
        let tampered = Data("tampered-generation".utf8)
        let hooks = SwapEngine.AuthFileWriteTestHooks(
            transaction: .init(beforeGenerationCheck: {
                try overwriteSecureTestFile(tampered, atPath: url.path)
            })
        )

        do {
            try SwapEngine.writeAuthFile(
                for: account(accessToken: "second"),
                path: url.path,
                testHooks: hooks
            )
            Issue.record("Expected stale generation rejection")
        } catch let error as SecureAtomicFileError {
            guard case .staleGeneration = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: url) == tampered)
    }

    @Test("Auth commit fails when exact-byte readback is changed")
    func authCommitRequiresReadbackProof() throws {
        let url = makeSecureTestFileURL(prefix: "codexswitch-auth-readback", fileName: "auth.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tampered = Data("tampered-readback".utf8)
        let hooks = SwapEngine.AuthFileWriteTestHooks(
            transaction: .init(beforeReadback: {
                try overwriteSecureTestFile(tampered, atPath: url.path)
            })
        )

        do {
            try SwapEngine.writeAuthFile(
                for: account(accessToken: "target"),
                path: url.path,
                testHooks: hooks
            )
            Issue.record("Expected readback rejection")
        } catch let error as SecureAtomicFileError {
            guard case .readbackMismatch = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: url) == tampered)
    }

    @Test("Auth lock rejects symlink replacement")
    func authLockRejectsSymlink() throws {
        let url = makeSecureTestFileURL(prefix: "codexswitch-auth-lock", fileName: "auth.json")
        let directory = url.deletingLastPathComponent()
        let outside = makeSecureTestFileURL(prefix: "codexswitch-auth-outside", fileName: "sentinel")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: outside.deletingLastPathComponent(),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = Data("sentinel".utf8)
        try sentinel.write(to: outside)
        let lockPath = directory.appendingPathComponent("auth.json.lock").path
        guard symlink(outside.path, lockPath) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try SwapEngine.writeAuthFile(for: account(accessToken: "target"), path: url.path)
            Issue.record("Expected lock symlink rejection")
        } catch let error as SecureAtomicFileError {
            guard case .lockFailed(_, "open", _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: outside) == sentinel)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private func account(accessToken: String) -> CodexAccount {
        CodexAccount(
            email: "auth@example.com",
            accessToken: accessToken,
            refreshToken: "complete-refresh",
            idToken: "complete-id",
            accountId: "complete-account"
        )
    }
}
