import Foundation

struct LinuxDevboxResetObservation: Equatable, Sendable {
    let states: [LinuxDevboxAccountState]
    let settings: LinuxDevboxMonitorSettings
    let observedAt: Date

    func authorization(
        for providerAccountId: String,
        settings currentSettings: LinuxDevboxMonitorSettings,
        now: Date
    ) -> RateLimitResetCoordinatorAuthorization {
        guard settings == currentSettings else {
            return .blocked("VPS settings changed; refresh reset status before redeeming")
        }
        return LinuxDevboxMonitor.manualResetCompatibilityAuthorization(
            states: states,
            observedAt: observedAt,
            providerAccountId: providerAccountId,
            now: now
        )
    }
}
