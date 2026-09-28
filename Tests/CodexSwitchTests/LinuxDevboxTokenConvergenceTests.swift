import Darwin
import Foundation
import Testing
@testable import CodexSwitch

/// End-to-end return path: a real VPS account store read by the real Rust CLI
/// through the real SSH envelope (executed locally), decoded and planned by the
/// real Swift code, and adopted through the real Mac account-store commit.
/// Build the CLI first; set CODEXSWITCH_CLI_TEST_BINARY to override the path.
private let convergenceCLIBinary: String? = {
    let path = ProcessInfo.processInfo.environment["CODEXSWITCH_CLI_TEST_BINARY"]
        ?? "/tmp/cs-target-token/debug/codexswitch-cli"
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}()

@Suite("Linux devbox token convergence")
struct LinuxDevboxTokenConvergenceTests {
    private static let now = Date()

    private func token(_ providerAccountId: String, expiresIn: TimeInterval, issuedAgo: TimeInterval) -> String {
        let claims: [String: Any] = [
            "exp": Int(Self.now.addingTimeInterval(expiresIn).timeIntervalSince1970),
            "iat": Int(Self.now.addingTimeInterval(-issuedAgo).timeIntervalSince1970),
            "https://api.openai.com/auth": ["chatgpt_account_id": providerAccountId],
        ]
        let payload = try! JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).sig"
    }

    /// Generation 1 is nine days old; generation 2 is a fresh refresh.
    private func account(
        _ name: String, generation: Int, id: UUID, active: Bool = false,
        providerAccountId: String? = nil, blocked: Bool = false
    ) -> CodexAccount {
        let provider = providerAccountId ?? "provider-\(name)"
        return CodexAccount(
            id: id,
            email: "\(name)@example.com",
            accessToken: generation == 1
                ? token(provider, expiresIn: 86_400, issuedAgo: 9 * 86_400)
                : token(provider, expiresIn: 10 * 86_400, issuedAgo: 0),
            refreshToken: "refresh-\(name)-gen\(generation)",
            idToken: "id-\(name)",
            accountId: provider,
            runtimeUnusableUntil: blocked ? Self.now.addingTimeInterval(30 * 86_400) : nil,
            runtimeUnusableReason: blocked ? "token_expired" : nil,
            isActive: active
        )
    }

    @Test(
        "Mac adopts only strictly newer VPS chains and flags newer Mac chains for push",
        .enabled(if: convergenceCLIBinary != nil)
    )
    func convergesToNewestChainPerAccount() throws {
        let cli = try #require(convergenceCLIBinary)
        let root = URL(fileURLWithPath: String(cString: realpath(NSTemporaryDirectory(), nil)))
            .appendingPathComponent("codexswitch-token-convergence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vpsHome = root.appendingPathComponent("vps-home", isDirectory: true)
        let cliDirectory = vpsHome.appendingPathComponent(".local/share/codexswitch/current", isDirectory: true)
        try FileManager.default.createDirectory(at: cliDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: cliDirectory.appendingPathComponent("codexswitch-cli").path,
            withDestinationPath: cli
        )
        let flock = root.appendingPathComponent("flock")
        try Data("#!/bin/sh\nshift 3\nexec \"$@\"\n".utf8).write(to: flock)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: flock.path)

        let ids = (0..<6).map { _ in UUID() }
        // active: Mac refreshed (gen 2), VPS still on gen 1 -> push.
        // vpsRefreshed: VPS daemon refreshed (gen 2); the Mac copy is dead and
        //   blocked token_expired -> adopt, clearing the block.
        // macReauthed: Mac holds gen 2, VPS gen 1 -> push, never downgrade.
        // tie: same access token generation, divergent refresh token -> keep local.
        // crossed: VPS token claims another account -> never adopted.
        // runtimeRefreshed: a VPS runtime refreshed into auth.json (gen 2) but the
        //   VPS store still holds gen 1 -> adopt from auth, then push to the store.
        let mac = [
            account("active", generation: 2, id: ids[0], active: true),
            account("vpsRefreshed", generation: 1, id: ids[1], blocked: true),
            account("macReauthed", generation: 2, id: ids[2]),
            account("tie", generation: 1, id: ids[3]),
            account("crossed", generation: 1, id: ids[4]),
            account("runtimeRefreshed", generation: 1, id: ids[5]),
        ]
        var vps = [
            account("active", generation: 1, id: UUID(), active: true),
            account("vpsRefreshed", generation: 2, id: UUID()),
            account("macReauthed", generation: 1, id: UUID()),
            account("tie", generation: 1, id: UUID()),
            account("crossed", generation: 2, id: UUID()),
            account("runtimeRefreshed", generation: 1, id: UUID()),
        ]
        vps[3].refreshToken = "refresh-tie-vps"
        vps[3].accessToken = mac[3].accessToken
        vps[4].accessToken = token("provider-active", expiresIn: 20 * 86_400, issuedAgo: 0)

        let macStore = KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: root.appendingPathComponent("mac/accounts.json").path
        )
        try macStore.saveAll(mac)
        try KeychainStore(
            service: "CodexSwitch-Test-\(UUID().uuidString)",
            storePath: vpsHome.appendingPathComponent(".codexswitch/accounts.json").path
        ).saveAll(vps)
        let runtimeGeneration = account("runtimeRefreshed", generation: 2, id: UUID())
        let codexDirectory = vpsHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let authFile = codexDirectory.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["tokens": [
            "id_token": runtimeGeneration.idToken,
            "access_token": runtimeGeneration.accessToken,
            "refresh_token": runtimeGeneration.refreshToken,
            "account_id": runtimeGeneration.accountId,
        ]]).write(to: authFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)

        let settings = LinuxDevboxMonitorSettings(
            enabled: true, host: "vps.example.test", user: "codex", sshKeyPath: "", port: 22
        )
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = vpsHome.path
        let localSSH: (URL, [String], TimeInterval) -> ProcessRunResult = { _, arguments, timeout in
            ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", arguments.last!.replacingOccurrences(of: "/usr/bin/flock", with: flock.path)],
                timeout: timeout,
                environment: environment
            )
        }

        func convergeOnce() throws -> LinuxDevboxTokenConvergence.Plan {
            let remote = try LinuxDevboxMonitor.fetchCredentialGenerations(
                settings: settings, runner: localSSH
            ).get()
            #expect(remote.count == 7)
            let plan = LinuxDevboxTokenConvergence.plan(local: try macStore.loadAll(), remote: remote)
            for adoption in plan.adoptions {
                guard case .persisted = try macStore.saveInactiveCredentialUpdate(
                    original: adoption.original, candidate: adoption.candidate
                ) else {
                    Issue.record("adoption was discarded as credential drift")
                    continue
                }
            }
            return plan
        }

        let first = try convergeOnce()
        #expect(first.adoptions.map(\.original.id) == [ids[1], ids[5]])
        #expect(first.newerLocalProviderAccountIds == [
            "provider-active", "provider-macreauthed", "provider-runtimerefreshed",
        ])

        let converged = Dictionary(uniqueKeysWithValues: try macStore.loadAll().map { ($0.id, $0) })
        let adopted = try #require(converged[ids[1]])
        #expect(adopted.refreshToken == "refresh-vpsRefreshed-gen2")
        #expect(adopted.accessToken == vps[1].accessToken)
        #expect(adopted.runtimeUnusableReason == nil && adopted.runtimeUnusableUntil == nil)
        #expect(adopted.email == "vpsRefreshed@example.com")
        #expect(converged[ids[0]]?.refreshToken == "refresh-active-gen2")
        #expect(converged[ids[2]]?.refreshToken == "refresh-macReauthed-gen2")
        #expect(converged[ids[3]]?.refreshToken == "refresh-tie-gen1")
        #expect(converged[ids[4]]?.refreshToken == "refresh-crossed-gen1")
        #expect(converged[ids[5]]?.refreshToken == "refresh-runtimeRefreshed-gen2")

        // A second round is idempotent: nothing older is ever adopted.
        let second = try convergeOnce()
        #expect(second.adoptions.isEmpty)
        #expect(second.newerLocalProviderAccountIds == first.newerLocalProviderAccountIds)
    }
}
