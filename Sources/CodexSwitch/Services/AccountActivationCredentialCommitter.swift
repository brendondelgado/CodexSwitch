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
        permit: AccountActivationEffectPermit,
        recoveryWitness: AuthorityConflictRecoveryWitness? = nil,
        committedStoreSnapshot: SecureAtomicFileTransaction.Snapshot? = nil,
        now: @Sendable () -> Date = { Date() }
    ) -> AccountActivationCredentialCommitResult {
        guard permit.isCurrentlyAuthorized() else {
            return .authorizationLost
        }
        do {
            if let witness = recoveryWitness {
                guard witness.authPath == path, witness.target.id == account.id,
                      witness.target.accountId == account.accountId,
                      witness.target.accessToken == account.accessToken,
                      witness.target.refreshToken == account.refreshToken,
                      witness.target.idToken == account.idToken,
                      permit.targetAccountId == account.id,
                      permit.requiredPhase == .preparing,
                      witness.authorizes(at: now()), let committedStoreSnapshot,
                      AccountActivationCrossProcessLeaseContext.holds(
                        URL(fileURLWithPath: witness.storePath).deletingLastPathComponent()
                            .appendingPathComponent("accounts.runtime-activation.lock")
                      ) else { return .authorizationLost }
                try SecureAtomicFileTransaction(path: witness.storePath).withExclusiveLock { store in
                    guard try store.read(allowMissing: false) == committedStoreSnapshot else {
                        throw AccountActivationCoordinatorError.authorizationRevoked
                    }
                    try SwapEngine.writeAuthFile(
                        for: account, path: path, expectedSnapshot: witness.authSnapshot,
                        authorizeEffect: { witness.authorizes(at: now()) && permit.isCurrentlyAuthorized() }
                    )
                }
            } else {
                try SwapEngine.writeAuthFile(
                    for: account, path: path,
                    authorizeEffect: { permit.isCurrentlyAuthorized() }
                )
            }
            return .committed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func persistRecoveryAccountStore(
        witness: AuthorityConflictRecoveryWitness,
        permit: AccountActivationEffectPermit,
        now: @Sendable () -> Date = { Date() }
    ) -> SecureAtomicFileTransaction.Snapshot? {
        guard witness.authorizes(at: now()), permit.targetAccountId == witness.target.id,
              permit.requiredPhase == .preparing, permit.isCurrentlyAuthorized(),
              AccountActivationCrossProcessLeaseContext.holds(
                URL(fileURLWithPath: witness.storePath).deletingLastPathComponent()
                    .appendingPathComponent("accounts.runtime-activation.lock")
              ) else { return nil }
        do {
            let bytes = try Self.recoveryStoreData(witness)
            return try SecureAtomicFileTransaction(path: witness.storePath).withExclusiveLock { store in
                guard try store.read(allowMissing: false) == witness.storeSnapshot else {
                    throw AccountActivationCoordinatorError.authorizationRevoked
                }
                return try SecureAtomicFileTransaction(path: witness.authPath).withExclusiveLock { auth in
                    guard try auth.read(allowMissing: false) == witness.authSnapshot,
                          witness.authorizes(at: now()), permit.isCurrentlyAuthorized() else {
                        throw AccountActivationCoordinatorError.authorizationRevoked
                    }
                    let committed = try store.replace(bytes, expectedGeneration: witness.storeSnapshot.generation)
                    guard committed.bytes == bytes else {
                        throw SecureAtomicFileError.readbackMismatch(path: witness.storePath)
                    }
                    return committed
                }
            }
        } catch {
            return nil
        }
    }

    func compensateRecoveryStoreSelection(
        witness: AuthorityConflictRecoveryWitness,
        committedSnapshot: SecureAtomicFileTransaction.Snapshot,
        authorizeOwner: @Sendable () -> Bool
    ) -> SecureAtomicFileTransaction.Snapshot? {
        guard AccountActivationCrossProcessLeaseContext.holds(
            URL(fileURLWithPath: witness.storePath).deletingLastPathComponent()
                .appendingPathComponent("accounts.runtime-activation.lock")
        ), authorizeOwner() else { return nil }
        do {
            // Restore only selection, never the older credential bytes.
            guard let bytes = committedSnapshot.bytes,
                  var records = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
                  records.count == witness.originalAccounts.count else { return nil }
            for index in records.indices {
                guard let id = records[index]["id"] as? String,
                      UUID(uuidString: id) == witness.originalAccounts[index].id else { return nil }
                records[index]["isActive"] = witness.originalAccounts[index].isActive
            }
            let restored = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted])
            return try SecureAtomicFileTransaction(path: witness.storePath).withExclusiveLock { store in
                guard try store.read(allowMissing: false) == committedSnapshot,
                      authorizeOwner() else { throw AccountActivationCoordinatorError.authorizationRevoked }
                return try store.replace(restored, expectedGeneration: committedSnapshot.generation)
            }
        } catch { return nil }
    }

    nonisolated static func recoveryStoreData(_ witness: AuthorityConflictRecoveryWitness) throws -> Data {
        guard let original = witness.storeSnapshot.bytes,
              var records = try JSONSerialization.jsonObject(with: original) as? [[String: Any]],
              records.count == witness.replacementAccounts.count else {
            throw AccountActivationCoordinatorError.authorizationRevoked
        }
        // Patch only credentials and selection; preserve every unrelated raw field.
        for index in records.indices {
            let account = witness.replacementAccounts[index]
            guard let id = records[index]["id"] as? String, UUID(uuidString: id) == account.id else {
                throw AccountActivationCoordinatorError.authorizationRevoked
            }
            records[index]["isActive"] = account.isActive
            let prior = witness.originalAccounts[index]
            if prior.accessToken != account.accessToken || prior.refreshToken != account.refreshToken
                || prior.idToken != account.idToken {
                records[index]["accessToken"] = account.accessToken
                records[index]["refreshToken"] = account.refreshToken
                records[index]["idToken"] = account.idToken
                records[index]["lastRefreshed"] = account.lastRefreshed?.timeIntervalSinceReferenceDate
                records[index]["runtimeUnusableReason"] = account.runtimeUnusableReason
                records[index]["runtimeUnusableUntil"] = account.runtimeUnusableUntil?.timeIntervalSinceReferenceDate
            }
        }
        return try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted])
    }
}
