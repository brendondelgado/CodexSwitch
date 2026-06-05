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
        #expect(LinuxDevboxMonitor.activeAccountSyncMode(hasActiveRemoteSession: false) == .statusOnly)
        #expect(LinuxDevboxMonitor.shouldRunMacAutoSwap(
            hasActiveRemoteSession: false,
            accountMirrorHealthy: false
        ))
    }

    @Test("active VPS mirror delegates auto swap only while account mirror is healthy")
    func activeVPSMirrorDelegatesAutoSwapOnlyWhileAccountMirrorIsHealthy() {
        #expect(LinuxDevboxMonitor.activeAccountSyncMode(hasActiveRemoteSession: true) == .mirrorVPS)
        #expect(!LinuxDevboxMonitor.shouldRunMacAutoSwap(
            hasActiveRemoteSession: true,
            accountMirrorHealthy: true
        ))
        #expect(LinuxDevboxMonitor.shouldRunMacAutoSwap(
            hasActiveRemoteSession: true,
            accountMirrorHealthy: false
        ))
    }

    @Test("local Codex desktop keeps Mac auto swap authority during active VPS sessions")
    func localCodexDesktopKeepsMacAutoSwapAuthorityDuringActiveVPSSessions() {
        #expect(LinuxDevboxMonitor.shouldRunMacAutoSwap(
            hasActiveRemoteSession: true,
            accountMirrorHealthy: true,
            localDesktopRuntimeRunning: true
        ))
    }

    @Test("account state decoding accepts mixed date formats from VPS store")
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
        #expect(states[0].quotaSnapshot?.fiveHour.shouldAutoSwapAway == true)
        #expect(states[1].isActive)
        #expect(states[1].quotaSnapshot?.fiveHour.usedPercent == 2)
    }

    @Test("credential sync fingerprint changes only when credentials change")
    func credentialSyncFingerprintTracksCredentialsOnly() {
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
        account.lastRefreshed = Date(timeIntervalSince1970: 2_000)
        #expect(LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account]) == original)

        account.refreshToken = "refresh-2"
        #expect(LinuxDevboxMonitor.credentialSyncFingerprint(accounts: [account]) != original)
    }

    @Test("credential sync command imports bundle and removes temporary secrets")
    func credentialSyncCommandImportsBundleAndCleansUp() {
        let command = LinuxDevboxMonitor.remoteCredentialSyncCommand(
            bundlePath: "~/.codexswitch/incoming/sync.csbundle",
            passphrasePath: "~/.codexswitch/incoming/sync.passphrase"
        )

        #expect(command.contains("CODEXSWITCH_IMPORT_PASSPHRASE_FILE='~/.codexswitch/incoming/sync.passphrase'"))
        #expect(command.contains("codexswitch-cli update-bundle '~/.codexswitch/incoming/sync.csbundle' --ignore-expiry"))
        #expect(command.contains("rm -f '~/.codexswitch/incoming/sync.csbundle' '~/.codexswitch/incoming/sync.passphrase'"))
        #expect(!command.contains("systemctl --user kill --signal=HUP signul-codex-app-server.service"))
        #expect(!command.contains("pgrep -f 'codex app-server'"))
        #expect(command.contains("codex_app_server_reload=not_reloaded_credential_sync_only"))
        #expect(command.contains("exit $status"))
    }

    @Test("credential sync contexts exclude quota and status persistence")
    func credentialSyncContextsExcludeQuotaAndStatusPersistence() {
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "token-refresh"))
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "swap"))
        #expect(AppDelegate.shouldSyncLinuxDevboxCredentials(for: "reauth-account"))
        #expect(!AppDelegate.shouldSyncLinuxDevboxCredentials(for: "quota-update"))
        #expect(!AppDelegate.shouldSyncLinuxDevboxCredentials(for: "quota-primed"))
        #expect(!AppDelegate.shouldSyncLinuxDevboxCredentials(for: "subscription-info"))
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
