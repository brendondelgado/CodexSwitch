import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CodexSwitch

@Suite("Codex managed runtime trust")
struct CodexManagedRuntimeTrustTests {
    @Test("An intact retained prepared generation authorizes its live CLI")
    func retainedGenerationAuthorizesMatchingRuntime() throws {
        let fixture = try retainedRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        #expect(CodexManagedRuntimeTrust.retainedRuntimeAuthorizes(
            fixture.binding,
            homeDirectory: fixture.home
        ))
    }

    @Test("A changed retained helper revokes first-ACK bootstrap")
    func retainedGenerationRejectsChangedHelper() throws {
        let fixture = try retainedRuntimeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try setMode(0o700, at: fixture.helper)
        try Data("changed-helper".utf8).write(to: fixture.helper)
        try setMode(0o500, at: fixture.helper)

        #expect(!CodexManagedRuntimeTrust.retainedRuntimeAuthorizes(
            fixture.binding,
            homeDirectory: fixture.home
        ))
    }

    private struct Fixture {
        let home: URL
        let helper: URL
        let binding: CodexReloadBinding
    }

    private func retainedRuntimeFixture() throws -> Fixture {
        let home = try makeSecureTestDirectoryURL(
            prefix: "codex-managed-runtime"
        )
        let generation = home.appendingPathComponent(
            ".local/share/codexswitch/prepared-codex/0.145.0/generation-1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: generation,
            withIntermediateDirectories: true
        )

        let runtime = generation.appendingPathComponent("codex")
        let helper = generation.appendingPathComponent("codex-code-mode-host")
        let controlPlane = generation.appendingPathComponent("codexswitch-cli")
        let files = [
            (runtime, Data("runtime".utf8)),
            (helper, Data("helper".utf8)),
            (controlPlane, Data("control".utf8)),
        ]
        for (url, bytes) in files {
            try bytes.write(to: url)
            try setMode(0o500, at: url)
        }

        let manifest: [String: Any] = [
            "format": "codexswitch-macos-runtime-artifact-v1",
            "codexSwitchGitSha": String(repeating: "a", count: 40),
            "codexSwitchBuildVersion": "test",
            "upstreamCodexVersion": "0.145.0",
            "upstreamCodexGitSha": String(repeating: "b", count: 40),
            "sourcePatchSha256": String(repeating: "c", count: 64),
            "targetTriple": "aarch64-apple-darwin",
            "architecture": "arm64",
            "buildEpoch": 1,
            "files": files.map { url, bytes in
                [
                    "name": url.lastPathComponent,
                    "bytes": bytes.count,
                    "sha256": SHA256.hash(data: bytes)
                        .map { String(format: "%02x", $0) }
                        .joined(),
                ] as [String: Any]
            },
        ]
        let manifestURL = generation.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: manifestURL)
        try setMode(0o400, at: manifestURL)

        var runtimeInfo = stat()
        #expect(lstat(runtime.path, &runtimeInfo) == 0)
        let executableIdentity = CodexKernelExecutableIdentity(
            canonicalPath: runtime.path,
            device: UInt64(bitPattern: Int64(runtimeInfo.st_dev)),
            inode: UInt64(runtimeInfo.st_ino)
        )
        let binding = CodexReloadBinding(
            processIdentity: CodexSignalProcessIdentity(
                pid: 42,
                ownerUID: UInt32(getuid()),
                executablePath: runtime.path,
                startSeconds: 1_000,
                startMicroseconds: 1
            ),
            kernelExecutableIdentity: executableIdentity,
            runtimeKind: .localInteractiveCLI,
            authFileIdentity: CodexAuthFileIdentity(
                canonicalPath: home.appendingPathComponent(".codex/auth.json").path,
                device: 9,
                inode: 10,
                accountID: "account-1",
                completeTokenFingerprint: String(repeating: "d", count: 64)
            ),
            requestNonce: "nonce",
            issuedAtUnixMilliseconds: 1_000_100
        )
        return Fixture(home: home, helper: helper, binding: binding)
    }

    private func setMode(_ mode: mode_t, at url: URL) throws {
        guard chmod(url.path, mode) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}
