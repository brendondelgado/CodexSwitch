import Foundation

enum AccountActivationCredentialCommitResult: Equatable, Sendable {
    case committed
    case authorizationLost
    case failed(String)
}

actor AccountActivationCredentialCommitter {
    func persistAuth(
        for account: CodexAccount,
        path: String,
        permit: AccountActivationEffectPermit
    ) -> AccountActivationCredentialCommitResult {
        guard permit.isCurrentlyAuthorized() else {
            return .authorizationLost
        }
        do {
            try SwapEngine.writeAuthFile(for: account, path: path)
            return .committed
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
