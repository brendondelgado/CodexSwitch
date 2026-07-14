import Foundation

enum AccountActivationRecoveryCoordinator {
    static func configuredAccountRecovery(
        accounts: [CodexAccount],
        observedProviderAccountId: String?
    ) -> ConfiguredAccountRecovery {
        if let observedProviderAccountId {
            let observedMatches = accounts.filter {
                $0.accountId == observedProviderAccountId
            }
            if observedMatches.count == 1, let match = observedMatches.first {
                return .recovered(match.id)
            }
            return .ambiguous
        }

        let selected = accounts.filter(\.isActive)
        if selected.count == 1, let account = selected.first {
            return .recovered(account.id)
        }
        return accounts.isEmpty ? .noConfiguredAccount : .ambiguous
    }

    static func manualReviewSelectionIsUnambiguous(
        accounts: [CodexAccount],
        targetAccountId: UUID?
    ) -> Bool {
        guard let targetAccountId else { return false }
        return accounts.filter(\.isActive).map(\.id) == [targetAccountId]
    }
}
