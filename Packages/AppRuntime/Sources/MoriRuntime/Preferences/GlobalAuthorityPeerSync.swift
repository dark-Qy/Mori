import Foundation

/// Production adapters must bound peer I/O and promptly honor task
/// cancellation. The runtime also applies an outer timeout so one authority
/// channel cannot starve the other.
public protocol GlobalAuthorityPeerTransport: Sendable {
  func exchange(
    channel: GlobalAuthoritySyncChannel,
    payload: Data
  ) async throws -> Data
}

public enum GlobalAuthorityPeerTransportError: Error, Equatable, Sendable {
  case offline
  case injectedFailure(GlobalAuthoritySyncChannel)
}

/// Deterministic in-memory transport for Mock scenarios and runtime tests.
///
/// The handler normally calls the peer runtime's `receive(channel:payload:)`.
/// Availability and one-shot failures let lifecycle retries be exercised
/// without exposing a product-facing sync control.
public actor InMemoryGlobalAuthorityPeerTransport:
  GlobalAuthorityPeerTransport
{
  public typealias Handler =
    @Sendable (GlobalAuthoritySyncChannel, Data) async throws -> Data

  private let handler: Handler
  private var isAvailable: Bool
  private var remainingFailures: [GlobalAuthoritySyncChannel: Int]
  private var exchangedChannels: [GlobalAuthoritySyncChannel] = []

  public init(
    isAvailable: Bool = true,
    handler: @escaping Handler
  ) {
    self.isAvailable = isAvailable
    self.handler = handler
    remainingFailures = [:]
  }

  public func setAvailable(_ isAvailable: Bool) {
    self.isAvailable = isAvailable
  }

  public func failNext(
    _ channel: GlobalAuthoritySyncChannel,
    count: Int = 1
  ) {
    remainingFailures[channel, default: 0] += max(0, count)
  }

  public func exchangeLog() -> [GlobalAuthoritySyncChannel] {
    exchangedChannels
  }

  public func exchange(
    channel: GlobalAuthoritySyncChannel,
    payload: Data
  ) async throws -> Data {
    exchangedChannels.append(channel)
    guard isAvailable else {
      throw GlobalAuthorityPeerTransportError.offline
    }
    if remainingFailures[channel, default: 0] > 0 {
      remainingFailures[channel, default: 0] -= 1
      throw GlobalAuthorityPeerTransportError.injectedFailure(channel)
    }
    return try await handler(channel, payload)
  }
}

public enum GlobalAuthoritySyncTrigger: String, CaseIterable, Sendable {
  case initialActivation
  case foregroundActivation
  case connectivityRestored
  case backgroundRefresh
  case localAuthorityChanged
}

public enum GlobalAuthorityChannelFailure: String, Equatable, Sendable {
  case invalidWire
  case mergeRejected
  case timedOut
  case transportOrPersistence
}

public enum GlobalAuthorityChannelOutcome: Equatable, Sendable {
  case synchronized(localStateChanged: Bool)
  case retryRequired(GlobalAuthorityChannelFailure)

  public var requiresRetry: Bool {
    if case .retryRequired = self { true } else { false }
  }
}

public struct GlobalAuthoritySyncReport: Equatable, Sendable {
  public let trigger: GlobalAuthoritySyncTrigger
  public let preferences: GlobalAuthorityChannelOutcome
  public let consent: GlobalAuthorityChannelOutcome

  public init(
    trigger: GlobalAuthoritySyncTrigger,
    preferences: GlobalAuthorityChannelOutcome,
    consent: GlobalAuthorityChannelOutcome
  ) {
    self.trigger = trigger
    self.preferences = preferences
    self.consent = consent
  }

  public var requiresRetry: Bool {
    preferences.requiresRetry || consent.requiresRetry
  }
}

public enum GlobalAuthorityPeerSyncError: Error, Equatable, Sendable {
  case rejectedPreferences(GlobalPreferenceMergeRejection)
  case rejectedConsent(GlobalConsentMergeRejection)
}

