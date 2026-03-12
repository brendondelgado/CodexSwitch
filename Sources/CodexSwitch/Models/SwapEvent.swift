import Foundation

struct SwapEvent: Codable, Sendable {
    let fromAccountId: UUID
    let toAccountId: UUID
    let reason: SwapReason
    let timestamp: Date

    enum SwapReason: String, Codable, Sendable {
        case quotaExhausted
        case manual
    }
}
