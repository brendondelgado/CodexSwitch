import Foundation
import Testing
@testable import CodexSwitch

@Suite("Linux devbox monitor")
struct LinuxDevboxMonitorTests {
    @Test("reset authority migration is sticky and fails closed")
    func resetAuthorityMigrationIsStickyAndFailsClosed() throws {
        let suiteName = "LinuxDevboxMonitorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        defaults.set("authority.example.test", forKey: "linuxDevboxHost")
        defaults.set("codex", forKey: "linuxDevboxUser")
        defaults.set(22, forKey: "linuxDevboxSSHPort")
        defaults.set(
            AutomaticRateLimitResetOwner.macStandalone.rawValue,
            forKey: LinuxDevboxMonitorSettings.resetAuthorityModeDefaultsKey
        )

        let migrated = LinuxDevboxMonitor.settings(from: defaults)
        #expect(migrated.effectiveResetAuthorityMode == .vpsAuthority)
        #expect(defaults.string(
            forKey: LinuxDevboxMonitorSettings.resetAuthorityModeDefaultsKey
        ) == AutomaticRateLimitResetOwner.vpsAuthority.rawValue)

        defaults.set(" invalid host ", forKey: "linuxDevboxHost")
        let corruptedEndpoint = LinuxDevboxMonitor.settings(from: defaults)
        #expect(!corruptedEndpoint.hasRemoteAuthorityEndpoint)
        #expect(corruptedEndpoint.usesVPSResetAuthority)
        #expect(!corruptedEndpoint.hasUsableVPSResetAuthorityTransport)

        defaults.removeObject(forKey: LinuxDevboxMonitorSettings.resetAuthorityModeDefaultsKey)
        let missingMode = LinuxDevboxMonitor.settings(from: defaults)
        #expect(missingMode.usesVPSResetAuthority)
        #expect(defaults.string(
            forKey: LinuxDevboxMonitorSettings.resetAuthorityModeDefaultsKey
        ) == AutomaticRateLimitResetOwner.vpsAuthority.rawValue)

        defaults.set(
            AutomaticRateLimitResetOwner.macStandalone.rawValue,
            forKey: LinuxDevboxMonitorSettings.resetAuthorityModeDefaultsKey
        )
        let explicitStandalone = LinuxDevboxMonitor.settings(from: defaults)
        #expect(explicitStandalone.effectiveResetAuthorityMode == .macStandalone)
        #expect(!explicitStandalone.usesVPSResetAuthority)
    }

    @Test("invalid VPS endpoint rejects every reset transport without fallback")
    func invalidVPSEndpointRejectsResetTransports() {
        let settings = LinuxDevboxMonitorSettings(
            enabled: false,
            host: " invalid host ",
            user: "codex",
            sshKeyPath: "~/.ssh/id_ed25519",
            port: 22,
            resetAuthorityMode: .vpsAuthority
        )

        guard case .failure(let observationFailure) = LinuxDevboxMonitor
            .automaticResetPolicy(settings: settings),
              case .failure(let mutationFailure) = LinuxDevboxMonitor
            .setAutomaticResetPolicy(settings: settings, enabled: true),
              case .failure(let redemptionFailure) = LinuxDevboxMonitor
            .redeemReset(settings: settings, providerAccountId: "provider-id") else {
            Issue.record("Expected every unavailable VPS reset transport to fail closed")
            return
        }
        #expect(observationFailure.disposition == .rejected)
        #expect(mutationFailure.disposition == .rejected)
        #expect(redemptionFailure.disposition == .rejected)
    }

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

    @Test("remote sessions do not accelerate full readiness checks")
    func remoteSessionsDoNotAccelerateFullReadinessChecks() {
        let now = Date(timeIntervalSince1970: 2_000)
        let recentFullCheck = now.addingTimeInterval(-5)

        #expect(!LinuxDevboxMonitor.shouldRunReadinessCheck(
            now: now,
            lastFullCheckAt: recentFullCheck,
            hasActiveRemoteSession: false,
            force: false
        ))
        #expect(!LinuxDevboxMonitor.shouldRunReadinessCheck(
            now: now,
            lastFullCheckAt: recentFullCheck,
            hasActiveRemoteSession: true,
            force: false
        ))
        #expect(LinuxDevboxMonitor.shouldRunReadinessCheck(
            now: now,
            lastFullCheckAt: recentFullCheck,
            hasActiveRemoteSession: true,
            force: true
        ))
    }

    @Test("readiness probe uses one CLI process")
    func readinessProbeUsesOneCLIProcess() {
        let command = LinuxDevboxMonitor.remoteReadinessCommand()

        #expect(command.components(separatedBy: "codexswitch-cli").count - 1 == 1)
        #expect(command.contains("doctor --json"))
        #expect(!command.contains("auth-diagnostics"))
    }

    @Test("no-op credential convergence preserves the normal readiness cadence")
    func noOpCredentialConvergencePreservesReadinessCadence() {
        #expect(!AppDelegate.shouldForceLinuxDevboxReadinessAfterCredentialSync(
            remoteMutationCommitted: false
        ))
        #expect(AppDelegate.shouldForceLinuxDevboxReadinessAfterCredentialSync(
            remoteMutationCommitted: true
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

    @Test("credential sync preserves the VPS active provider identity")
    func credentialSyncPreservesVPSActiveProviderIdentity() throws {
        let macActive = CodexAccount(
            email: "mac@example.com",
            accessToken: "mac-access",
            refreshToken: "mac-refresh",
            idToken: "mac-id",
            accountId: "mac-account",
            isActive: true
        )
        let vpsActive = CodexAccount(
            email: "vps@example.com",
            accessToken: "vps-access",
            refreshToken: "vps-refresh",
            idToken: "vps-id",
            accountId: "vps-account",
            isActive: false
        )

        let result = LinuxDevboxMonitor.credentialSyncAccountsPreservingRemoteActive(
            accounts: [macActive, vpsActive],
            remoteActiveProviderAccountId: "vps-account"
        )
        let synchronized = try result.get()

        #expect(synchronized.first(where: \.isActive)?.accountId == "vps-account")
        #expect(synchronized.first(where: { $0.accountId == "mac-account" })?.isActive == false)
    }

    @Test("credential sync refuses to guess when the VPS active account is absent")
    func credentialSyncRejectsMissingVPSActiveProviderIdentity() {
        let macActive = CodexAccount(
            email: "mac@example.com",
            accessToken: "mac-access",
            refreshToken: "mac-refresh",
            idToken: "mac-id",
            accountId: "mac-account",
            isActive: true
        )

        let result = LinuxDevboxMonitor.credentialSyncAccountsPreservingRemoteActive(
            accounts: [macActive],
            remoteActiveProviderAccountId: "vps-only-account"
        )

        guard case .failure(let failure) = result else {
            Issue.record("Expected missing VPS identity to reject background sync")
            return
        }
        #expect(failure.credentialSyncDisposition == .rejected)
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

    @Test("credential convergence requires the complete non-secret evidence set")
    func credentialStateEvidenceRequiresExactConvergence() throws {
        var accounts = [
            CodexAccount(
                email: "active@example.com",
                accessToken: "active-access",
                refreshToken: "active-refresh",
                idToken: "active-id",
                accountId: "active-account",
                isActive: true
            ),
            CodexAccount(
                email: "inactive@example.com",
                accessToken: "inactive-access",
                refreshToken: "inactive-refresh",
                idToken: "inactive-id",
                accountId: "inactive-account",
                isActive: false
            ),
        ]
        let matching = LinuxDevboxCredentialStateEvidence(
            accountIdentityFingerprint: LinuxDevboxMonitor
                .credentialAccountIdentityFingerprint(accounts: accounts),
            credentialSetFingerprint: try #require(
                LinuxDevboxMonitor.credentialSetFingerprint(accounts: accounts)
            ),
            activeProviderAccountId: "active-account",
            activeTokenHashPrefix: try #require(
                LinuxDevboxMonitor.activeTokenHashPrefix(accounts: accounts)
            ),
            authMatchesActiveStoreToken: true
        )

        #expect(LinuxDevboxMonitor.credentialStateEvidenceMatches(
            accounts: accounts,
            observed: matching
        ))

        let convergedAccounts = accounts
        accounts[1].refreshToken = "rotated-inactive-refresh"
        #expect(!LinuxDevboxMonitor.credentialStateEvidenceMatches(
            accounts: accounts,
            observed: matching
        ))

        let authMismatch = LinuxDevboxCredentialStateEvidence(
            accountIdentityFingerprint: matching.accountIdentityFingerprint,
            credentialSetFingerprint: matching.credentialSetFingerprint,
            activeProviderAccountId: matching.activeProviderAccountId,
            activeTokenHashPrefix: matching.activeTokenHashPrefix,
            authMatchesActiveStoreToken: false
        )
        #expect(!LinuxDevboxMonitor.credentialStateEvidenceMatches(
            accounts: convergedAccounts,
            observed: authMismatch
        ))
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

    @Test("receipt convergence proof suppresses only exact unchanged divergence")
    func receiptConvergenceProofRequiresExactLocalAndRemoteEvidence() throws {
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
                accessToken: "inactive-old-access-secret",
                refreshToken: "inactive-old-refresh-secret",
                idToken: "inactive-old-id-secret",
                accountId: "inactive-account",
                isActive: false
            ),
        ]
        let credentialFingerprint = LinuxDevboxMonitor.credentialSyncFingerprint(
            accounts: accounts
        )
        let incomingFingerprint = try #require(
            LinuxDevboxMonitor.credentialSetFingerprint(accounts: accounts)
        )
        let identityFingerprint = LinuxDevboxMonitor.credentialAccountIdentityFingerprint(
            accounts: accounts
        )
        let observed = LinuxDevboxCredentialStateEvidence(
            accountIdentityFingerprint: identityFingerprint,
            credentialSetFingerprint: String(repeating: "9", count: 64),
            activeProviderAccountId: "active-account",
            activeTokenHashPrefix: try #require(
                LinuxDevboxMonitor.activeTokenHashPrefix(accounts: accounts)
            ),
            authMatchesActiveStoreToken: true
        )
        let proof = LinuxDevboxCredentialConvergenceProof(
            version: LinuxDevboxCredentialConvergenceProof.schemaVersion,
            credentialFingerprint: credentialFingerprint,
            incomingCredentialSetFingerprint: incomingFingerprint,
            accountIdentityFingerprint: identityFingerprint,
            activeProviderAccountId: "active-account",
            committedEvidence: observed
        )

        #expect(LinuxDevboxMonitor.credentialConvergenceProofMatches(
            proof,
            accounts: accounts,
            credentialFingerprint: credentialFingerprint,
            observed: observed
        ))

        var changedAccounts = accounts
        changedAccounts[1].refreshToken = "inactive-new-refresh-secret"
        #expect(!LinuxDevboxMonitor.credentialConvergenceProofMatches(
            proof,
            accounts: changedAccounts,
            credentialFingerprint: LinuxDevboxMonitor.credentialSyncFingerprint(
                accounts: changedAccounts
            ),
            observed: observed
        ))

        let changedRemote = LinuxDevboxCredentialStateEvidence(
            accountIdentityFingerprint: observed.accountIdentityFingerprint,
            credentialSetFingerprint: String(repeating: "8", count: 64),
            activeProviderAccountId: observed.activeProviderAccountId,
            activeTokenHashPrefix: observed.activeTokenHashPrefix,
            authMatchesActiveStoreToken: true
        )
        #expect(!LinuxDevboxMonitor.credentialConvergenceProofMatches(
            proof,
            accounts: accounts,
            credentialFingerprint: credentialFingerprint,
            observed: changedRemote
        ))

        let encoded = try #require(LinuxDevboxMonitor.encodeCredentialConvergenceProof(proof))
        #expect(LinuxDevboxMonitor.decodeCredentialConvergenceProof(encoded) == proof)
        let serialized = String(decoding: encoded, as: UTF8.self)
        #expect(!serialized.contains("active-access-secret"))
        #expect(!serialized.contains("inactive-old-refresh-secret"))
        #expect(!serialized.contains("@"))
        let injected = Data(
            (String(serialized.dropLast()) + ",\"accessToken\":\"secret\"}").utf8
        )
        #expect(LinuxDevboxMonitor.decodeCredentialConvergenceProof(injected) == nil)
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
            passphraseName: "sync.passphrase",
            operationID: "11111111-1111-4111-8111-111111111111"
        )

        #expect(command.contains("stage='/tmp/codexswitch-auto-sync-fixture'"))
        #expect(command.contains("CODEXSWITCH_IMPORT_PASSPHRASE_FILE='/tmp/codexswitch-auto-sync-fixture/sync.passphrase'"))
        #expect(command.contains("\(LinuxDevboxMonitor.remoteCodexSwitchCLI) update-bundle --preserve-active --receipt-operation-id '11111111-1111-4111-8111-111111111111' '/tmp/codexswitch-auto-sync-fixture/sync.csbundle'"))
        #expect(!command.contains("export PATH="))
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
        let bin = home.appendingPathComponent(
            ".local/share/codexswitch/current",
            isDirectory: true
        )
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
            passphraseName: "sync.passphrase",
            operationID: "11111111-1111-4111-8111-111111111111"
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
        let bin = home.appendingPathComponent(
            ".local/share/codexswitch/current",
            isDirectory: true
        )
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
            operationID: "11111111-1111-4111-8111-111111111111",
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
        let bin = home.appendingPathComponent(
            ".local/share/codexswitch/current",
            isDirectory: true
        )
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
            passphraseName: "sync.passphrase",
            operationID: "11111111-1111-4111-8111-111111111111"
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
            passphraseName: "sync.passphrase",
            operationID: "11111111-1111-4111-8111-111111111111"
        )
        #expect(!command.contains("--ignore-expiry"))
    }

    @Test("manual reset command uses one normalized shell-quoted provider ID")
    func manualResetCommandUsesExactNormalizedProviderID() throws {
        let command = try #require(LinuxDevboxMonitor.remoteManualResetCommand(
            providerAccountId: "  Provider'ID  "
        ))

        #expect(command == "\(LinuxDevboxMonitor.remoteCodexSwitchCLI) redeem-reset 'provider'\\''id' --json")
        #expect(!command.contains("Provider"))
    }

    @Test("manual reset decodes a bounded non-secret success result")
    func manualResetDecodesSuccessResult() throws {
        let executionToken = "reset-success"
        let executionMarker = LinuxDevboxMonitor.remoteExecutionMarker(
            executionToken: executionToken
        )
        let completionMarker = LinuxDevboxMonitor.remoteCompletionMarker(
            executionToken: executionToken
        )
        let json = """
        {
          "account": "not-returned@example.com",
          "accountId": "PROVIDER-ACCOUNT-ID",
          "wasActive": false,
          "submittedReset": true,
          "previousBankedResets": 3,
          "bankedResetsRemaining": 2,
          "remainingPercent": 100
        }
        """

        let result = LinuxDevboxMonitor.redeemResetWithCandidates(
            [["fixture"]],
            providerAccountId: "provider-account-id",
            executionToken: executionToken
        ) { _, arguments, timeout in
            #expect(timeout == LinuxDevboxMonitor.manualResetTimeout)
            #expect(arguments.last?.contains("codexswitch-cli redeem-reset") == true)
            return ProcessRunResult(
                terminationStatus: 0,
                stdout: Data(json.utf8),
                stderr: Data("\(executionMarker)\n\(completionMarker) 0\n".utf8),
                timedOut: false
            )
        }

        let success = try result.get()
        #expect(success.providerAccountId == "provider-account-id")
        #expect(!success.wasActive)
        #expect(success.submittedReset)
        #expect(success.previousBankedResets == 3)
        #expect(success.bankedResetsRemaining == 2)
        #expect(success.remainingPercent == 100)
    }

    @Test("manual reset retries only when the prior SSH process never started")
    func manualResetRetriesOnlyNotStartedCandidate() throws {
        let executionToken = "reset-not-started"
        let executionMarker = LinuxDevboxMonitor.remoteExecutionMarker(
            executionToken: executionToken
        )
        let completionMarker = LinuxDevboxMonitor.remoteCompletionMarker(
            executionToken: executionToken
        )
        var calls = 0
        let result = LinuxDevboxMonitor.redeemResetWithCandidates(
            [["first"], ["second"]],
            providerAccountId: "provider-account-id",
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
                stdout: Data("""
                {"accountId":"provider-account-id","wasActive":false,"submittedReset":false,"previousBankedResets":2,"bankedResetsRemaining":2,"remainingPercent":100}
                """.utf8),
                stderr: Data("\(executionMarker)\n\(completionMarker) 0\n".utf8),
                timedOut: false
            )
        }

        #expect(calls == 2)
        #expect(try result.get().bankedResetsRemaining == 2)

        var failedLaunchCalls = 0
        let failedLaunch = LinuxDevboxMonitor.redeemResetWithCandidates(
            [["first"], ["second"]],
            providerAccountId: "provider-account-id",
            executionToken: "reset-never-started"
        ) { _, _, _ in
            failedLaunchCalls += 1
            return ProcessRunResult(
                terminationStatus: -1,
                stdout: Data(),
                stderr: Data("The SSH executable could not be launched\n".utf8),
                timedOut: false
            )
        }
        #expect(failedLaunchCalls == 2)
        guard case .failure(let failure) = failedLaunch else {
            Issue.record("Expected a pre-execution failure")
            return
        }
        #expect(failure.disposition == .retryablePreExecution)
        #expect(failure.disposition.allowsAutomaticRetry)
    }

    @Test("manual reset never replays a started timeout and reports outcome unknown")
    func manualResetStartedTimeoutIsOutcomeUnknown() {
        let executionToken = "reset-timeout"
        let executionMarker = LinuxDevboxMonitor.remoteExecutionMarker(
            executionToken: executionToken
        )
        var calls = 0
        let result = LinuxDevboxMonitor.redeemResetWithCandidates(
            [["first"], ["second"]],
            providerAccountId: "provider-account-id",
            executionToken: executionToken
        ) { _, _, _ in
            calls += 1
            return ProcessRunResult(
                terminationStatus: -1,
                stdout: Data(),
                stderr: Data("\(executionMarker)\n".utf8),
                timedOut: true
            )
        }

        #expect(calls == 1)
        guard case .failure(let failure) = result else {
            Issue.record("Expected an outcome-unknown failure")
            return
        }
        #expect(failure.disposition == .outcomeUnknown)
        #expect(!failure.disposition.allowsAutomaticRetry)
    }

    @Test("automatic-reset policy commands match the VPS CLI contract")
    func automaticResetPolicyCommandsMatchContract() {
        #expect(LinuxDevboxMonitor.remoteAutomaticResetPolicyGetCommand()
            == "\(LinuxDevboxMonitor.remoteCodexSwitchCLI) automatic-reset-policy get --json")
        #expect(LinuxDevboxMonitor.remoteAutomaticResetPolicySetCommand(enabled: true)
            == "\(LinuxDevboxMonitor.remoteCodexSwitchCLI) automatic-reset-policy set enabled --json")
        #expect(LinuxDevboxMonitor.remoteAutomaticResetPolicySetCommand(enabled: false)
            == "\(LinuxDevboxMonitor.remoteCodexSwitchCLI) automatic-reset-policy set disabled --json")
    }

    @Test("automated VPS commands use the immutable current release CLI")
    func automatedVPSCommandsUseCurrentReleaseCLI() throws {
        #expect(LinuxDevboxMonitor.remoteCodexSwitchCLI.hasPrefix(
            "/usr/bin/flock --shared --no-fork "
        ))
        #expect(LinuxDevboxMonitor.remoteCodexSwitchCLI.contains(
            "runtime-start-install.lock"
        ))
        let commands = [
            LinuxDevboxMonitor.remoteSwapCommand(selector: "account@example.com"),
            LinuxDevboxMonitor.remotePoolAuthorityStatusCommand(),
            try #require(LinuxDevboxMonitor.remoteManualResetCommand(
                providerAccountId: "provider-account-id"
            )),
            LinuxDevboxMonitor.remoteAutomaticResetPolicyGetCommand(),
            LinuxDevboxMonitor.remoteAutomaticResetPolicySetCommand(enabled: true),
            LinuxDevboxMonitor.remoteReadinessCommand(),
        ]

        for command in commands {
            #expect(command.contains(LinuxDevboxMonitor.remoteCodexSwitchCLI))
            #expect(!command.contains("export PATH="))
            #expect(!command.contains("; codexswitch-cli "))
        }
    }

    @Test("automatic-reset policy decoding is fail closed")
    func automaticResetPolicyDecodingIsFailClosed() throws {
        let configured = LinuxDevboxMonitor.decodeAutomaticResetPolicyObservation(Data("""
        {"schemaVersion":1,"automaticRateLimitResetRedemption":true,"state":"configured","authority":"vps"}
        """.utf8))
        #expect(try configured.get().automaticRateLimitResetRedemption)

        for json in [
            "{\"schemaVersion\":2,\"automaticRateLimitResetRedemption\":true,\"state\":\"configured\",\"authority\":\"vps\"}",
            "{\"schemaVersion\":1,\"automaticRateLimitResetRedemption\":true,\"state\":\"missing\",\"authority\":\"vps\"}",
            "{\"schemaVersion\":1,\"automaticRateLimitResetRedemption\":false,\"state\":\"configured\",\"authority\":\"mac\"}",
        ] {
            guard case .failure = LinuxDevboxMonitor.decodeAutomaticResetPolicyObservation(
                Data(json.utf8)
            ) else {
                Issue.record("Expected invalid automatic-reset policy response")
                continue
            }
        }
    }

    @Test("automatic-reset policy set retries only before execution")
    func automaticResetPolicySetRetriesOnlyBeforeExecution() throws {
        let executionToken = "policy-pre-execution"
        let completionMarker = LinuxDevboxMonitor.remoteCompletionMarker(
            executionToken: executionToken
        )
        var calls = 0
        let result = LinuxDevboxMonitor.setAutomaticResetPolicyWithCandidates(
            [["first"], ["second"]],
            enabled: true,
            executionToken: executionToken
        ) { _, _, timeout in
            calls += 1
            #expect(timeout == LinuxDevboxMonitor.automaticResetPolicyTimeout)
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
                stdout: Data("""
                {"schemaVersion":1,"automaticRateLimitResetRedemption":true,"state":"configured","authority":"vps"}
                """.utf8),
                stderr: Data("\(completionMarker) 0\n".utf8),
                timedOut: false
            )
        }

        #expect(calls == 2)
        #expect(try result.get().automaticRateLimitResetRedemption)
    }

    @Test("automatic-reset policy set never replays an ambiguous started request")
    func automaticResetPolicySetDoesNotReplayAmbiguousStartedRequest() {
        let executionToken = "policy-ambiguous"
        let executionMarker = LinuxDevboxMonitor.remoteExecutionMarker(
            executionToken: executionToken
        )
        var calls = 0
        let result = LinuxDevboxMonitor.setAutomaticResetPolicyWithCandidates(
            [["first"], ["second"]],
            enabled: true,
            executionToken: executionToken
        ) { _, _, _ in
            calls += 1
            return ProcessRunResult(
                terminationStatus: -1,
                stdout: Data(),
                stderr: Data("\(executionMarker)\n".utf8),
                timedOut: true
            )
        }

        #expect(calls == 1)
        guard case .failure(let failure) = result else {
            Issue.record("Expected an outcome-unknown policy failure")
            return
        }
        #expect(failure.disposition == .outcomeUnknown)
        #expect(!failure.disposition.allowsAutomaticMutationRetry)
    }

    @Test("automatic-reset policy set requires the requested authoritative value")
    func automaticResetPolicySetRequiresRequestedValue() {
        let executionToken = "policy-mismatch"
        let completionMarker = LinuxDevboxMonitor.remoteCompletionMarker(
            executionToken: executionToken
        )
        let result = LinuxDevboxMonitor.setAutomaticResetPolicyWithCandidates(
            [["fixture"]],
            enabled: true,
            executionToken: executionToken
        ) { _, _, _ in
            ProcessRunResult(
                terminationStatus: 0,
                stdout: Data("""
                {"schemaVersion":1,"automaticRateLimitResetRedemption":false,"state":"configured","authority":"vps"}
                """.utf8),
                stderr: Data("\(completionMarker) 0\n".utf8),
                timedOut: false
            )
        }

        guard case .failure(let failure) = result else {
            Issue.record("Expected an outcome-unknown policy mismatch")
            return
        }
        #expect(failure.disposition == .outcomeUnknown)
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
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "authority-reconciliation"))
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
        #expect(!AppDelegate.shouldBypassLinuxDevboxCredentialSyncThrottle(for: "authority-reconciliation"))
        #expect(AppDelegate.linuxDevboxCredentialSyncThrottleInterval(for: "quota-update") == 60)
        #expect(AppDelegate.linuxDevboxCredentialSyncThrottleInterval(for: "queued-after-quota-update") == 60)
        #expect(AppDelegate.linuxDevboxCredentialSyncThrottleInterval(for: "load-restore") == 10 * 60)
        #expect(AppDelegate.linuxDevboxCredentialSyncThrottleInterval(for: "authority-reconciliation") == 60)
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
