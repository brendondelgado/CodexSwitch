import Foundation
import Testing
@testable import CodexSwitch

@Suite("Remote reset redemption results and mirrored redemption detection")
struct RateLimitResetRemoteRedemptionTests {
    // MARK: - VPS CLI failure contract

    @Test("Rejection reason is taken from the CLI's anyhow error chain on stderr")
    func rejectionReasonComesFromStderr() {
        let stderr = """
        Warning: Permanently added 'signul-vps' (ED25519) to the list of known hosts.
        Error: banked reset redemption could not acquire the account-mutation lease

        Caused by:
            0: runtime activation is busy: another process owns the cross-process runtime-activation lease
            1: lock held
        """
        let detail = LinuxDevboxMonitor.manualResetFailureDetail(fromStderr: Data(stderr.utf8))
        #expect(detail == "banked reset redemption could not acquire the account-mutation lease: runtime activation is busy: another process owns the cross-process runtime-activation lease: lock held")

        let single = LinuxDevboxMonitor.manualResetFailureDetail(fromStderr: Data("""
        Error: banked reset redemption requires a paid account; a@example.com is not paid
        """.utf8))
        #expect(single == "banked reset redemption requires a paid account; a@example.com is not paid")
    }

    @Test("Stderr without an error line, control characters, and oversize text are bounded")
    func rejectionReasonIsBoundedAndSanitized() {
        #expect(LinuxDevboxMonitor.manualResetFailureDetail(fromStderr: Data()) == nil)
        #expect(LinuxDevboxMonitor.manualResetFailureDetail(
            fromStderr: Data("ssh: connect to host timed out\n".utf8)
        ) == nil)
        #expect(LinuxDevboxMonitor.manualResetFailureDetail(
            fromStderr: Data("Error:   \n".utf8)
        ) == nil)
        let control = LinuxDevboxMonitor.manualResetFailureDetail(
            fromStderr: Data("Error: bad\u{1B}[31m state\u{7F}\n".utf8)
        )
        #expect(control == "bad[31m state")
        let long = LinuxDevboxMonitor.manualResetFailureDetail(
            fromStderr: Data("Error: \(String(repeating: "x", count: 1_000))".utf8)
        )
        #expect(long?.count == LinuxDevboxMonitor.maximumManualResetFailureDetailCharacters)
        #expect(long?.hasSuffix("…") == true)
        let invalidUTF8 = LinuxDevboxMonitor.manualResetFailureDetail(
            fromStderr: Data([0x45, 0x72, 0x72, 0x6F, 0x72, 0x3A, 0x20, 0xFF, 0x61])
        )
        #expect(invalidUTF8?.hasSuffix("a") == true)
    }

    @Test("A completed structured rejection surfaces the stderr reason and stays retryable")
    func structuredRejectionCarriesReason() {
        let requestID = UUID()
        let executionToken = "reset-rejected-reason"
        let executionMarker = LinuxDevboxMonitor.remoteExecutionMarker(executionToken: executionToken)
        let completionMarker = LinuxDevboxMonitor.remoteCompletionMarker(executionToken: executionToken)
        let json = """
        {"schemaVersion":1,"status":"error","accountId":"provider-account-id","requestId":"\(requestID.uuidString)","disposition":"rejected","message":"\(LinuxDevboxMonitor.remoteManualResetRejectedMessage)"}
        """
        let stderr = """
        \(executionMarker)
        Error: runtime activation is busy: another process owns the cross-process runtime-activation lease
        \(completionMarker) 1
        """
        let result = LinuxDevboxMonitor.redeemResetWithCandidates(
            [["fixture"]],
            providerAccountId: "provider-account-id",
            requestID: requestID,
            executionToken: executionToken
        ) { _, _, _ in
            ProcessRunResult(
                terminationStatus: 1,
                stdout: Data(json.utf8),
                stderr: Data(stderr.utf8),
                timedOut: false
            )
        }
        guard case .failure(let failure) = result else {
            Issue.record("Expected a structured rejection")
            return
        }
        #expect(failure.disposition == .rejected)
        #expect(failure.message == LinuxDevboxMonitor.remoteManualResetRejectedMessage)
        #expect(failure.detail?.hasPrefix("runtime activation is busy") == true)
        #expect(failure.isRuntimeActivationBusyRejection)
        #expect(failure.userFacingMessage.contains("nothing was spent"))
        #expect(failure.userFacingMessage.contains("runtime activation is busy"))
    }

    @Test("Busy detection never applies to unknown outcomes or other rejections")
    func busyDetectionIsScopedToRejections() {
        let busy = "runtime activation is busy: lease held"
        #expect(!LinuxDevboxManualResetFailure(
            message: LinuxDevboxMonitor.remoteManualResetOutcomeUnknownMessage,
            disposition: .outcomeUnknown,
            detail: busy
        ).isRuntimeActivationBusyRejection)
        #expect(!LinuxDevboxManualResetFailure(
            message: LinuxDevboxMonitor.remoteManualResetRejectedMessage,
            disposition: .rejected,
            detail: "reset inventory is stale"
        ).isRuntimeActivationBusyRejection)
        #expect(!LinuxDevboxManualResetFailure(
            message: LinuxDevboxMonitor.remoteManualResetRejectedMessage,
            disposition: .rejected
        ).isRuntimeActivationBusyRejection)
        // Without a stderr reason the generic envelope text is kept.
        #expect(LinuxDevboxManualResetFailure(
            message: LinuxDevboxMonitor.remoteManualResetRejectedMessage,
            disposition: .rejected
        ).userFacingMessage == LinuxDevboxMonitor.remoteManualResetRejectedMessage)
    }

    @Test("A busy rejection is retried exactly once")
    func busyRejectionRetriesOnce() {
        let busy = LinuxDevboxManualResetFailure(
            message: LinuxDevboxMonitor.remoteManualResetRejectedMessage,
            disposition: .rejected,
            detail: "runtime activation is busy: another process owns the lease"
        )
        #expect(AppDelegate.remoteRateLimitResetShouldRetry(failure: busy, completedAttempts: 1))
        #expect(!AppDelegate.remoteRateLimitResetShouldRetry(failure: busy, completedAttempts: 2))
        let unknown = LinuxDevboxManualResetFailure(
            message: LinuxDevboxMonitor.remoteManualResetOutcomeUnknownMessage,
            disposition: .outcomeUnknown,
            detail: busy.detail
        )
        #expect(!AppDelegate.remoteRateLimitResetShouldRetry(failure: unknown, completedAttempts: 1))
    }

    @Test("A mismatched envelope stays outcome-unknown but still carries the stderr reason")
    func mismatchedEnvelopeKeepsReason() {
        let failure = LinuxDevboxMonitor.decodeManualResetFailure(
            Data("not-json".utf8),
            expectedProviderAccountId: "provider-account-id",
            stderr: Data("Error: journal unreadable\n".utf8)
        )
        #expect(failure.disposition == .outcomeUnknown)
        #expect(failure.detail == "journal unreadable")
        #expect(failure.userFacingMessage.contains("journal unreadable"))
    }

    // MARK: - Mirrored (VPS/T3) redemption detection

    @Test("A mirrored count drop is detected as a redemption")
    func mirroredCountDropIsRedemption() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = bank(ids: ["a", "b"], fetchedAt: now.addingTimeInterval(-60))
        let current = account(bank: bank(ids: ["b"], fetchedAt: now))
        let detected = AppDelegate.accountsWithMirroredRateLimitResetRedemption(
            previous: ["provider-1": previous],
            current: [current],
            now: now
        )
        #expect(detected.map(\.id) == [current.id])
    }

    @Test("A consumption hidden by a simultaneous new grant is detected by credit ID")
    func consumedCreditHiddenByNewGrantIsRedemption() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = bank(ids: ["a", "b"], fetchedAt: now.addingTimeInterval(-60))
        let current = account(bank: bank(ids: ["b", "c"], fetchedAt: now))
        #expect(AppDelegate.accountsWithMirroredRateLimitResetRedemption(
            previous: ["provider-1": previous],
            current: [current],
            now: now
        ).count == 1)
    }

    @Test("Grants, natural expiry, unchanged, older, and unknown banks are not redemptions")
    func nonRedemptionChangesAreIgnored() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = bank(ids: ["a", "b"], fetchedAt: now.addingTimeInterval(-60))
        let cases: [RateLimitResetBank] = [
            bank(ids: ["a", "b", "c"], fetchedAt: now),
            bank(ids: ["a", "b"], fetchedAt: now),
            bank(ids: ["b"], fetchedAt: now.addingTimeInterval(-120)),
        ]
        for refreshed in cases {
            #expect(AppDelegate.accountsWithMirroredRateLimitResetRedemption(
                previous: ["provider-1": previous],
                current: [account(bank: refreshed)],
                now: now
            ).isEmpty)
        }
        let expiringPrevious = bank(
            ids: ["a", "b"],
            expiring: ["a": now.addingTimeInterval(-30)],
            fetchedAt: now.addingTimeInterval(-60)
        )
        #expect(expiringPrevious.availableCount == 2)
        #expect(AppDelegate.accountsWithMirroredRateLimitResetRedemption(
            previous: ["provider-1": expiringPrevious],
            current: [account(bank: bank(ids: ["b"], fetchedAt: now))],
            now: now
        ).isEmpty)
        // No previous bank (first observation) and no provider identity.
        #expect(AppDelegate.accountsWithMirroredRateLimitResetRedemption(
            previous: [:],
            current: [account(bank: bank(ids: [], fetchedAt: now))],
            now: now
        ).isEmpty)
        #expect(AppDelegate.accountsWithMirroredRateLimitResetRedemption(
            previous: ["provider-1": previous],
            current: [account(providerAccountId: "  ", bank: bank(ids: [], fetchedAt: now))],
            now: now
        ).isEmpty)
    }

    @Test("Bank index uses normalized provider identity and skips accounts without banks")
    func bankIndexIsNormalized() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let withBank = account(providerAccountId: " PROVIDER-1 ", bank: bank(ids: ["a"], fetchedAt: now))
        let withoutBank = account(providerAccountId: "provider-2", bank: nil)
        let index = AppDelegate.rateLimitResetBanksByProviderAccountId([withBank, withoutBank])
        #expect(Set(index.keys) == ["provider-1"])
    }

    // MARK: - Log diagnostics

    @Test("Inventory and quota failure descriptions carry status without secrets")
    func failureDescriptionsCarryStatus() {
        #expect(AppDelegate.rateLimitResetInventoryFailureDescription(.httpError(503)) == "http_503")
        #expect(AppDelegate.rateLimitResetInventoryFailureDescription(
            .transport("line one\nline two")
        ) == "transport: line one line two")
        #expect(AppDelegate.rateLimitResetInventoryFailureDescription(
            .transport(String(repeating: "y", count: 500))
        ).count == 200)
        #expect(AppDelegate.pollerErrorDescription(PollerError.httpError(500)) == "http_500")
        #expect(AppDelegate.pollerErrorDescription(PollerError.tokenExpired) == "http_401")
        #expect(AppDelegate.pollerErrorDescription(PollerError.usageUnavailable) == "usage_unavailable")
    }

    // MARK: - Fixtures

    private func account(
        providerAccountId: String = "provider-1",
        bank: RateLimitResetBank?
    ) -> CodexAccount {
        CodexAccount(
            id: UUID(),
            email: "account@example.com",
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: providerAccountId,
            rateLimitResetBank: bank,
            isActive: false
        )
    }

    private func bank(
        ids: [String],
        expiring: [String: Date] = [:],
        fetchedAt: Date
    ) -> RateLimitResetBank {
        let credits = ids.map { id in
            RateLimitResetCredit(
                id: id,
                resetType: "usage",
                status: "available",
                grantedAt: fetchedAt.addingTimeInterval(-3_600),
                expiresAt: expiring[id] ?? fetchedAt.addingTimeInterval(7 * 24 * 60 * 60),
                redeemedAt: nil,
                title: nil,
                description: nil
            )
        }
        let availableCount = credits.filter { $0.isAvailable(at: fetchedAt) }.count
        return RateLimitResetBank(
            availableCount: availableCount,
            totalEarnedCount: ids.count,
            credits: credits,
            fetchedAt: fetchedAt
        )
    }
}
