import Foundation

struct CodexTokenSavingsStore: Sendable {
    private static let currentEnvelopeVersion = 3

    private struct Envelope: Codable {
        let version: Int
        let savedAt: Date
        let summary: CodexTokenSavingsSummary
    }

    private let storeURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(storeURL: URL = CodexTokenSavingsStore.defaultStoreURL()) {
        self.storeURL = storeURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() -> CodexTokenSavingsSummary? {
        guard let data = try? Data(contentsOf: storeURL),
              let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return nil
        }
        guard envelope.version == Self.currentEnvelopeVersion else {
            return nil
        }
        return envelope.summary
    }

    func save(_ summary: CodexTokenSavingsSummary, now: Date = Date()) {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let envelope = Envelope(version: Self.currentEnvelopeVersion, savedAt: now, summary: summary)
            let data = try encoder.encode(envelope)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            SwapLog.append(.debug("TOKEN_USAGE_HIGH_WATER_SAVE_FAILED error=\(error.localizedDescription)"))
        }
    }

    func stabilizedSummary(
        current: CodexTokenSavingsSummary?,
        candidate: CodexTokenSavingsSummary,
        now: Date = Date()
    ) -> (summary: CodexTokenSavingsSummary, keptPrevious: Bool, previous: CodexTokenSavingsSummary?) {
        let persisted = load()
        let previous = strongest(current, persisted)
        guard let previous else {
            save(candidate, now: now)
            return (candidate, false, nil)
        }

        if CodexTokenSavingsSummary.shouldKeepPreviousSummary(previous: previous, candidate: candidate, now: now) {
            save(previous, now: now)
            return (previous, true, previous)
        }

        save(candidate, now: now)
        return (candidate, false, previous)
    }

    private func strongest(
        _ left: CodexTokenSavingsSummary?,
        _ right: CodexTokenSavingsSummary?
    ) -> CodexTokenSavingsSummary? {
        switch (left, right) {
        case (nil, nil):
            return nil
        case (.some(let summary), nil), (nil, .some(let summary)):
            return summary
        case (.some(let left), .some(let right)):
            if right.apiValueUSD > left.apiValueUSD + 0.01 {
                return right
            }
            if right.total.completionCount > left.total.completionCount,
               abs(right.apiValueUSD - left.apiValueUSD) <= 0.01 {
                return right
            }
            return left
        }
    }

    private static func defaultStoreURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".codexswitch", isDirectory: true)
            .appendingPathComponent("token-usage-high-water.json")
    }
}
