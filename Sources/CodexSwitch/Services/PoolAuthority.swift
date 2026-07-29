import Dispatch
import Foundation

enum PoolAuthorityPhase: String, Codable, CaseIterable, Equatable, Sendable {
  case stable
  case converging
  case degraded
}

enum PoolAuthorityValidationError: Error, Equatable, LocalizedError {
  case invalidField(String)

  var errorDescription: String? {
    switch self {
    case .invalidField(let field):
      return "Pool authority field is invalid: \(field)"
    }
  }
}

struct PoolAuthorityObservation: Codable, Equatable, Sendable {
  static let maximumProviderAccountIdBytes = 256
  static let maximumRequestIdBytes = 128
  static let maximumReasonBytes = 256
  static let maximumDetailBytes = 4 * 1_024
  static let maximumFreshnessAge: TimeInterval = 30
  static let maximumFutureClockSkew: TimeInterval = 30

  let epoch: UInt64
  let phase: PoolAuthorityPhase
  let desiredProviderAccountId: String
  let requestId: String
  let reason: String
  let observedAt: Date
  let updatedAt: Date
  let previousProviderAccountId: String?
  let detail: String?

  init(
    epoch: UInt64,
    phase: PoolAuthorityPhase,
    desiredProviderAccountId: String,
    requestId: String,
    reason: String,
    observedAt: Date,
    updatedAt: Date,
    previousProviderAccountId: String?,
    detail: String?
  ) throws {
    self.epoch = epoch
    self.phase = phase
    self.desiredProviderAccountId = desiredProviderAccountId
    self.requestId = requestId
    self.reason = reason
    self.observedAt = observedAt
    self.updatedAt = updatedAt
    self.previousProviderAccountId = previousProviderAccountId
    self.detail = detail
    try validate()
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    epoch = try container.decode(UInt64.self, forKey: .epoch)
    phase = try container.decode(PoolAuthorityPhase.self, forKey: .phase)
    desiredProviderAccountId = try container.decode(
      String.self,
      forKey: .desiredProviderAccountId
    )
    requestId = try container.decode(String.self, forKey: .requestId)
    reason = try container.decode(String.self, forKey: .reason)
    observedAt = try Self.decodeDate(container: container, key: .observedAt)
    updatedAt = try Self.decodeDate(container: container, key: .updatedAt)
    previousProviderAccountId = try container.decodeIfPresent(
      String.self,
      forKey: .previousProviderAccountId
    )
    detail = try container.decodeIfPresent(String.self, forKey: .detail)
    try validate()
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(epoch, forKey: .epoch)
    try container.encode(phase, forKey: .phase)
    try container.encode(desiredProviderAccountId, forKey: .desiredProviderAccountId)
    try container.encode(requestId, forKey: .requestId)
    try container.encode(reason, forKey: .reason)
    try container.encode(
      Self.makeDateFormatter(fractionalSeconds: true).string(from: observedAt),
      forKey: .observedAt
    )
    try container.encode(
      Self.makeDateFormatter(fractionalSeconds: true).string(from: updatedAt),
      forKey: .updatedAt
    )
    try container.encodeIfPresent(
      previousProviderAccountId,
      forKey: .previousProviderAccountId
    )
    try container.encodeIfPresent(detail, forKey: .detail)
  }

  func isFresh(
    at now: Date,
    maximumAge: TimeInterval = Self.maximumFreshnessAge
  ) -> Bool {
    guard maximumAge.isFinite, maximumAge >= 0 else { return false }
    let age = now.timeIntervalSince(observedAt)
    return age >= -Self.maximumFutureClockSkew && age <= maximumAge
  }

  private enum CodingKeys: String, CodingKey {
    case epoch
    case phase
    case desiredProviderAccountId
    case requestId
    case reason
    case observedAt
    case updatedAt
    case previousProviderAccountId
    case detail
  }

  private func validate() throws {
    try Self.validateBoundedPrintable(
      desiredProviderAccountId,
      field: "desiredProviderAccountId",
      maximumBytes: Self.maximumProviderAccountIdBytes
    )
    try Self.validateBoundedPrintable(
      requestId,
      field: "requestId",
      maximumBytes: Self.maximumRequestIdBytes
    )
    guard UUID(uuidString: requestId) != nil else {
      throw PoolAuthorityValidationError.invalidField("requestId")
    }
    try Self.validateBoundedPrintable(
      reason,
      field: "reason",
      maximumBytes: Self.maximumReasonBytes
    )
    if let previousProviderAccountId {
      try Self.validateBoundedPrintable(
        previousProviderAccountId,
        field: "previousProviderAccountId",
        maximumBytes: Self.maximumProviderAccountIdBytes
      )
    }
    if let detail {
      try Self.validateBoundedPrintable(
        detail,
        field: "detail",
        maximumBytes: Self.maximumDetailBytes,
        permitsEmpty: true
      )
    }
    guard observedAt.timeIntervalSince1970.isFinite else {
      throw PoolAuthorityValidationError.invalidField("observedAt")
    }
    guard updatedAt.timeIntervalSince1970.isFinite else {
      throw PoolAuthorityValidationError.invalidField("updatedAt")
    }
  }

