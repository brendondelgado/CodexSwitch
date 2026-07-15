import Foundation
import Testing
@testable import CodexSwitch

@Suite("Linux devbox monitor")
struct LinuxDevboxMonitorTests {
    @Test("remote session detection includes Codex app VPS remote client")
    func remoteSessionDetectionIncludesCodexAppVPSRemoteClient() {
        let output = """
        /Applications/Codex.app/Contents/Resources/codex -c model=gpt-5.5 -c model_reasoning_effort=xhigh --remote ws://100.95.84.123:8390 resume 019ddf25
        """

        #expect(LinuxDevboxMonitor.isCodexVPSRemoteSessionRunning(psOutput: output))
    }

    @Test("remote session detection includes local codex-vps tunnel client")
    func remoteSessionDetectionIncludesLocalCodexVPSTunnelClient() {
        let output = """
        /Users/brendondelgado/.local/share/codexswitch/patched-mac-remote-client/codex --remote ws://127.0.0.1:18390 resume 019ddf25
        """

        #expect(LinuxDevboxMonitor.isCodexVPSRemoteSessionRunning(psOutput: output))
    }

    @Test("remote session detection skips SSH tunnel helpers")
    func remoteSessionDetectionSkipsSSHTunnelHelpers() {
        let output = """
        /usr/bin/ssh -N -L 127.0.0.1:18390:127.0.0.1:8390 signul-vps
        /Applications/Tailscale.app/Contents/MacOS/Tailscale nc signul-hostinger-kvm4 22
        """

        #expect(!LinuxDevboxMonitor.isCodexVPSRemoteSessionRunning(psOutput: output))
    }