/// Automatic latest-state anti-entropy for global preferences and consent.
///
/// The durable global-authority repository is also the retry state. Each
/// lifecycle trigger sends the current canonical value on two independent
/// channels. The receiver persists its deterministic merge before returning
/// the merged value. If delivery or the response is lost, the next lifecycle
/// trigger safely repeats the exchange; duplicates, reordering, and relaunches
/// therefore converge without a manual sync action or a second outbox.
public actor GlobalAuthorityPeerSyncRuntime<Storage: GlobalAuthorityStorage> {
  private let repository: GlobalAuthorityRepository<Storage>
  private let wireCodec: GlobalAuthoritySyncWireCodec
  private let channelTimeout: Duration

  public init(
    repository: GlobalAuthorityRepository<Storage>,
    wireCodec: GlobalAuthoritySyncWireCodec = GlobalAuthoritySyncWireCodec(),
    channelTimeout: Duration = .seconds(15)
  ) {
    self.repository = repository
    self.wireCodec = wireCodec
    self.channelTimeout =
      channelTimeout > .zero
      ? channelTimeout
      : .milliseconds(1)
  }

  /// Entry point for app lifecycle and connectivity hooks. Both logical
  /// channels are attempted independently so one malformed or unavailable
  /// channel cannot starve the other.
  public func handle<Transport: GlobalAuthorityPeerTransport>(
    _ trigger: GlobalAuthoritySyncTrigger,
    using transport: Transport
  ) async -> GlobalAuthoritySyncReport {
    async let preferenceOutcome = withGlobalAuthorityTimeout(
      channelTimeout
    ) {
      await self.synchronizePreferences(using: transport)
    }
    async let consentOutcome = withGlobalAuthorityTimeout(channelTimeout) {
      await self.synchronizeConsent(using: transport)
    }
    return GlobalAuthoritySyncReport(
      trigger: trigger,
      preferences: await preferenceOutcome,
      consent: await consentOutcome
    )
  }

  public func receive(
    channel: GlobalAuthoritySyncChannel,
    payload: Data
  ) async throws -> Data {
    switch channel {
    case .preferences:
      let frame = try wireCodec.decodePreferences(payload)
      let merge = try await repository.merge(preferences: frame.preferences)
      switch merge {
      case .applied, .duplicate:
        let current = try await repository.current()
        return try wireCodec.encode(
          GlobalPreferenceSyncFrame(preferences: current.preferences)
        )
      case .rejected(let reason):
        throw GlobalAuthorityPeerSyncError.rejectedPreferences(reason)
      }
    case .consent:
      let frame = try wireCodec.decodeConsent(payload)
      let merge = try await repository.merge(consent: frame.consent)
      switch merge {
      case .applied, .duplicate:
        let current = try await repository.current()
        return try wireCodec.encode(
          GlobalConsentSyncFrame(consent: current.consent)
        )
      case .rejected(let reason):
        throw GlobalAuthorityPeerSyncError.rejectedConsent(reason)
      }
    }
  }

  private func synchronizePreferences<
    Transport: GlobalAuthorityPeerTransport
  >(
    using transport: Transport
  ) async -> GlobalAuthorityChannelOutcome {
    do {
      let current = try await repository.current()
      let payload = try wireCodec.encode(
        GlobalPreferenceSyncFrame(preferences: current.preferences)
      )
      try Task.checkCancellation()
      let response = try await transport.exchange(
        channel: .preferences,
        payload: payload
      )
      try Task.checkCancellation()
      let frame = try wireCodec.decodePreferences(response)
      let merge = try await repository.merge(preferences: frame.preferences)
      switch merge {
      case .applied:
        return .synchronized(localStateChanged: true)
      case .duplicate:
        return .synchronized(localStateChanged: false)
      case .rejected(let reason):
        throw GlobalAuthorityPeerSyncError.rejectedPreferences(reason)
      }
    } catch is GlobalAuthoritySyncWireError {
      return .retryRequired(.invalidWire)
    } catch is GlobalAuthorityPeerSyncError {
      return .retryRequired(.mergeRejected)
    } catch {
      return .retryRequired(.transportOrPersistence)
    }
  }

  private func synchronizeConsent<Transport: GlobalAuthorityPeerTransport>(
    using transport: Transport
  ) async -> GlobalAuthorityChannelOutcome {
    do {
      let current = try await repository.current()
      let payload = try wireCodec.encode(
        GlobalConsentSyncFrame(consent: current.consent)
      )
      try Task.checkCancellation()
      let response = try await transport.exchange(
        channel: .consent,
        payload: payload
      )
      try Task.checkCancellation()
      let frame = try wireCodec.decodeConsent(response)
      let merge = try await repository.merge(consent: frame.consent)
      switch merge {
      case .applied:
        return .synchronized(localStateChanged: true)
      case .duplicate:
        return .synchronized(localStateChanged: false)
      case .rejected(let reason):
        throw GlobalAuthorityPeerSyncError.rejectedConsent(reason)
      }
    } catch is GlobalAuthoritySyncWireError {
      return .retryRequired(.invalidWire)
    } catch is GlobalAuthorityPeerSyncError {
      return .retryRequired(.mergeRejected)
    } catch {
      return .retryRequired(.transportOrPersistence)
    }
  }
}

private actor GlobalAuthorityFirstOutcomeGate<Value: Sendable> {
  private var outcome: Value?
  private var waiters: [CheckedContinuation<Value, Never>] = []

  func resolve(_ value: Value) {
    guard outcome == nil else { return }
    outcome = value
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume(returning: value)
    }
  }

  func wait() async -> Value {
    if let outcome { return outcome }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private func withGlobalAuthorityTimeout(
  _ duration: Duration,
  operation: @escaping @Sendable () async -> GlobalAuthorityChannelOutcome
) async -> GlobalAuthorityChannelOutcome {
  let gate = GlobalAuthorityFirstOutcomeGate<GlobalAuthorityChannelOutcome>()
  let operationTask = Task {
    let outcome = await operation()
    await gate.resolve(outcome)
  }
  let timeoutTask = Task {
    do {
      try await Task.sleep(for: duration)
    } catch {
      return
    }
    await gate.resolve(.retryRequired(.timedOut))
  }
  let outcome = await gate.wait()
  operationTask.cancel()
  timeoutTask.cancel()
  return outcome
}