  private static func validateBoundedPrintable(
    _ value: String,
    field: String,
    maximumBytes: Int,
    permitsEmpty: Bool = false
  ) throws {
    guard permitsEmpty || !value.isEmpty,
      value.utf8.count <= maximumBytes,
      value.unicodeScalars.allSatisfy({
        $0.value >= 32 && $0.value != 127
      })
    else {
      throw PoolAuthorityValidationError.invalidField(field)
    }
  }

  private static func decodeDate(
    container: KeyedDecodingContainer<CodingKeys>,
    key: CodingKeys
  ) throws -> Date {
    if let value = try? container.decode(String.self, forKey: key),
      let date = makeDateFormatter(fractionalSeconds: true).date(from: value)
        ?? makeDateFormatter(fractionalSeconds: false).date(from: value)
    {
      return date
    }
    if let value = try? container.decode(Double.self, forKey: key),
      value.isFinite
    {
      return Date(timeIntervalSince1970: value)
    }
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription: "Expected an RFC3339 timestamp or Unix seconds"
    )
  }

  private static func makeDateFormatter(
    fractionalSeconds: Bool
  ) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions =
      fractionalSeconds
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter
  }
}

struct PoolAuthorityRequest: Equatable, Sendable {
  let selector: String
  let requestId: String
  let expectedEpoch: UInt64
  let reason: String

  init(
    selector: String,
    requestId: String,
    expectedEpoch: UInt64,
    reason: String
  ) throws {
    guard !selector.isEmpty,
      selector.utf8.count <= PoolAuthorityObservation.maximumProviderAccountIdBytes,
      selector.unicodeScalars.allSatisfy({
        $0.value >= 32 && $0.value != 127
      })
    else {
      throw PoolAuthorityValidationError.invalidField("selector")
    }
    guard UUID(uuidString: requestId) != nil,
      requestId.utf8.count <= PoolAuthorityObservation.maximumRequestIdBytes
    else {
      throw PoolAuthorityValidationError.invalidField("requestId")
    }
    guard !reason.isEmpty,
      reason.utf8.count <= PoolAuthorityObservation.maximumReasonBytes,
      reason.unicodeScalars.allSatisfy({
        $0.value >= 32 && $0.value != 127
      })
    else {
      throw PoolAuthorityValidationError.invalidField("reason")
    }
    self.selector = selector
    self.requestId = requestId
    self.expectedEpoch = expectedEpoch
    self.reason = reason
  }
}

enum PoolAuthorityRequestResolution: Equatable, Sendable {
  case accepted(PoolAuthorityObservation)
  case reconciledAfterUnknown(PoolAuthorityObservation)

  var observation: PoolAuthorityObservation {
    switch self {
    case .accepted(let observation), .reconciledAfterUnknown(let observation):
      return observation
    }
  }
}

enum PoolAuthorityAdoptionDecision: Equatable, Sendable {
  case adopt(PoolAuthorityObservation)
  case alreadyCurrent
  case observeOnly
  case ignoreRepeated
  case rejected(String)
}

enum PoolAuthorityRemoteFirstDecision: Equatable, Sendable {
  case adoptExisting(PoolAuthorityObservation)
  case requestRequired(PoolAuthorityObservation)
  case failClosed(String)
}

struct PoolAuthorityClientState: Equatable, Sendable {
  static let adoptionRetryBaseDelay: TimeInterval = 5
  static let adoptionRetryMaximumDelay: TimeInterval = 60

  private(set) var latestObservation: PoolAuthorityObservation?
  private(set) var adoptionInFlightEpoch: UInt64?
  private(set) var adoptionFailureCount = 0
  private(set) var nextAdoptionRetryAt: Date?
  private(set) var lastSuccessfulAdoptionEpoch: UInt64?
  private(set) var lastSuccessfulProviderAccountId: String?

