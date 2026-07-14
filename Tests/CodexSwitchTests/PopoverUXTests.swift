import Foundation
import Testing
@testable import CodexSwitch

@Suite("Popover UX")
struct PopoverUXTests {
    @Test("Host ownership presentation keeps all three fields visible")
    @MainActor
    func hostOwnershipFieldsRemainSimultaneous() {
        let labels = AccountCardView.hostOwnershipLabels(
            isConfigured: true,
            isRuntimeCurrent: true,
            vpsRuntimePresentation: .current
        )

        #expect(labels.macConfigured == "Mac Configured")
        #expect(labels.macRuntime == "Mac Runtime Current")
        #expect(labels.vpsRuntime == "VPS Runtime Current")
        #expect(StatusBarController.accountScopeLabel(
            configuredAccountId: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            runtimeCurrentAccountId: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        ) == "Mac Configured; Mac Runtime Current")
    }

    @Test("Popover keeps native menu-bar anchor and installs outside-click monitors")
    func popoverKeepsNativeAnchorAndDismissesOnOutsideClick() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(source.contains("popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)"))
        #expect(source.contains("startPopoverDismissalMonitoring()"))
        #expect(source.contains("NSEvent.addLocalMonitorForEvents"))
        #expect(source.contains("NSEvent.addGlobalMonitorForEvents"))
        #expect(source.contains("closePopoverIfNeeded(forLocalEvent:"))
        #expect(source.contains("if frame.minX < minX"))
        #expect(source.contains("} else if frame.maxX > maxX {"))
        #expect(source.contains("let verticalGap = buttonScreenFrame.minY - frame.maxY"))
        #expect(source.contains("frame.origin.y += verticalGap + desiredArrowOverlap"))
        #expect(!source.contains("targetRightEdge"))
        #expect(!source.contains("frame.origin.y = min(frame.origin.y, visibleFrame.maxY - frame.height - screenPadding)"))
    }

    @Test("Account card shows full email on hover")
    func accountCardShowsFullEmailOnHover() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/Views/AccountCardView.swift",
            encoding: .utf8
        )

        #expect(source.contains("@State private var isHovering = false"))
        #expect(source.contains("private var emailHoverOverlay: some View"))
        #expect(source.contains("Text(account.email)"))
        #expect(source.contains("AccountCardHoverTrackingView(email: account.email, isHovering: $isHovering)"))
        #expect(source.contains("NSTrackingArea("))
        #expect(source.contains("toolTip = email"))
        #expect(source.contains(".onHover { hovering in"))
        #expect(source.contains(".help(account.email)"))
    }

    @Test("Status bar menu captures click type before async restart menu handling")
    func statusBarMenuCapturesClickTypeSynchronously() throws {
        let source = try String(
            contentsOfFile: "Sources/CodexSwitch/App/AppDelegate.swift",
            encoding: .utf8
        )

        #expect(source.contains("let eventType = NSApp.currentEvent?.type"))
        #expect(source.contains("let isRightClick = eventType == .rightMouseUp"))
        #expect(!source.contains("let isRightClick = NSApp.currentEvent?.type == .rightMouseUp"))
    }

    @Test("Pooled metrics include only accounts reporting the requested window")
    @MainActor
    func pooledMetricsRespectOptionalWindows() {
        let weeklyOnly = account(
            snapshot: snapshot(windows: [window(kind: .weekly, durationSeconds: 7 * 86_400)])
        )

        let fiveHour = PooledUsageMeterView.metric(for: .fiveHour, accounts: [weeklyOnly])
        let weekly = PooledUsageMeterView.metric(for: .weekly, accounts: [weeklyOnly])

        #expect(fiveHour.reportingCount == 0)
        #expect(fiveHour.totalCapacity == 0)
        #expect(weekly.reportingCount == 1)
        #expect(weekly.totalCapacity == 100)
        #expect(weekly.pooledPercent == 75)
    }

    @Test("Pooled metrics retain both legacy windows")
    @MainActor
    func pooledMetricsSupportLegacySnapshots() {
        let legacy = QuotaSnapshot(
            fiveHour: QuotaWindow(
                usedPercent: 20,
                windowDurationMins: 300,
                resetsAt: Date(timeIntervalSince1970: 1_800_018_000)
            ),
            weekly: QuotaWindow(
                usedPercent: 30,
                windowDurationMins: 10_080,
                resetsAt: Date(timeIntervalSince1970: 1_800_604_800)
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let legacyAccount = account(snapshot: legacy)

        #expect(PooledUsageMeterView.metric(for: .fiveHour, accounts: [legacyAccount]).reportingCount == 1)
        #expect(PooledUsageMeterView.metric(for: .weekly, accounts: [legacyAccount]).reportingCount == 1)
    }

    @Test("Unknown and denied snapshots do not create semantic pool capacity")
    @MainActor
    func pooledMetricsDoNotFabricateCapacity() {
        let unknown = account(
            snapshot: snapshot(windows: [window(kind: .unknown, durationSeconds: 4 * 3_600)])
        )
        let denied = account(snapshot: snapshot(allowed: false, limitReached: true, windows: []))

        for kind in [QuotaWindowKind.fiveHour, .weekly] {
            let metric = PooledUsageMeterView.metric(for: kind, accounts: [unknown, denied])
            #expect(metric.reportingCount == 0)
            #expect(metric.totalCapacity == 0)
            #expect(metric.totalRemaining == 0)
        }
    }

    @Test("Global denial stays distinct from healthy-looking windows")
    @MainActor
    func pooledDenialDoesNotBecomeWindowExhaustion() {
        let denied = account(
            snapshot: snapshot(
                allowed: false,
                limitReached: true,
                windows: [window(kind: .weekly, durationSeconds: 7 * 86_400)]
            )
        )
        let summary = PooledUsageMeterView.stateSummary(for: [denied])
        let weekly = PooledUsageMeterView.metric(for: .weekly, accounts: [denied])

        #expect(PooledUsageMeterView.quotaState(for: denied.quotaSnapshot!) == .denied)
        #expect(summary.deniedCount == 1)
        #expect(summary.exhaustedCount == 0)
        #expect(summary.unknownCount == 0)
        #expect(weekly.reportingCount == 0)
        #expect(weekly.totalCapacity == 0)
        #expect(weekly.nextReset == nil)
        #expect(
            PooledUsageMeterView.naturalWeeklyResetDate(accounts: [denied])
                == denied.quotaSnapshot?.weekly?.resetsAt
        )
    }

    @Test("Successful windowless snapshots stay neutral and unknown")
    @MainActor
    func pooledWindowlessSnapshotIsUnknown() {
        let windowless = account(snapshot: snapshot(allowed: true, limitReached: false, windows: []))
        let summary = PooledUsageMeterView.stateSummary(for: [windowless])

        #expect(PooledUsageMeterView.quotaState(for: windowless.quotaSnapshot!) == .unknown)
        #expect(summary.deniedCount == 0)
        #expect(summary.exhaustedCount == 0)
        #expect(summary.unknownCount == 1)
        #expect(summary.usableCount == 0)
        #expect(PooledUsageMeterView.naturalWeeklyResetDate(accounts: [windowless]) == nil)
    }

    @Test("Observed weekly reset metadata produces the popover reset fallback")
    @MainActor
    func nextWeeklyResetIncludesGlobalExhaustion() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let denied = account(
            snapshot: snapshot(
                allowed: false,
                limitReached: true,
                windows: [window(kind: .weekly, durationSeconds: 7 * 86_400)]
            ),
            email: "denied@example.com"
        )
        let windowless = account(
            snapshot: snapshot(allowed: true, limitReached: false, windows: []),
            email: "unknown@example.com"
        )
        let exhausted = account(
            snapshot: snapshot(
                windows: [window(kind: .weekly, durationSeconds: 7 * 86_400, usedPercent: 100)]
            ),
            email: "exhausted@example.com"
        )

        let absent = PopoverContentView.nextWeeklyResetAccount(from: [denied, windowless], now: now)
        #expect(absent?.account.email == "denied@example.com")
        let next = PopoverContentView.nextWeeklyResetAccount(from: [denied, windowless, exhausted], now: now)
        let exhaustedSummary = PooledUsageMeterView.stateSummary(for: [exhausted])
        #expect(next != nil)
        #expect(exhaustedSummary.deniedCount == 0)
        #expect(exhaustedSummary.exhaustedCount == 1)
        #expect(exhaustedSummary.unknownCount == 0)
        #expect(PooledUsageMeterView.naturalWeeklyResetDate(accounts: [exhausted]) != nil)
    }

    @Test("Exhausted weekly window blocks positive five-hour runway")
    @MainActor
    func weeklyExhaustionTakesRunwayPrecedence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = Date(timeIntervalSince1970: 1_800_100_000)
        let blocked = account(
            snapshot: snapshot(
                windows: [
                    window(kind: .fiveHour, durationSeconds: 5 * 3_600, usedPercent: 50),
                    window(kind: .weekly, durationSeconds: 7 * 86_400, usedPercent: 100),
                ]
            )
        )

        #expect(PooledUsageMeterView.quotaState(for: blocked.quotaSnapshot!) == .exhausted)
        #expect(PooledUsageMeterView.estimatedRunway(for: .fiveHour, accounts: [blocked], now: now) == nil)
        #expect(PooledUsageMeterView.runwayPresentation(accounts: [blocked], now: now) == .weeklyRecovery(resetAt))
    }

    @Test("Auto-swap threshold blocks pooled runway before hard exhaustion")
    @MainActor
    func autoSwapThresholdUsesDomainBlockingContract() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let resetAt = Date(timeIntervalSince1970: 1_800_100_000)
        let weeklyAtThreshold = window(kind: .weekly, durationSeconds: 7 * 86_400, usedPercent: 99)
        let fiveHourAtThreshold = window(kind: .fiveHour, durationSeconds: 5 * 3_600, usedPercent: 99)

        let weeklyBlocked = account(
            snapshot: snapshot(
                windows: [
                    window(kind: .fiveHour, durationSeconds: 5 * 3_600, usedPercent: 50),
                    weeklyAtThreshold,
                ]
            )
        )
        let siblingBlocked = account(
            snapshot: snapshot(
                windows: [
                    fiveHourAtThreshold,
                    window(kind: .weekly, durationSeconds: 7 * 86_400, usedPercent: 50),
                ]
            )
        )

        #expect(!weeklyAtThreshold.isExhausted)
        #expect(weeklyAtThreshold.shouldAutoSwapAway)
        #expect(PooledUsageMeterView.quotaState(for: weeklyBlocked.quotaSnapshot!) == .exhausted)
        #expect(PooledUsageMeterView.estimatedRunway(for: .fiveHour, accounts: [weeklyBlocked], now: now) == nil)
        #expect(PooledUsageMeterView.runwayPresentation(accounts: [weeklyBlocked], now: now) == .weeklyRecovery(resetAt))

        #expect(!fiveHourAtThreshold.isExhausted)
        #expect(fiveHourAtThreshold.shouldAutoSwapAway)
        #expect(PooledUsageMeterView.quotaState(for: siblingBlocked.quotaSnapshot!) == .exhausted)
        #expect(PooledUsageMeterView.estimatedRunway(for: .weekly, accounts: [siblingBlocked], now: now) == nil)
        #expect(PooledUsageMeterView.runwayPresentation(accounts: [siblingBlocked], now: now) == .unavailable)
    }

    private func snapshot(
        allowed: Bool? = true,
        limitReached: Bool? = false,
        windows: [QuotaWindow]
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            allowed: allowed,
            limitReached: limitReached,
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            windows: windows
        )
    }

    private func window(
        kind: QuotaWindowKind,
        durationSeconds: Int,
        usedPercent: Double = 25
    ) -> QuotaWindow {
        QuotaWindow(
            kind: kind,
            durationSeconds: durationSeconds,
            usedPercent: usedPercent,
            resetsAt: Date(timeIntervalSince1970: 1_800_100_000),
            source: QuotaWindowSourceMetadata(rateLimit: .main, slot: .primary)
        )
    }

    private func account(
        snapshot: QuotaSnapshot,
        email: String = "quota@example.com"
    ) -> CodexAccount {
        CodexAccount(
            email: email,
            accessToken: "access",
            refreshToken: "refresh",
            idToken: "id",
            accountId: UUID().uuidString,
            quotaSnapshot: snapshot,
            planType: "plus"
        )
    }
}
