import CoreFoundation
import Foundation

/// The VPS's newest credential generation for one provider account, as emitted
/// by `codexswitch-cli credential-generations`. Holds live tokens: never log it.
struct LinuxDevboxCredentialGeneration: Decodable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    let providerAccountId: String
    let accessTokenExpiresAt: Int64?
    let accessTokenIssuedAt: Int64?
    let source: String
    let idToken: String
    let accessToken: String
    let refreshToken: String

    var description: String {
        "LinuxDevboxCredentialGeneration(provider: \(providerAccountId), source: \(source))"
    }

    var debugDescription: String { description }
}

/// Newest-generation-wins convergence of OAuth token chains between the Mac and
/// the VPS. Refresh tokens are single-use, so whichever host refreshed last holds
/// the only live chain; the other host must adopt it rather than refresh again.
/// See "Token refresh ownership" in docs/architecture/runtime-and-host-ownership.md.
enum LinuxDevboxTokenConvergence {
    static let reportVersion = 1
    static let maximumReportBytes = 1024 * 1024
    static let maximumTokenPayloadBytes = 64 * 1024
    /// Background pull cadence. Access tokens live for days and the VPS refreshes
    /// five minutes before expiry, so a five-minute lag never strands a chain.
    static let periodicInterval: TimeInterval = 5 * 60
    /// Floor for triggered pulls (pre-refresh, VPS token_expired) so several
    /// pollers expiring together share one SSH round trip.
    static let triggeredInterval: TimeInterval = 30

    /// Later access-token `exp` wins; equal expiry falls back to later `iat`.
    struct GenerationKey: Comparable, Sendable {
        let expiresAt: Double
        let issuedAt: Double

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.expiresAt, lhs.issuedAt) < (rhs.expiresAt, rhs.issuedAt)
        }
    }

    struct Adoption: Sendable {
        let original: CodexAccount
        let candidate: CodexAccount
    }

    struct Plan: Sendable {
        var adoptions: [Adoption] = []
        /// Accounts whose Mac generation (after adoption) is strictly newer than
        /// the VPS store copy.
        var newerLocalProviderAccountIds: [String] = []
    }

    private struct Report: Decodable {
        let version: Int
        let accounts: [LinuxDevboxCredentialGeneration]
    }

    enum ReportError: Error {
        case oversized
        case unsupportedVersion
        case invalidAccount
        case duplicateAccount
    }

    static func remoteCommand(cli: String = LinuxDevboxMonitor.remoteCodexSwitchCLI) -> String {
        "\(cli) credential-generations"
    }

    static func decodeReport(_ data: Data) throws -> [LinuxDevboxCredentialGeneration] {
        guard !data.isEmpty, data.count <= maximumReportBytes else { throw ReportError.oversized }
        let report = try JSONDecoder().decode(Report.self, from: data)
        guard report.version == reportVersion else { throw ReportError.unsupportedVersion }
        var seen = Set<String>()
        for generation in report.accounts {
            guard let id = CodexAccount.normalizedProviderAccountId(generation.providerAccountId),
                  generation.source == "store" || generation.source == "auth",
                  [generation.idToken, generation.accessToken, generation.refreshToken]
                    .allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ReportError.invalidAccount
            }
            guard seen.insert("\(generation.source):\(id)").inserted else {
                throw ReportError.duplicateAccount
            }
        }
        return report.accounts
    }

    static func generationKey(accessToken: String) -> GenerationKey? {
        guard let claims = claims(accessToken),
              let expiresAt = numericClaim(claims["exp"]) else { return nil }
        return GenerationKey(
            expiresAt: expiresAt,
            issuedAt: numericClaim(claims["iat"]) ?? -.infinity
        )
    }

    /// Compares each Mac account with the VPS generations for the same
    /// normalized provider account. The Mac adopts the newest account-bound VPS
    /// generation only when it is strictly newer; ties keep the Mac copy. The Mac
    /// pushes when its (possibly just adopted) generation is one the VPS import
    /// merge would take over the VPS store copy.
    static func plan(
        local: [CodexAccount],
        remote: [LinuxDevboxCredentialGeneration],
        now: Date = Date()
    ) -> Plan {
        var storeByAccount: [String: LinuxDevboxCredentialGeneration] = [:]
        var candidatesByAccount: [String: [LinuxDevboxCredentialGeneration]] = [:]
        for generation in remote {
            guard let id = CodexAccount.normalizedProviderAccountId(generation.providerAccountId) else {
                continue
            }
            if generation.source == "store" { storeByAccount[id] = generation }
            candidatesByAccount[id, default: []].append(generation)
        }
        let localCounts = Dictionary(
            local.compactMap(\.normalizedProviderAccountId).map { ($0, 1) },
            uniquingKeysWith: +
        )

        var plan = Plan()
        for account in local {
            guard let id = account.normalizedProviderAccountId,
                  localCounts[id] == 1,
                  account.hasCompleteRuntimeCredentials,
                  let candidates = candidatesByAccount[id] else {
                continue
            }
            var localKey = generationKey(accessToken: account.accessToken)
            // A token bound to another account is never adopted.
            let newest = candidates
                .compactMap { generation in
                    generationKey(accessToken: generation.accessToken).map { (generation, $0) }
                }
                .filter { accessToken($0.0.accessToken, bindsTo: id) }
                .max { $0.1 < $1.1 }
            if let (generation, remoteKey) = newest,
               !sameTokens(generation, account),
               localKey.map({ remoteKey > $0 }) ?? true {
                var candidate = account
                candidate.idToken = generation.idToken
                candidate.accessToken = generation.accessToken
                candidate.refreshToken = generation.refreshToken
                candidate.lastRefreshed = remoteKey.issuedAt.isFinite
                    ? Date(timeIntervalSince1970: remoteKey.issuedAt)
                    : now
                if candidate.requiresReauthentication(at: now) {
                    // The block was observed against the replaced chain.
                    candidate.runtimeUnusableUntil = nil
                    candidate.runtimeUnusableReason = nil
                }
                plan.adoptions.append(Adoption(original: account, candidate: candidate))
                localKey = remoteKey
            }
            // Mirror the VPS import merge so a push always changes the VPS store.
            if let store = storeByAccount[id], let localKey {
                let storeKey = generationKey(accessToken: store.accessToken)
                if storeKey.map({ localKey > $0 }) ?? true {
                    plan.newerLocalProviderAccountIds.append(id)
                }
            }
        }
        return plan
    }

    private static func sameTokens(
        _ generation: LinuxDevboxCredentialGeneration,
        _ account: CodexAccount
    ) -> Bool {
        generation.idToken == account.idToken
            && generation.accessToken == account.accessToken
            && generation.refreshToken == account.refreshToken
    }

    /// A present `chatgpt_account_id` claim must name the same account; the VPS
    /// store binding is otherwise authoritative.
    static func accessToken(_ token: String, bindsTo providerAccountId: String) -> Bool {
        guard let claims = claims(token) else { return false }
        guard let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let claimed = auth["chatgpt_account_id"] as? String else {
            return true
        }
        return CodexAccount.normalizedProviderAccountId(claimed) == providerAccountId
    }

    private static func claims(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              !segments[1].isEmpty,
              segments[1].utf8.count <= maximumTokenPayloadBytes * 2 else { return nil }
        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        guard let data = Data(base64Encoded: encoded),
              data.count <= maximumTokenPayloadBytes else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func numericClaim(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