    @Test("remote sessions bypass normal sixty second readiness cadence")
    func remoteSessionsBypassNormalSixtySecondReadinessCadence() {
        let now = Date(timeIntervalSince1970: 2_000)
        let recentFullCheck = now.addingTimeInterval(-5)

        #expect(!LinuxDevboxMonitor.shouldRunReadinessCheck(
            now: now,
            lastFullCheckAt: recentFullCheck,
            hasActiveRemoteSession: false,
            force: false
        ))
        #expect(LinuxDevboxMonitor.shouldRunReadinessCheck(
            now: now,
            lastFullCheckAt: recentFullCheck,
            hasActiveRemoteSession: true,
            force: false
        ))
    }

    @Test("background readiness does not own the Mac active account")
    func backgroundReadinessKeepsMacAccountAuthority() {
        #expect(LinuxDevboxMonitor.remotePollingMode(hasActiveRemoteSession: false) == .statusOnly)
    }

    @Test("active VPS sessions use fast status polling without owning Mac state")
    func activeVPSSessionsUseFastStatusPolling() {
        #expect(LinuxDevboxMonitor.remotePollingMode(hasActiveRemoteSession: true) == .activeSession)
    }

    @Test("account state decoding retains legacy snapshots and mixed VPS date formats")
    func accountStateDecodingAcceptsMixedDateFormatsFromVPSStore() throws {
        let json = """
        {
          "accounts": [
            {
              "email": "old@example.com",
              "isActive": false,
              "quotaSnapshot": {
                "fiveHour": {
                  "usedPercent": 98.6,
                  "windowDurationMins": 300,
                  "resetsAt": "2026-05-23T00:29:46Z",
                  "hardLimitReached": false
                },
                "weekly": {
                  "usedPercent": 50,
                  "windowDurationMins": 10080,
                  "resetsAt": "2026-05-30T00:29:46Z",
                  "hardLimitReached": false
                },
                "fetchedAt": "2026-05-21T17:10:41Z"
              },
              "planType": "free",
              "lastRefreshed": "2026-05-21T17:10:41Z"
            },
            {
              "email": "new@example.com",
              "isActive": true,
              "quotaSnapshot": {
                "fiveHour": {
                  "usedPercent": 2,
                  "windowDurationMins": 300,
                  "resetsAt": 801854591.0,
                  "hardLimitReached": false
                },
                "weekly": {
                  "usedPercent": 31,
                  "windowDurationMins": 10080,
                  "resetsAt": 801957391.0,
                  "hardLimitReached": false
                },
                "fetchedAt": 801837391.0
              },
              "planType": "pro",
              "lastRefreshed": 801837391.0
            }
          ]
        }
        """

        let states = try LinuxDevboxMonitor.decodeAccountStates(data: Data(json.utf8))

        #expect(states.count == 2)
        #expect(states[0].email == "old@example.com")
        #expect(states[0].quotaSnapshot?.fiveHour?.shouldAutoSwapAway == true)
        #expect(states[1].isActive)
        #expect(states[1].quotaSnapshot?.fiveHour?.usedPercent == 2)
    }

    @Test("account state decoding accepts quota v2 weekly-only snapshots")
    func accountStateDecodingAcceptsQuotaV2Collections() throws {
        let json = """
        {
          "accounts": [
            {
              "email": "weekly@example.com",
              "isActive": true,
              "quotaSnapshot": {
                "version": 2,
                "allowed": false,
                "limitReached": true,
                "fetchedAt": 801837391.0,
                "windows": [
                  {
                    "kind": "weekly",
                    "durationSeconds": 604800,
                    "usedPercent": 77,
                    "resetsAt": 801957391.0,
                    "source": {
                      "rateLimit": "main",
                      "slot": "primary",
                      "limitName": "Codex",
                      "meteredFeature": "codex"
                    },
                    "hardLimitReached": false
                  },
                  {
                    "kind": "fiveHour",
                    "durationSeconds": 0,
                    "usedPercent": 100,
                    "resetsAt": 801837391.0,
                    "hardLimitReached": true
                  },
                  {
                    "kind": "unknown",
                    "durationSeconds": 86400,
                    "usedPercent": 99,
                    "resetsAt": 801900000.0,
                    "hardLimitReached": false
                  }
                ]
              }
            }
          ]
        }
        """

        let states = try LinuxDevboxMonitor.decodeAccountStates(data: Data(json.utf8))
        let snapshot = try #require(states.first?.quotaSnapshot)
        let weekly = try #require(snapshot.weekly)

        #expect(snapshot.windows.count == 2)
        #expect(snapshot.policyWindows.count == 1)
        #expect(snapshot.fiveHour == nil)
        #expect(snapshot.isDenied)
        #expect(weekly.usedPercent == 77)
        #expect(weekly.source.limitName == "Codex")
    }

    @Test("credential sync fingerprint tracks quota and runtime state")
    func credentialSyncFingerprintTracksQuotaAndRuntimeState() {
        var account = CodexAccount(
            email: "dev@example.com",
            accessToken: "access-1",
            refreshToken: "refresh-1",
            idToken: "id-1",
            accountId: "acct-1",
            isActive: true
        )
        let original = LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account])

        account.planType = "pro"
        #expect(LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account]) != original)

        let planFingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account])
        account.lastRefreshed = Date(timeIntervalSince1970: 2_000)
        #expect(LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account]) == planFingerprint)

        account.quotaSnapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 1,
                windowDurationMins: 300,
                resetsAt: Date(timeIntervalSince1970: 2_000 + 300 * 60)
            ),
            weekly: QuotaWindow(
                usedPercent: 20,
                windowDurationMins: 10_080,
                resetsAt: Date(timeIntervalSince1970: 2_000 + 10_080 * 60)
            ),
            fetchedAt: Date(timeIntervalSince1970: 2_000)
        )
        #expect(LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account]) != planFingerprint)
        let firstQuotaFingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account])

        account.quotaSnapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 1,
                windowDurationMins: 300,
                resetsAt: Date(timeIntervalSince1970: 2_000 + 300 * 60)
            ),
            weekly: QuotaWindow(
                usedPercent: 20,
                windowDurationMins: 10_080,
                resetsAt: Date(timeIntervalSince1970: 2_000 + 10_080 * 60)
            ),
            fetchedAt: Date(timeIntervalSince1970: 2_030)
        )

        let quotaFingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account])
        #expect(quotaFingerprint == firstQuotaFingerprint)
        #expect(quotaFingerprint != planFingerprint)

        account.runtimeUnusableReason = "usage_limit"
        account.runtimeUnusableUntil = Date(timeIntervalSince1970: 2_300)
        #expect(LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account]) != quotaFingerprint)

        let runtimeFingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account])
        account.refreshToken = "refresh-2"
        #expect(LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account]) != runtimeFingerprint)
    }

    @Test("credential evidence fingerprint covers inactive account tokens")
    func credentialSetFingerprintCoversInactiveTokens() throws {
        let active = CodexAccount(
            email: "active@example.com",
            accessToken: "active-access",
            refreshToken: "active-refresh",
            idToken: "active-id",
            accountId: "active-account",
            isActive: true
        )
        var inactive = CodexAccount(
            email: "inactive@example.com",
            accessToken: "inactive-access",
            refreshToken: "inactive-refresh",
            idToken: "inactive-id",
            accountId: "inactive-account",
            isActive: false
        )
        let before = try #require(LinuxDevboxMonitor.credentialSetFingerprint(
            accounts: [active, inactive]
        ))

        inactive.refreshToken = "rotated-inactive-refresh"
        let after = try #require(LinuxDevboxMonitor.credentialSetFingerprint(
            accounts: [inactive, active]
        ))

        #expect(before != after)
    }

    @Test("remote credential evidence matches the local token-free fingerprint")
    func remoteCredentialEvidenceMatchesLocalFingerprint() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "codexswitch-credential-evidence-\(UUID().uuidString)",
                isDirectory: true
            )
        let storeDirectory = root.appendingPathComponent(".codexswitch", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )

        let accounts = [
            CodexAccount(
                email: "active@example.com",
                accessToken: "active-access-secret",
                refreshToken: "active-refresh-secret",
                idToken: "active-id-secret",
                accountId: "active-account",
                isActive: true
            ),
            CodexAccount(
                email: "inactive@example.com",
                accessToken: "inactive-access-secret",
                refreshToken: "inactive-refresh-secret",
                idToken: "inactive-id-secret",
                accountId: "inactive-account",
                isActive: false
            ),
        ]
        let encodedAccounts = try JSONEncoder().encode(accounts)
        let accountArray = try #require(
            JSONSerialization.jsonObject(with: encodedAccounts) as? [Any]
        )
        let store = try JSONSerialization.data(withJSONObject: ["accounts": accountArray])
        try store.write(to: storeDirectory.appendingPathComponent("accounts.json"))

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", LinuxDevboxMonitor.remoteAccountStateCommand()],
            timeout: 5,
            environment: environment
        )
        let report = try #require(
            JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        )
        let expected = try #require(
            LinuxDevboxMonitor.credentialSetFingerprint(accounts: accounts)
        )

        #expect(result.terminationStatus == 0)
        #expect(report["credentialSetFingerprint"] as? String == expected)
        #expect(!result.stdoutString.contains("active-access-secret"))
        #expect(!result.stdoutString.contains("inactive-refresh-secret"))
    }

    @Test("credential sync fingerprint includes quota v2 denial and window metadata")
    func credentialSyncFingerprintTracksQuotaV2Semantics() {
        let now = Date(timeIntervalSince1970: 2_000)
        let window = QuotaWindow(
            kind: .weekly,
            durationSeconds: 604_800,
            usedPercent: 20,
            resetsAt: now.addingTimeInterval(604_800),
            source: QuotaWindowSourceMetadata(
                rateLimit: .main,
                slot: .primary,
                limitName: "Codex",
                meteredFeature: "codex"
            )
        )
        var account = CodexAccount(
            email: "weekly@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: "weekly",
            quotaSnapshot: QuotaSnapshot(
                allowed: true,
                limitReached: false,
                fetchedAt: now,
                windows: [window]
            )
        )
        let allowed = LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account])

        account.quotaSnapshot = QuotaSnapshot(
            allowed: false,
            limitReached: true,
            fetchedAt: now.addingTimeInterval(30),
            windows: [window]
        )
        let denied = LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account])

        #expect(denied != allowed)
    }

    @Test("credential sync command imports bundle and removes temporary secrets")
    func credentialSyncCommandImportsBundleAndCleansUp() {
        let command = LinuxDevboxMonitor.remoteCredentialSyncCommand(
            remoteDirectory: "/tmp/codexswitch-auto-sync-fixture",
            bundleName: "sync.csbundle",
            passphraseName: "sync.passphrase"
        )

        #expect(command.contains("stage='/tmp/codexswitch-auto-sync-fixture'"))
        #expect(command.contains("CODEXSWITCH_IMPORT_PASSPHRASE_FILE='/tmp/codexswitch-auto-sync-fixture/sync.passphrase'"))
        #expect(command.contains("codexswitch-cli update-bundle '/tmp/codexswitch-auto-sync-fixture/sync.csbundle'"))
        #expect(command.contains("chmod 600 '/tmp/codexswitch-auto-sync-fixture/sync.csbundle'"))
        #expect(!command.contains("chmod 600 --"))
        #expect(!command.contains("--ignore-expiry"))
        #expect(command.contains("'/bin/rm' -rf -- \"$stage\""))
        #expect(command.contains("[ ! -e \"$stage\" ] && [ ! -L \"$stage\" ]"))
        #expect(command.contains(LinuxDevboxMonitor.remoteCleanupFailureMarker))
        #expect(command.contains("trap 'cleanup_with_status \"$?\"' EXIT"))
        #expect(command.contains("trap 'cleanup_with_status 129' HUP"))
        #expect(command.contains("trap 'cleanup_with_status 130' INT"))
        #expect(command.contains("trap 'cleanup_with_status 143' TERM"))
        #expect(command.contains("set -eu"))
        #expect(command.contains("exit \"$status\""))
        #expect(!command.contains("systemctl --user kill --signal=HUP signul-codex-app-server.service"))
        #expect(!command.contains("pgrep -f 'codex app-server'"))
        #expect(!command.contains("python3"))
        #expect(!command.contains(".codex/auth.json"))
        #expect(!command.contains("codexswitch-cli swap"))
    }

    @Test("credential sync staging is private and fail-closed")
    func credentialSyncStagingIsPrivate() {
        let command = LinuxDevboxMonitor.remoteCredentialStagingCommand(
            remoteDirectory: "/tmp/codexswitch-auto-sync-fixture"
        )

        #expect(command == "umask 077; mkdir -m 700 -- '/tmp/codexswitch-auto-sync-fixture'")
    }

    @Test("credential sync cleanup trap preserves the mutating command status")
    func credentialSyncCleanupTrapPreservesStatus() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-remote-cleanup-test-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let stage = root.appendingPathComponent("private-stage", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("bundle".utf8).write(to: stage.appendingPathComponent("sync.csbundle"))
        try Data("passphrase".utf8).write(to: stage.appendingPathComponent("sync.passphrase"))
        let fakeCLI = bin.appendingPathComponent("codexswitch-cli")
        try Data("#!/bin/sh\nexit 23\n".utf8).write(to: fakeCLI)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fakeCLI.path
        )

        let command = LinuxDevboxMonitor.remoteCredentialSyncCommand(
            remoteDirectory: stage.path,
            bundleName: "sync.csbundle",
            passphraseName: "sync.passphrase"
        )
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            timeout: 5,
            environment: environment
        )

        #expect(result.terminationStatus == 23)
        #expect(!result.timedOut)
        #expect(!FileManager.default.fileExists(atPath: stage.path))
    }

    @Test("credential sync cleanup failure is observable and leaves staging unresolved")
    func credentialSyncCleanupFailureIsObservable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-remote-cleanup-failure-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let stage = root.appendingPathComponent("private-stage", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("bundle".utf8).write(to: stage.appendingPathComponent("sync.csbundle"))
        try Data("passphrase".utf8).write(to: stage.appendingPathComponent("sync.passphrase"))
        let fakeCLI = bin.appendingPathComponent("codexswitch-cli")
        let fakeRM = bin.appendingPathComponent("rm")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeCLI)
        try Data("#!/bin/sh\nexit 91\n".utf8).write(to: fakeRM)
        for executable in [fakeCLI, fakeRM] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }

        let command = LinuxDevboxMonitor.remoteCredentialSyncCommand(
            remoteDirectory: stage.path,
            bundleName: "sync.csbundle",
            passphraseName: "sync.passphrase",
            removeExecutable: fakeRM.path
        )
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            timeout: 5,
            environment: environment
        )

        #expect(result.terminationStatus == 74)
        #expect(result.stderrString.contains(LinuxDevboxMonitor.remoteCleanupFailureMarker))
        #expect(FileManager.default.fileExists(atPath: stage.path))
    }

    @Test("credential sync cleanup ignores a shadowed rm that falsely reports success")
    func credentialSyncCleanupIgnoresShadowedRM() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-remote-cleanup-shadow-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let stage = root.appendingPathComponent("private-stage", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("bundle".utf8).write(to: stage.appendingPathComponent("sync.csbundle"))
        try Data("passphrase".utf8).write(to: stage.appendingPathComponent("sync.passphrase"))
        let fakeCLI = bin.appendingPathComponent("codexswitch-cli")
        let shadowedRM = bin.appendingPathComponent("rm")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeCLI)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: shadowedRM)
        for executable in [fakeCLI, shadowedRM] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executable.path
            )
        }

        let command = LinuxDevboxMonitor.remoteCredentialSyncCommand(
            remoteDirectory: stage.path,
            bundleName: "sync.csbundle",
            passphraseName: "sync.passphrase"
        )
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        let result = ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            timeout: 5,
            environment: environment
        )

        #expect(result.terminationStatus == 0)
        #expect(!result.stderrString.contains(LinuxDevboxMonitor.remoteCleanupFailureMarker))
        #expect(!FileManager.default.fileExists(atPath: stage.path))
    }

    @Test("local credential staging is private from creation")
    func localCredentialStagingIsPrivateFromCreation() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codexswitch-linux-credential-sync-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try LinuxDevboxMonitor.createPrivateLocalCredentialStage(at: directory)
        let secret = directory.appendingPathComponent("fixture.passphrase")
        try LinuxDevboxMonitor.writePrivateLocalCredentialFile(Data("secret".utf8), to: secret)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: secret.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("local cleanup failures remain observable")
    func localCredentialCleanupFailureIsObservable() {
        let directory = URL(fileURLWithPath: "/tmp/codexswitch-linux-credential-sync-fixture")
        let failure = LinuxDevboxMonitor.cleanupLocalCredentialStage(
            at: directory,
            removeItem: { _ in throw CocoaError(.fileWriteNoPermission) },
            pathExists: { _ in true }
        )

        #expect(failure?.contains("cleanup failed") == true)
        #expect(failure?.contains(directory.path) == true)
    }

    @Test("signals after credential import starts are outcome unknown")
    func credentialImportSignalsAreOutcomeUnknown() {
        for status: Int32 in [129, 130, 143] {
            #expect(
                LinuxDevboxMonitor.completedCredentialImportFailureDisposition(status)
                    == .outcomeUnknown
            )
        }
        #expect(
            LinuxDevboxMonitor.completedCredentialImportFailureDisposition(23)
                == .rejected
        )
    }

    @Test("automatic credential bundles expire and never bypass expiry checks")
    func automaticCredentialBundlesRetainExpiryEnforcement() throws {
        #expect(LinuxDevboxMonitor.automaticCredentialBundleLifetime == 10 * 60)
        let issuedAt = Date(timeIntervalSince1970: 2_000)
        let account = CodexAccount(
            email: "expiry@example.com",
            accessToken: "expiry-access",
            refreshToken: "expiry-refresh",
            idToken: "expiry-id",
            accountId: "expiry-account",
            isActive: true
        )
        let service = LinuxDevboxExportService(
            now: { issuedAt },
            hostName: { "expiry-fixture" },
            randomBytes: { Data(repeating: 0x5a, count: $0) }
        )
        let bundle = try service.makeEncryptedBundle(
            accounts: [account],
            passphrase: "expiry-test-passphrase",
            confirmation: "expiry-test-passphrase",
            lifetime: LinuxDevboxMonitor.automaticCredentialBundleLifetime
        )

        #expect(bundle.metadata.expiresAt == issuedAt.addingTimeInterval(10 * 60))
        #expect(bundle.metadata.expiresAt < issuedAt.addingTimeInterval(10 * 60 + 1))
        let command = LinuxDevboxMonitor.remoteCredentialSyncCommand(
            remoteDirectory: "/tmp/codexswitch-auto-sync-fixture",
            bundleName: "sync.csbundle",
            passphraseName: "sync.passphrase"
        )
        #expect(!command.contains("--ignore-expiry"))
    }

    @Test("mutating SSH retries only a definite pre-execution transport failure")
    func mutatingSSHOnlyRetriesPreExecutionTransportFailure() {
        var calls = 0
        let executionToken = "fixture-token"
        let executionMarker = LinuxDevboxMonitor.remoteExecutionMarker(
            executionToken: executionToken
        )
        let completionMarker = LinuxDevboxMonitor.remoteCompletionMarker(
            executionToken: executionToken
        )
        let result = LinuxDevboxMonitor.runSSHWithCandidates(
            [["first"], ["second"]],
            remoteCommand: "codexswitch-cli swap fixture",
            timeout: 5,
            retryPolicy: .preExecutionTransportOnly,
            executionToken: executionToken
        ) { _, _, _ in
            calls += 1
            if calls == 1 {
                return ProcessRunResult(
                    terminationStatus: -1,
                    stdout: Data(),
                    stderr: Data("The SSH executable could not be launched\n".utf8),
                    timedOut: false
                )
            }
            return ProcessRunResult(
                terminationStatus: 0,
                stdout: Data("swapped\n".utf8),
                stderr: Data("\(executionMarker)\n\(completionMarker) 0\n".utf8),
                timedOut: false
            )
        }

        #expect(calls == 2)
        #expect(result.terminationStatus == 0)
        #expect(!result.stderrString.contains(executionMarker))
        #expect(!result.stderrString.contains(completionMarker))
    }

    @Test("mutating SSH never replays a started or outcome-unknown command")
    func mutatingSSHDoesNotReplayStartedOrUnknownOutcomes() {
        let executionToken = "fixture-token"
        let executionMarker = LinuxDevboxMonitor.remoteExecutionMarker(
            executionToken: executionToken
        )
        let completionMarker = LinuxDevboxMonitor.remoteCompletionMarker(
            executionToken: executionToken
        )
        for firstResult in [
            ProcessRunResult(
                terminationStatus: 1,
                stdout: Data(),
                stderr: Data(
                    "\(executionMarker)\nremote failure\n\(completionMarker) 1\n".utf8
                ),
                timedOut: false
            ),
            ProcessRunResult(
                terminationStatus: -1,
                stdout: Data(),
                stderr: Data("connection lost\n".utf8),
                timedOut: true
            ),
            ProcessRunResult(
                terminationStatus: 255,
                stdout: Data(),
                stderr: Data("ssh: connect to host fixture: Connection refused\n".utf8),
                timedOut: false
            ),
            ProcessRunResult(
                terminationStatus: 255,
                stdout: Data(),
                stderr: Data("ssh: connect to host fixture: Connection timed out\n".utf8),
                timedOut: false
            ),
            ProcessRunResult(
                terminationStatus: 255,
                stdout: Data(),
                stderr: Data("proxycommand exited with status 1\n".utf8),
                timedOut: false
            ),
            ProcessRunResult(
                terminationStatus: 255,
                stdout: Data(),
                stderr: Data(
                    "\(executionMarker)\nconnection refused\n".utf8
                ),
                timedOut: false
            ),
        ] {
            var calls = 0
            let result = LinuxDevboxMonitor.runSSHWithCandidates(
                [["first"], ["second"]],
                remoteCommand: "codexswitch-cli update-bundle fixture.csbundle",
                timeout: 5,
                retryPolicy: .preExecutionTransportOnly,
                executionToken: executionToken
            ) { _, _, _ in
                calls += 1
                return firstResult
            }

            #expect(calls == 1)
            #expect(result.terminationStatus == firstResult.terminationStatus)
            #expect(result.timedOut == firstResult.timedOut)
        }
    }

    @Test("remote success requires one matching completion marker")
    func remoteSuccessRequiresMatchingCompletionMarker() {
        let marker = LinuxDevboxMonitor.remoteCompletionMarker(executionToken: "fixture")
        let missing = ProcessRunResult(
            terminationStatus: 0,
            stdout: Data(),
            stderr: Data(),
            timedOut: false
        )
        let matching = ProcessRunResult(
            terminationStatus: 0,
            stdout: Data(),
            stderr: Data("\(marker) 0\n".utf8),
            timedOut: false
        )
        let duplicate = ProcessRunResult(
            terminationStatus: 0,
            stdout: Data(),
            stderr: Data("\(marker) 0\n\(marker) 0\n".utf8),
            timedOut: false
        )

        #expect(!LinuxDevboxMonitor.remoteCommandCompletionIsProven(
            completionMarker: marker,
            result: missing
        ))
        #expect(LinuxDevboxMonitor.remoteCommandCompletionIsProven(
            completionMarker: marker,
            result: matching
        ))
        #expect(!LinuxDevboxMonitor.remoteCommandCompletionIsProven(
            completionMarker: marker,
            result: duplicate
        ))
    }

    @Test("remote command envelope preserves heredoc terminators and completion proof")
    func remoteCommandEnvelopePreservesHeredocs() {
        let command = """
        python3 - <<'PY'
        import json
        print(json.dumps({"active": "vps-account"}, separators=(",", ":")))
        PY
        """
        let result = LinuxDevboxMonitor.runSSHWithCandidates(
            [["fixture"]],
            remoteCommand: command,
            timeout: 5,
            retryPolicy: .readOnly,
            executionToken: "heredoc-fixture"
        ) { _, arguments, timeout in
            guard let envelope = arguments.last else {
                return ProcessRunResult(
                    terminationStatus: -1,
                    stdout: Data(),
                    stderr: Data("missing envelope".utf8),
                    timedOut: false
                )
            }
            return ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", envelope],
                timeout: timeout
            )
        }

        #expect(result.terminationStatus == 0)
        #expect(!result.timedOut)
        #expect(result.stdoutString == "{\"active\":\"vps-account\"}\n")
        #expect(result.stderrString.isEmpty)
    }

    @Test("poll is treated as mutating because it persists account state")
    func pollUsesMutatingRetryPolicy() {
        #expect(LinuxDevboxMonitor.pollAccountRetryPolicy == .preExecutionTransportOnly)
    }

    @Test("only proven pre-execution credential failures are automatically retried")
    func credentialSyncAutomaticRetryDispositionIsFailClosed() {
        for disposition in CredentialSyncFailureDisposition.allCases {
            let failure = LinuxDevboxMonitorFailure(
                message: "fixture",
                credentialSyncDisposition: disposition
            )
            #expect(
                AppDelegate.shouldAutomaticallyRetryLinuxDevboxCredentialSync(after: failure)
                    == (disposition == .retryablePreExecution)
            )
            #expect(
                disposition.requiresPersistentHold
                    == (disposition == .outcomeUnknown || disposition == .cleanupUnresolved)
            )
        }
    }

    @Test("proven pre-execution failure schedules one bounded retry")
    func credentialSyncPreExecutionFailureBuildsOneRetryPlan() throws {
        let failure = LinuxDevboxMonitorFailure(
            message: "fixture",
            credentialSyncDisposition: .retryablePreExecution
        )
        let plan = try #require(AppDelegate.linuxDevboxCredentialSyncRetryPlan(
            after: failure,
            originalContext: "token-refresh",
            fingerprint: String(repeating: "a", count: 64)
        ))

        #expect(plan.context == "credential-retry-token-refresh")
        #expect(plan.delay == AppDelegate.linuxDevboxCredentialSyncRetryDelay)
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: plan.context))
        #expect(AppDelegate.shouldBypassLinuxDevboxCredentialSyncThrottle(for: plan.context))
        #expect(AppDelegate.shouldBypassLinuxDevboxCredentialSyncNetworkBackoff(
            for: plan.context
        ))
        #expect(!AppDelegate.shouldBypassLinuxDevboxCredentialSyncNetworkBackoff(
            for: "token-refresh"
        ))
        #expect(AppDelegate.linuxDevboxCredentialSyncRetryPlan(
            after: failure,
            originalContext: plan.context,
            fingerprint: plan.fingerprint
        ) == nil)
    }

    @Test("credential sync contexts exclude quota-only refreshes and remote mirror persistence")
    func credentialSyncContextsExcludeQuotaOnlyRefreshesAndRemoteMirrorPersistence() {
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "token-refresh"))
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "swap"))
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "reauth-account"))
        #expect(!AppDelegate.shouldSyncLinuxDevboxCredentials(for: "quota-update"))
        #expect(!AppDelegate.shouldSyncLinuxDevboxCredentials(for: "quota-primed"))
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "subscription-info"))
        #expect(!AppDelegate.shouldSyncLinuxDevboxCredentials(for: "linux-devbox-interactive-sync"))
        #expect(!AppDelegate.shouldSyncLinuxDevboxCredentials(for: "token-refresh-failed"))
    }

    @Test("auth-changing credential sync contexts bypass throttle")
    func authChangingCredentialSyncContextsBypassThrottle() {
        #expect(AppDelegate.shouldBypassLinuxDevboxCredentialSyncThrottle(for: "reauth-account"))
        #expect(AppDelegate.shouldBypassLinuxDevboxCredentialSyncThrottle(for: "queued-after-reauth-account"))
        #expect(AppDelegate.shouldBypassLinuxDevboxCredentialSyncThrottle(for: "token-refresh"))
        #expect(AppDelegate.shouldBypassLinuxDevboxCredentialSyncThrottle(for: "swap"))
        #expect(!AppDelegate.shouldBypassLinuxDevboxCredentialSyncThrottle(for: "load-restore"))
        #expect(!AppDelegate.shouldBypassLinuxDevboxCredentialSyncThrottle(for: "subscription-info"))
        #expect(AppDelegate.linuxDevboxCredentialSyncThrottleInterval(for: "quota-update") == 60)
        #expect(AppDelegate.linuxDevboxCredentialSyncThrottleInterval(for: "queued-after-quota-update") == 60)
        #expect(AppDelegate.linuxDevboxCredentialSyncThrottleInterval(for: "load-restore") == 10 * 60)
    }

    @Test("reauth validation rejects auth failures but tolerates transient usage errors")
    func reauthValidationRejectsAuthFailuresButToleratesTransientUsageErrors() {
        #expect(AppDelegate.shouldRejectReauthenticationValidation(.tokenExpired))
        #expect(AppDelegate.shouldRejectReauthenticationValidation(.httpError(401)))
        #expect(AppDelegate.shouldRejectReauthenticationValidation(.httpError(403)))
        #expect(!AppDelegate.shouldRejectReauthenticationValidation(.usageUnavailable))
        #expect(!AppDelegate.shouldRejectReauthenticationValidation(.rateLimited))
        #expect(!AppDelegate.shouldRejectReauthenticationValidation(.networkError("cancelled")))
    }
}