  mutating func adoptionDecision(
    for observation: PoolAuthorityObservation,
    localProviderAccountId: String?,
    runtimeConvergedForObservation: Bool,
    runtimeRemainsConfirmedForObservation: Bool = false,
    knownProviderAccountIds: [String],
    permitsConverging: Bool,
    now: Date
  ) -> PoolAuthorityAdoptionDecision {
    let previousEpoch = latestObservation?.epoch
    if let rejection = recordObservation(
      observation,
      knownProviderAccountIds: knownProviderAccountIds,
      now: now
    ) {
      return .rejected(rejection)
    }
    let localProviderIsDesired =
      localProviderAccountId == observation.desiredProviderAccountId
    if localProviderIsDesired, runtimeConvergedForObservation {
      recordSuccessfulAdoption(of: observation)
      finishAdoption(epoch: observation.epoch, succeeded: true, at: now)
      return .alreadyCurrent
    }
    if localProviderIsDesired,
      runtimeRemainsConfirmedForObservation,
      lastSuccessfulAdoptionEpoch == observation.epoch,
      lastSuccessfulProviderAccountId == observation.desiredProviderAccountId
    {
      return .alreadyCurrent
    }
    if observation.phase == .converging, !permitsConverging {
      return .observeOnly
    }
    if let adoptionInFlightEpoch,
      adoptionInFlightEpoch >= observation.epoch {
      return .ignoreRepeated
    }
    if latestObservation?.epoch == observation.epoch,
      let nextAdoptionRetryAt,
      now < nextAdoptionRetryAt {
      return .ignoreRepeated
    }
    if adoptionInFlightEpoch.map({ observation.epoch > $0 }) == true
      || previousEpoch != observation.epoch {
      adoptionFailureCount = 0
      nextAdoptionRetryAt = nil
    }
    adoptionInFlightEpoch = observation.epoch
    return .adopt(observation)
  }

  mutating func finishAdoption(
    epoch: UInt64,
    succeeded: Bool,
    at now: Date
  ) {
    guard adoptionInFlightEpoch == epoch else { return }
    adoptionInFlightEpoch = nil
    if succeeded {
      if let latestObservation, latestObservation.epoch == epoch {
        recordSuccessfulAdoption(of: latestObservation)
      }
      adoptionFailureCount = 0
      nextAdoptionRetryAt = nil
      return
    }
    adoptionFailureCount = min(adoptionFailureCount + 1, 16)
    let exponent = min(adoptionFailureCount - 1, 8)
    let delay = min(
      Self.adoptionRetryBaseDelay * pow(2, Double(exponent)),
      Self.adoptionRetryMaximumDelay
    )
    nextAdoptionRetryAt = now.addingTimeInterval(delay)
  }

  mutating func recordObservation(
    _ observation: PoolAuthorityObservation,
    knownProviderAccountIds: [String],
    now: Date
  ) -> String? {
    guard observation.isFresh(at: now) else {
      return "authority observation is stale"
    }
    guard
      knownProviderAccountIds.filter({
        $0 == observation.desiredProviderAccountId
      }).count == 1
    else {
      return "authority provider identity is missing or ambiguous"
    }
    if let latestObservation {
      if observation.epoch < latestObservation.epoch {
        return "authority epoch regressed"
      }
      if observation.epoch == latestObservation.epoch {
        guard
          observation.desiredProviderAccountId
            == latestObservation.desiredProviderAccountId
        else {
          return "authority target changed without an epoch advance"
        }
        guard observation.updatedAt >= latestObservation.updatedAt else {
          return "authority transition regressed within its epoch"
        }
        if observation.updatedAt == latestObservation.updatedAt,
          observation.observedAt < latestObservation.observedAt
        {
          return "authority status read regressed within its epoch"
        }
      }
    }
    latestObservation = observation
    return nil
  }

  mutating func remoteFirstDecision(
    observation: PoolAuthorityObservation?,
    targetProviderAccountId: String,
    knownProviderAccountIds: [String],
    now: Date
  ) -> PoolAuthorityRemoteFirstDecision {
    guard let observation else {
      return .failClosed("authority status is unavailable")
    }
    if let rejection = recordObservation(
      observation,
      knownProviderAccountIds: knownProviderAccountIds,
      now: now
    ) {
      return .failClosed(rejection)
    }
    if observation.desiredProviderAccountId == targetProviderAccountId {
      guard observation.phase == .stable || observation.phase == .degraded else {
        return .failClosed("authority is still converging")
      }
      return .adoptExisting(observation)
    }
    guard observation.phase == .stable else {
      return .failClosed("authority cannot accept a different target")
    }
    return .requestRequired(observation)
  }

  mutating func reset() {
    latestObservation = nil
    adoptionInFlightEpoch = nil
    adoptionFailureCount = 0
    nextAdoptionRetryAt = nil
    lastSuccessfulAdoptionEpoch = nil
    lastSuccessfulProviderAccountId = nil
  }

  private mutating func recordSuccessfulAdoption(
    of observation: PoolAuthorityObservation
  ) {
    lastSuccessfulAdoptionEpoch = observation.epoch
    lastSuccessfulProviderAccountId = observation.desiredProviderAccountId
  }
}

final class PoolAuthorityOperationAuthority: @unchecked Sendable {
  let generation: UUID
  let epoch: UInt64
  let providerAccountId: String
  let expiresAt: Date

  private let lock = NSLock()
  private var revoked = false

  init(
    epoch: UInt64,
    providerAccountId: String,
    expiresAt: Date,
    generation: UUID = UUID()
  ) {
    self.generation = generation
    self.epoch = epoch
    self.providerAccountId = providerAccountId
    self.expiresAt = expiresAt
  }

  func authorizes(at now: Date = Date()) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !revoked && now <= expiresAt
  }

  func revoke() {
    lock.lock()
    revoked = true
    lock.unlock()
  }
}
