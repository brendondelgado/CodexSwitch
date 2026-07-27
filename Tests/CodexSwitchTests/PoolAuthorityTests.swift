import Foundation
import Testing

@testable import CodexSwitch

@Suite("Pool authority Swift client")
struct PoolAuthorityTests {
  private func observation(
    epoch: UInt64 = 4,
    phase: PoolAuthorityPhase = .stable,
    target: String = "provider-b",
    requestId: String = "11111111-1111-4111-8111-111111111111",
    observedAt: Date,
    updatedAt: Date
  ) throws -> PoolAuthorityObservation {
    try PoolAuthorityObservation(
      epoch: epoch,
      phase: phase,
      desiredProviderAccountId: target,
      requestId: requestId,
      reason: "test",
      observedAt: observedAt,
      updatedAt: updatedAt,
      previousProviderAccountId: "provider-a",
      detail: nil
    )
  }

  @Test("freshness uses observedAt rather than transition updatedAt")
  func freshnessUsesStatusObservationTime() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let value = try observation(
      observedAt: now,
      updatedAt: now.addingTimeInterval(-86_400)
    )

    #expect(value.isFresh(at: now))
  }

  @Test("JSON requires the server-generated observedAt field")
  func decodingRequiresObservedAt() {
    let json = """
      {
        "epoch": 4,
        "phase": "stable",
        "desiredProviderAccountId": "provider-b",
        "requestId": "11111111-1111-4111-8111-111111111111",
        "reason": "test",
        "updatedAt": "2026-07-27T12:00:00Z",
        "previousProviderAccountId": "provider-a"
      }
      """

    #expect(throws: Error.self) {
      try JSONDecoder().decode(
        PoolAuthorityObservation.self,
        from: Data(json.utf8)
      )
    }
  }

  @Test("fresh stable and degraded observations adopt once")
  func freshAuthorityAdoptsOnce() throws {
    let now = Date(timeIntervalSince1970: 20_000)
    for phase in [PoolAuthorityPhase.stable, .degraded] {
      var state = PoolAuthorityClientState()
      let value = try observation(
        phase: phase,
        observedAt: now,
        updatedAt: now.addingTimeInterval(-3_600)
      )

      #expect(
        state.adoptionDecision(
          for: value,
          localProviderAccountId: "provider-a",
          knownProviderAccountIds: ["provider-a", "provider-b"],
          permitsConverging: false,
          now: now
        ) == .adopt(value))
      #expect(
        state.adoptionDecision(
          for: value,
          localProviderAccountId: "provider-a",
          knownProviderAccountIds: ["provider-a", "provider-b"],
          permitsConverging: false,
          now: now
        ) == .ignoreRepeated)
    }
  }

  @Test("failed same-epoch adoption retries after bounded backoff")
  func failedAdoptionCanRetrySameEpochWithoutOverlap() throws {
    let now = Date(timeIntervalSince1970: 25_000)
    var state = PoolAuthorityClientState()
    let value = try observation(
      epoch: 6,
      observedAt: now,
      updatedAt: now.addingTimeInterval(-100)
    )

    #expect(state.adoptionDecision(
      for: value,
      localProviderAccountId: "provider-a",
      knownProviderAccountIds: ["provider-a", "provider-b"],
      permitsConverging: false,
      now: now
    ) == .adopt(value))
    #expect(state.adoptionDecision(
      for: value,
      localProviderAccountId: "provider-a",
      knownProviderAccountIds: ["provider-a", "provider-b"],
      permitsConverging: false,
      now: now
    ) == .ignoreRepeated)

    state.finishAdoption(epoch: 6, succeeded: false, at: now)
    #expect(state.adoptionDecision(
      for: value,
      localProviderAccountId: "provider-a",
      knownProviderAccountIds: ["provider-a", "provider-b"],
      permitsConverging: false,
      now: now.addingTimeInterval(4)
    ) == .ignoreRepeated)
    #expect(state.adoptionDecision(
      for: value,
      localProviderAccountId: "provider-a",
      knownProviderAccountIds: ["provider-a", "provider-b"],
      permitsConverging: false,
      now: now.addingTimeInterval(5)
    ) == .adopt(value))
  }

  @Test("newer epoch supersedes an older in-flight adoption")
  func newerEpochSupersedesInFlightAdoption() throws {
    let now = Date(timeIntervalSince1970: 27_000)
    var state = PoolAuthorityClientState()
    let b = try observation(
      epoch: 6,
      target: "provider-b",
      observedAt: now,
      updatedAt: now
    )
    let c = try observation(
      epoch: 7,
      target: "provider-c",
      observedAt: now.addingTimeInterval(1),
      updatedAt: now.addingTimeInterval(1)
    )
    _ = state.adoptionDecision(
      for: b,
      localProviderAccountId: "provider-a",
      knownProviderAccountIds: ["provider-a", "provider-b", "provider-c"],
      permitsConverging: false,
      now: now
    )

    #expect(state.adoptionDecision(
      for: c,
      localProviderAccountId: "provider-a",
      knownProviderAccountIds: ["provider-a", "provider-b", "provider-c"],
      permitsConverging: false,
      now: now.addingTimeInterval(1)
    ) == .adopt(c))
    state.finishAdoption(epoch: 6, succeeded: true, at: now.addingTimeInterval(2))
    #expect(state.adoptionInFlightEpoch == 7)
    #expect(state.adoptionDecision(
      for: c,
      localProviderAccountId: "provider-a",
      knownProviderAccountIds: ["provider-a", "provider-b", "provider-c"],
      permitsConverging: false,
      now: now.addingTimeInterval(2)
    ) == .ignoreRepeated)
  }

  @Test("stale epochs and out-of-order reads cannot restore an old target")
  func staleAuthorityCannotRestoreOldTarget() throws {
    let now = Date(timeIntervalSince1970: 30_000)
    var state = PoolAuthorityClientState()
    let current = try observation(
      epoch: 8,
      target: "provider-b",
      observedAt: now,
      updatedAt: now.addingTimeInterval(-100)
    )
    _ = state.adoptionDecision(
      for: current,
      localProviderAccountId: "provider-a",
      knownProviderAccountIds: ["provider-a", "provider-b"],
      permitsConverging: false,
      now: now
    )
    let staleEpoch = try observation(
      epoch: 7,
      target: "provider-a",
      observedAt: now,
      updatedAt: now
    )
    let staleRead = try observation(
      epoch: 8,
      target: "provider-b",
      observedAt: now.addingTimeInterval(-1),
      updatedAt: current.updatedAt
    )

    #expect(
      state.adoptionDecision(
        for: staleEpoch,
        localProviderAccountId: "provider-b",
        knownProviderAccountIds: ["provider-a", "provider-b"],
        permitsConverging: false,
        now: now
      ) == .rejected("authority epoch regressed"))
    #expect(
      state.adoptionDecision(
        for: staleRead,
        localProviderAccountId: "provider-b",
        knownProviderAccountIds: ["provider-a", "provider-b"],
        permitsConverging: false,
        now: now
      ) == .rejected("authority status read regressed within its epoch"))
  }

  @Test("configured VPS without a status observation fails closed")
  func unavailableVPSPreventsLocalSwap() {
    var state = PoolAuthorityClientState()

    #expect(
      state.remoteFirstDecision(
        observation: nil,
        targetProviderAccountId: "provider-b",
        knownProviderAccountIds: ["provider-a", "provider-b"],
        now: Date(timeIntervalSince1970: 40_000)
      ) == .failClosed("authority status is unavailable"))
  }

  @Test("disabled readiness monitor does not disable remote authority")
  func disabledMonitorStillRequiresRemoteAuthority() {
    let settings = LinuxDevboxMonitorSettings(
      enabled: false,
      host: "authority.example.test",
      user: "codex",
      sshKeyPath: "~/.ssh/id_ed25519",
      port: 22
    )
    var state = PoolAuthorityClientState()

    #expect(!settings.isConfigured)
    #expect(settings.hasRemoteAuthorityEndpoint)
    #expect(AppDelegate.swapRequiresRemoteAuthority(settings))
    #expect(state.remoteFirstDecision(
      observation: nil,
      targetProviderAccountId: "provider-b",
      knownProviderAccountIds: ["provider-a", "provider-b"],
      now: Date(timeIntervalSince1970: 45_000)
    ) == .failClosed("authority status is unavailable"))
  }

  @Test("authority endpoint suppresses local UI fallback before first status")
  @MainActor
  func authorityEndpointSuppressesConfiguredAccountFallback() {
    let manager = AccountManager(userDefaults: isolatedDefaults())
    let account = CodexAccount(
      email: "local@example.com",
      accessToken: "access",
      refreshToken: "refresh",
      idToken: "id",
      accountId: "provider-local",
      isActive: true
    )
    manager.accounts = [account]

    #expect(manager.poolTargetAccount?.id == account.id)
    manager.publishRemoteAuthorityEndpointConfigured(true)
    #expect(manager.poolTargetAccount == nil)
    #expect(!manager.isPoolTarget(account))
  }

  @Test("remote authority transport config is token-free and mode 0600")
  func remoteAuthorityTransportConfigIsSecure() throws {
    let root = try makeSecureTestDirectoryURL(
      prefix: "codexswitch-authority"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("remote-authority.json")
    let settings = LinuxDevboxMonitorSettings(
      enabled: false,
      host: "authority.example.test",
      user: "codex",
      sshKeyPath: "~/.ssh/id_ed25519",
      port: 2222
    )

    let config = try RemoteAuthorityTransportConfigStore(
      path: path.path
    ).write(settings: settings)
    let data = try Data(contentsOf: path)
    let decoded = try JSONDecoder().decode(
      RemoteAuthorityTransportConfig.self,
      from: data
    )
    let permissions = try #require(
      FileManager.default.attributesOfItem(atPath: path.path)[
        .posixPermissions
      ] as? NSNumber
    )
    let text = String(decoding: data, as: UTF8.self)

    #expect(config == decoded)
    #expect(decoded == RemoteAuthorityTransportConfig(
      settings: settings
    ))
    #expect(decoded.enabled)
    let expectedKeyPath = URL(
      fileURLWithPath: NSString(
        string: "~/.ssh/id_ed25519"
      ).expandingTildeInPath
    )
    .resolvingSymlinksInPath()
    .standardizedFileURL
    .path
    #expect(decoded.sshKeyPath == expectedKeyPath)
    #expect(decoded.sshKeyPath.hasPrefix("/"))
    #expect(!decoded.sshKeyPath.contains("~"))
    #expect(permissions.intValue & 0o777 == 0o600)
    #expect(!text.contains("accessToken"))
    #expect(!text.contains("refreshToken"))
    #expect(!text.contains("PRIVATE KEY"))
  }

  @Test("remote authority transport bounds match the Rust reader")
  func remoteAuthorityTransportBoundsMatchReader() {
    #expect(LinuxDevboxMonitorSettings.maximumHostBytes == 253)
    #expect(LinuxDevboxMonitorSettings.maximumUserBytes == 64)
    #expect(LinuxDevboxMonitorSettings.maximumSSHKeyPathBytes == 4 * 1_024)
  }

  @Test("missing endpoint writes an explicitly disabled authority config")
  func missingEndpointDisablesAuthorityTransport() throws {
    let root = try makeSecureTestDirectoryURL(
      prefix: "codexswitch-authority-disabled"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("remote-authority.json")
    let config = try RemoteAuthorityTransportConfigStore(
      path: path.path
    ).write(settings: LinuxDevboxMonitorSettings(
      enabled: true,
      host: "",
      user: "",
      sshKeyPath: "",
      port: 22
    ))

    #expect(!config.enabled)
    #expect(config.host.isEmpty)
    #expect(config.user.isEmpty)
    #expect(config.sshKeyPath.isEmpty)
  }

  @Test("remote authority transport refuses a symlink destination")
  func remoteAuthorityTransportRejectsSymlink() throws {
    let root = try makeSecureTestDirectoryURL(
      prefix: "codexswitch-authority-link"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target.json")
    let link = root.appendingPathComponent("remote-authority.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: target
    )

    #expect(throws: Error.self) {
      try RemoteAuthorityTransportConfigStore(path: link.path).write(
        settings: LinuxDevboxMonitorSettings(
          enabled: false,
          host: "authority.example.test",
          user: "codex",
          sshKeyPath: "",
          port: 22
        )
      )
    }
  }

  @Test("unknown request outcome reconciles once without replay")
  func unknownOutcomeUsesReadOnlyReconciliation() throws {
    let now = Date(timeIntervalSince1970: 50_000)
    let request = try PoolAuthorityRequest(
      selector: "provider-b",
      requestId: "22222222-2222-4222-8222-222222222222",
      expectedEpoch: 9,
      reason: "manual"
    )
    let reconciled = try observation(
      epoch: 10,
      target: "provider-b",
      requestId: request.requestId,
      observedAt: now,
      updatedAt: now
    )
    var mutationCalls = 0
    var statusCalls = 0

    let result = LinuxDevboxMonitor.requestPoolTargetWithCandidates(
      [["fixture-one"], ["fixture-two"]],
      request: request,
      requiresEpochAdvance: true,
      now: now,
      executionToken: "authority-fixture",
      runner: { _, _, _ in
        mutationCalls += 1
        return ProcessRunResult(
          terminationStatus: -1,
          stdout: Data(),
          stderr: Data("connection lost".utf8),
          timedOut: true
        )
      },
      statusFetcher: {
        statusCalls += 1
        return .success(reconciled)
      }
    )

    #expect(result == .success(.reconciledAfterUnknown(reconciled)))
    #expect(mutationCalls == 1)
    #expect(statusCalls == 1)
  }

  @Test("authority request command matches the VPS CLI contract")
  func requestCommandMatchesContract() throws {
    let request = try PoolAuthorityRequest(
      selector: "provider'b",
      requestId: "33333333-3333-4333-8333-333333333333",
      expectedEpoch: 12,
      reason: "quota exhausted"
    )
    let command = LinuxDevboxMonitor.remotePoolTargetRequestCommand(request)

    #expect(command.contains("request-pool-target 'provider'\\''b'"))
    #expect(command.contains("--request-id '33333333-3333-4333-8333-333333333333'"))
    #expect(command.contains("--expected-epoch 12"))
    #expect(command.contains("--reason 'quota exhausted' --json"))
    #expect(
      LinuxDevboxMonitor.remotePoolAuthorityStatusCommand()
        .contains("pool-authority-status --json"))
  }

  @Test("completed nonzero request reconciles a committed authority target")
  func completedFailureReconcilesCommittedTarget() throws {
    let now = Date(timeIntervalSince1970: 55_000)
    let token = "completed-failure"
    let request = try PoolAuthorityRequest(
      selector: "provider-b",
      requestId: "44444444-4444-4444-8444-444444444444",
      expectedEpoch: 14,
      reason: "automatic"
    )
    let committed = try observation(
      epoch: 15,
      phase: .degraded,
      target: "provider-b",
      requestId: request.requestId,
      observedAt: now,
      updatedAt: now
    )
    let start = LinuxDevboxMonitor.remoteExecutionMarker(executionToken: token)
    let completion = LinuxDevboxMonitor.remoteCompletionMarker(executionToken: token)
    var mutationCalls = 0
    var statusCalls = 0

    let result = LinuxDevboxMonitor.requestPoolTargetWithCandidates(
      [["fixture"]],
      request: request,
      requiresEpochAdvance: true,
      now: now,
      executionToken: token,
      runner: { _, _, _ in
        mutationCalls += 1
        return ProcessRunResult(
          terminationStatus: 1,
          stdout: Data(),
          stderr: Data("\(start)\nruntime confirmation failed\n\(completion) 1\n".utf8),
          timedOut: false
        )
      },
      statusFetcher: {
        statusCalls += 1
        return .success(committed)
      }
    )

    #expect(result == .success(.reconciledAfterUnknown(committed)))
    #expect(mutationCalls == 1)
    #expect(statusCalls == 1)
  }

  @Test("newer authority revokes an older local operation generation")
  func operationAuthorityIsRevocable() {
    let authority = PoolAuthorityOperationAuthority(
      epoch: 3,
      providerAccountId: "provider-a"
    )

    #expect(authority.authorizes())
    authority.revoke()
    #expect(!authority.authorizes())
  }

  private func isolatedDefaults() -> UserDefaults {
    let suite = "PoolAuthorityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }
}
