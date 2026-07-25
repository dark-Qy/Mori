import Foundation
import MoriDomain

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
  case schemaIncompatible(
    channel: GlobalAuthoritySyncChannel,
    receivedSchemaVersion: UInt16,
    maximumSupportedSchemaVersion: UInt16
  )
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
  case offline
  case schemaIncompatible
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
  case consentRevocationDidNotConverge
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
      let frame: GlobalConsentSyncFrame
      do {
        frame = try wireCodec.decodeConsent(payload)
      } catch let error as GlobalAuthoritySyncWireError {
        _ = try await repository.revokeConsentForIncompatiblePeer()
        throw error
      }
      if frame.isLegacyV1 {
        let revocation = try await persistLegacyConsentRevocation(
          peerConsent: frame.consent
        )
        return try wireCodec.encode(
          GlobalConsentSyncFrame(
            schemaVersion: GlobalConsentSyncFrame.legacySchemaVersion,
            deletionRoot: revocation.deletionRoot,
            consent: revocation.consent
          )
        )
      }
      let merge = try await repository.merge(
        consent: frame.consent,
        deletionRoot: frame.deletionRoot
      )
      switch merge {
      case .applied, .duplicate:
        let current = try await repository.current()
        return try wireCodec.encode(
          GlobalConsentSyncFrame(
            deletionRoot: current.deletionRoot,
            consent: current.consent
          )
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
    } catch let error as GlobalAuthoritySyncWireError {
      if case .unsupportedSchema = error {
        return .retryRequired(.schemaIncompatible)
      }
      return .retryRequired(.invalidWire)
    } catch is GlobalAuthorityPeerSyncError {
      return .retryRequired(.mergeRejected)
    } catch let error as GlobalAuthorityPeerTransportError {
      switch error {
      case .offline:
        return .retryRequired(.offline)
      case .schemaIncompatible:
        return .retryRequired(.schemaIncompatible)
      case .injectedFailure:
        return .retryRequired(.transportOrPersistence)
      }
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
        GlobalConsentSyncFrame(
          deletionRoot: current.deletionRoot,
          consent: current.consent
        )
      )
      try Task.checkCancellation()
      let response: Data
      do {
        response = try await transport.exchange(
          channel: .consent,
          payload: payload
        )
      } catch let error as GlobalAuthorityPeerTransportError {
        return try await handleConsentTransportError(
          error,
          using: transport
        )
      } catch GlobalAuthoritySyncWireError.unsupportedSchema(
        let schemaVersion
      ) {
        return try await handleConsentSchemaIncompatibility(
          receivedSchemaVersion: schemaVersion,
          maximumSupportedSchemaVersion:
            GlobalConsentSyncFrame.legacySchemaVersion,
          using: transport
        )
      }
      try Task.checkCancellation()
      let frame: GlobalConsentSyncFrame
      do {
        frame = try wireCodec.decodeConsent(response)
      } catch let error as GlobalAuthoritySyncWireError {
        _ = try await repository.revokeConsentForIncompatiblePeer()
        throw error
      }
      if frame.isLegacyV1 {
        let revocation = try await persistLegacyConsentRevocation(
          peerConsent: frame.consent
        )
        return try await synchronizeLegacyConsent(
          using: transport,
          revocation: revocation
        )
      }
      return try await mergeCurrentConsentFrame(frame)
    } catch let error as GlobalAuthoritySyncWireError {
      if case .unsupportedSchema = error {
        return .retryRequired(.schemaIncompatible)
      }
      return .retryRequired(.invalidWire)
    } catch is GlobalAuthorityPeerSyncError {
      return .retryRequired(.mergeRejected)
    } catch {
      return .retryRequired(.transportOrPersistence)
    }
  }

  private func handleConsentTransportError<
    Transport: GlobalAuthorityPeerTransport
  >(
    _ error: GlobalAuthorityPeerTransportError,
    using transport: Transport
  ) async throws -> GlobalAuthorityChannelOutcome {
    switch error {
    case .offline:
      return .retryRequired(.offline)
    case .injectedFailure:
      return .retryRequired(.transportOrPersistence)
    case .schemaIncompatible(
      let channel,
      let receivedSchemaVersion,
      let maximumSupportedSchemaVersion
    ):
      guard channel == .consent else {
        _ = try await repository.revokeConsentForIncompatiblePeer()
        return .retryRequired(.schemaIncompatible)
      }
      return try await handleConsentSchemaIncompatibility(
        receivedSchemaVersion: receivedSchemaVersion,
        maximumSupportedSchemaVersion: maximumSupportedSchemaVersion,
        using: transport
      )
    }
  }

  private func handleConsentSchemaIncompatibility<
    Transport: GlobalAuthorityPeerTransport
  >(
    receivedSchemaVersion: UInt16,
    maximumSupportedSchemaVersion: UInt16,
    using transport: Transport
  ) async throws -> GlobalAuthorityChannelOutcome {
    let revocation = try await persistLegacyConsentRevocation()
    guard
      receivedSchemaVersion
        == GlobalConsentSyncFrame.currentSchemaVersion,
      maximumSupportedSchemaVersion
        == GlobalConsentSyncFrame.legacySchemaVersion
    else {
      return .retryRequired(.schemaIncompatible)
    }
    return try await synchronizeLegacyConsent(
      using: transport,
      revocation: revocation
    )
  }

  private struct PersistedLegacyConsentRevocation: Sendable {
    let deletionRoot: DeletionAuthorityRoot
    let consent: GlobalConsentState
    let localStateChanged: Bool
  }

  /// A schema-v1 peer has no deletion root. It can receive only a fail-closed
  /// consent frame and can never expand v2 authority. One bounded downgrade is
  /// attempted per lifecycle synchronization.
  private func synchronizeLegacyConsent<
    Transport: GlobalAuthorityPeerTransport
  >(
    using transport: Transport,
    revocation: PersistedLegacyConsentRevocation
  ) async throws -> GlobalAuthorityChannelOutcome {
    let payload = try wireCodec.encode(
      GlobalConsentSyncFrame(
        schemaVersion: GlobalConsentSyncFrame.legacySchemaVersion,
        deletionRoot: revocation.deletionRoot,
        consent: revocation.consent
      )
    )
    try Task.checkCancellation()
    let response: Data
    do {
      response = try await transport.exchange(
        channel: .consent,
        payload: payload
      )
    } catch GlobalAuthorityPeerTransportError.offline {
      return .retryRequired(.offline)
    } catch let error as GlobalAuthorityPeerTransportError {
      if case .schemaIncompatible = error {
        return .retryRequired(.schemaIncompatible)
      }
      return .retryRequired(.transportOrPersistence)
    }
    try Task.checkCancellation()
    let frame = try wireCodec.decodeConsent(response)
    guard frame.isLegacyV1 else {
      let outcome = try await mergeCurrentConsentFrame(frame)
      switch outcome {
      case .synchronized(let changed):
        return .synchronized(
          localStateChanged:
            revocation.localStateChanged || changed
        )
      case .retryRequired:
        return outcome
      }
    }

    let responseRevocation = try await persistLegacyConsentRevocation(
      peerConsent: frame.consent
    )
    let peerIsDisabled = MoriConsentKind.allCases.allSatisfy {
      !frame.consent[$0].enabled
    }
    guard peerIsDisabled else {
      // The peer had a causally newer grant. Its revision is now persisted as
      // a local revocation, so the next bounded downgrade can close the peer.
      return .retryRequired(.schemaIncompatible)
    }
    return .synchronized(
      localStateChanged:
        revocation.localStateChanged
        || responseRevocation.localStateChanged
    )
  }

  private func mergeCurrentConsentFrame(
    _ frame: GlobalConsentSyncFrame
  ) async throws -> GlobalAuthorityChannelOutcome {
    let merge = try await repository.merge(
      consent: frame.consent,
      deletionRoot: frame.deletionRoot
    )
    switch merge {
    case .applied:
      return .synchronized(localStateChanged: true)
    case .duplicate:
      return .synchronized(localStateChanged: false)
    case .rejected(let reason):
      throw GlobalAuthorityPeerSyncError.rejectedConsent(reason)
    }
  }

  /// Persists a revocation at least as new as every revision exposed by an
  /// incompatible v1 peer. The peer's enabled value is never merged and its
  /// missing deletion root is never trusted.
  private func persistLegacyConsentRevocation(
    peerConsent: GlobalConsentState? = nil
  ) async throws -> PersistedLegacyConsentRevocation {
    var changed =
      try await repository.revokeConsentForIncompatiblePeer()
    for _ in 0..<8 {
      let current = try await repository.current()
      var failClosed = current.consent
      for kind in MoriConsentKind.allCases {
        let revision = max(
          current.consent[kind].revision,
          peerConsent?[kind].revision ?? current.consent[kind].revision
        )
        failClosed = failClosed.replacing(
          kind,
          with: MoriConsentRecord(
            enabled: false,
            disclosureVersion: 0,
            revision: revision,
            authorDevice: .phone
          )
        )
      }
      let merge = try await repository.merge(
        consent: failClosed,
        deletionRoot: current.deletionRoot
      )
      let persisted: GlobalConsentState
      switch merge {
      case .applied(let consent):
        changed = true
        persisted = consent
      case .duplicate(let consent):
        persisted = consent
      case .rejected(let reason):
        throw GlobalAuthorityPeerSyncError.rejectedConsent(reason)
      }
      guard
        MoriConsentKind.allCases.allSatisfy({
          !persisted[$0].enabled
        })
      else {
        continue
      }
      return PersistedLegacyConsentRevocation(
        deletionRoot: current.deletionRoot,
        consent: persisted,
        localStateChanged: changed
      )
    }
    throw GlobalAuthorityPeerSyncError.consentRevocationDidNotConverge
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
