import Foundation
import MoriDomain

public struct CompanionSensingConfiguration: Hashable, Sendable {
  public let profile: RuntimeProfile
  public let enabled: Bool
  public let sensingEpoch: SensingEpoch
  public let effectiveAt: Date

  public init(
    profile: RuntimeProfile,
    enabled: Bool,
    sensingEpoch: SensingEpoch,
    effectiveAt: Date
  ) {
    self.profile = profile
    self.enabled = enabled
    self.sensingEpoch = sensingEpoch
    self.effectiveAt = effectiveAt
  }
}

/// An adapter callback must retain this token from the session that created it.
/// The coordinator validates the complete token again after every asynchronous
/// boundary before companion use is authorized.
public struct CompanionSensingSessionToken: Hashable, Sendable {
  public let profile: RuntimeProfile
  public let sensingEpoch: SensingEpoch
  public let generation: UInt64
  public let activeSince: Date

  public init(
    profile: RuntimeProfile,
    sensingEpoch: SensingEpoch,
    generation: UInt64,
    activeSince: Date
  ) {
    self.profile = profile
    self.sensingEpoch = sensingEpoch
    self.generation = generation
    self.activeSince = activeSince
  }
}

public protocol CompanionSensingAdapterControl: Sendable {
  func start(session: CompanionSensingSessionToken) async throws
  func stop() async
}

/// Persists the local sensing authority before adapters are allowed to emit
/// companion-authorized evidence.
public protocol CompanionSensingStateStore: Sendable {
  func commit(_ configuration: CompanionSensingConfiguration) async throws
}

/// Expires domain reminders and cancels any app-owned pending presentation
/// derived from the superseded sensing epoch.
public protocol CompanionSensingPendingWork: Sendable {
  func invalidatePendingWork(
    for profile: RuntimeProfile,
    supersededBy sensingEpoch: SensingEpoch,
    at date: Date
  ) async throws
}

public protocol ProfileSelectionAuthorizing: Sendable {
  func authorize(_ profile: RuntimeProfile) async -> ProfileSelectionAccess
}

extension ProfileSelectionAuthority: ProfileSelectionAuthorizing {}

public enum CompanionSensingTransitionResult: Equatable, Sendable {
  case applied(CompanionSensingSessionToken?)
  case duplicate(CompanionSensingSessionToken?)
}

public enum CompanionSensingCoordinatorError: Error, Equatable, Sendable {
  case invalidConfiguration
  case profileNotSelected
  case nonAdvancingSensingEpoch
  case adapterStartFailed
  case transitionSuperseded
}

/// Owns the privacy boundary between a saved "Mori 随行" preference and live
/// passive adapters. Disabling first invalidates callback generations, then
/// stops adapters and pending presentation before committing the disabled
/// authority. Enabling commits the new authority before starting adapters.
public actor CompanionSensingCoordinator {
  private struct RequestIntent: Hashable, Sendable {
    let profile: RuntimeProfile
    let enabled: Bool
    let sensingEpoch: SensingEpoch
    let requestGeneration: UInt64
  }

  private let selectionAuthority: any ProfileSelectionAuthorizing
  private let stateStore: any CompanionSensingStateStore
  private let adapters: [any CompanionSensingAdapterControl]
  private let pendingWork: any CompanionSensingPendingWork

  private var configuration: CompanionSensingConfiguration?
  private var session: CompanionSensingSessionToken?
  private var sessionIsReady = false
  private var generation: UInt64 = 0
  private var requestGeneration: UInt64 = 0
  private var transitionGeneration: UInt64 = 0
  private var highestRequestedIntent: [RuntimeProfile: RequestIntent] = [:]
  private var latestRequestIntent: RequestIntent?
  private var activeTransitionIntent: RequestIntent?

  public init(
    selectionAuthority: any ProfileSelectionAuthorizing,
    stateStore: any CompanionSensingStateStore,
    adapters: [any CompanionSensingAdapterControl],
    pendingWork: any CompanionSensingPendingWork,
    initialConfiguration: CompanionSensingConfiguration? = nil
  ) throws {
    if let initialConfiguration {
      guard
        initialConfiguration.profile.isValid,
        initialConfiguration.sensingEpoch.isValid
      else {
        throw CompanionSensingCoordinatorError.invalidConfiguration
      }
    }
    self.selectionAuthority = selectionAuthority
    self.stateStore = stateStore
    self.adapters = adapters
    self.pendingWork = pendingWork
    configuration = initialConfiguration
    if let initialConfiguration {
      let intent = RequestIntent(
        profile: initialConfiguration.profile,
        enabled: initialConfiguration.enabled,
        sensingEpoch: initialConfiguration.sensingEpoch,
        requestGeneration: requestGeneration
      )
      highestRequestedIntent[initialConfiguration.profile] = intent
      latestRequestIntent = intent
    }
  }

  public func currentConfiguration() -> CompanionSensingConfiguration? {
    configuration
  }

  public func currentSession() -> CompanionSensingSessionToken? {
    sessionIsReady ? session : nil
  }

  @discardableResult
  public func setEnabled(
    _ enabled: Bool,
    profile: RuntimeProfile,
    sensingEpoch: SensingEpoch,
    effectiveAt: Date
  ) async throws -> CompanionSensingTransitionResult {
    guard profile.isValid, sensingEpoch.isValid else {
      throw CompanionSensingCoordinatorError.invalidConfiguration
    }
    let intent = try reserveIntent(
      enabled: enabled,
      profile: profile,
      sensingEpoch: sensingEpoch
    )
    let initialAccess = await selectionAuthority.authorize(profile)
    try requireHighestIntent(intent)
    guard initialAccess == .authorized else {
      throw CompanionSensingCoordinatorError.profileNotSelected
    }
    if activeTransitionIntent == intent {
      return .duplicate(sessionIsReady ? session : nil)
    }

    if let configuration,
      configuration.profile == profile,
      configuration.sensingEpoch == sensingEpoch,
      configuration.enabled == enabled
    {
      if enabled, session == nil {
        let transition = beginTransition(for: intent)
        defer { finishTransition(transition, intent: intent) }
        return .applied(
          try await startSession(
            for: configuration,
            transition: transition,
            intent: intent
          )
        )
      }
      return .duplicate(sessionIsReady ? session : nil)
    }
    if let configuration,
      configuration.profile == profile,
      sensingEpoch <= configuration.sensingEpoch
    {
      throw CompanionSensingCoordinatorError.nonAdvancingSensingEpoch
    }

    let next = CompanionSensingConfiguration(
      profile: profile,
      enabled: enabled,
      sensingEpoch: sensingEpoch,
      effectiveAt: effectiveAt
    )

    let transition = beginTransition(for: intent)
    defer { finishTransition(transition, intent: intent) }
    let previousConfiguration = configuration
    invalidateSession()
    if let previousConfiguration {
      try await stopAdapters(
        whileCurrent: transition,
        intent: intent
      )
      try await pendingWork.invalidatePendingWork(
        for: previousConfiguration.profile,
        supersededBy: sensingEpoch,
        at: effectiveAt
      )
      try requireCurrentTransition(transition, intent: intent)
    }

    let accessBeforeCommit = await selectionAuthority.authorize(profile)
    try requireCurrentTransition(transition, intent: intent)
    guard accessBeforeCommit == .authorized else {
      throw CompanionSensingCoordinatorError.profileNotSelected
    }
    try await stateStore.commit(next)
    try requireCurrentTransition(transition, intent: intent)
    let accessAfterCommit = await selectionAuthority.authorize(profile)
    try requireCurrentTransition(transition, intent: intent)
    guard accessAfterCommit == .authorized else {
      throw CompanionSensingCoordinatorError.profileNotSelected
    }
    configuration = next
    guard enabled else {
      return .applied(nil)
    }
    return .applied(
      try await startSession(
        for: next,
        transition: transition,
        intent: intent
      )
    )
  }

  /// Stops live work without mutating the synced preference. This is used for
  /// process suspension, profile replacement, and deletion fencing.
  public func suspend() async {
    requestGeneration &+= 1
    latestRequestIntent = nil
    let suspensionGeneration = requestGeneration
    let transition = beginTransition()
    invalidateSession()
    try? await stopAdapters(
      whileCurrent: transition,
      requestGeneration: suspensionGeneration
    )
  }

  /// Returns display-only authority for every stale, pre-enable, disabled, or
  /// losing-profile callback. Callers must obtain this immediately before
  /// normalization and persistence.
  public func admission(
    for token: CompanionSensingSessionToken,
    observedAt: Date
  ) async -> EvidenceAdmissionMode {
    guard
      let expected = session,
      expected == token,
      sessionIsReady,
      observedAt >= token.activeSince
    else {
      return .displayOnly
    }

    let access = await selectionAuthority.authorize(token.profile)
    guard
      access == .authorized,
      session == expected,
      sessionIsReady,
      configuration?.enabled == true,
      configuration?.profile == token.profile,
      configuration?.sensingEpoch == token.sensingEpoch
    else {
      return .displayOnly
    }
    return .companion(token.sensingEpoch, activeSince: token.activeSince)
  }

  private func invalidateSession() {
    session = nil
    sessionIsReady = false
    generation &+= 1
  }

  @discardableResult
  private func beginTransition() -> UInt64 {
    transitionGeneration &+= 1
    activeTransitionIntent = nil
    return transitionGeneration
  }

  private func beginTransition(for intent: RequestIntent) -> UInt64 {
    let transition = beginTransition()
    activeTransitionIntent = intent
    return transition
  }

  private func finishTransition(
    _ transition: UInt64,
    intent: RequestIntent
  ) {
    if transition == transitionGeneration,
      activeTransitionIntent == intent
    {
      activeTransitionIntent = nil
    }
  }

  private func reserveIntent(
    enabled: Bool,
    profile: RuntimeProfile,
    sensingEpoch: SensingEpoch
  ) throws -> RequestIntent {
    if let highest = highestRequestedIntent[profile] {
      guard sensingEpoch >= highest.sensingEpoch else {
        throw CompanionSensingCoordinatorError.nonAdvancingSensingEpoch
      }
      if sensingEpoch == highest.sensingEpoch {
        guard enabled == highest.enabled else {
          throw CompanionSensingCoordinatorError.nonAdvancingSensingEpoch
        }
        if latestRequestIntent == highest {
          return highest
        }
      }
    }
    requestGeneration &+= 1
    let intent = RequestIntent(
      profile: profile,
      enabled: enabled,
      sensingEpoch: sensingEpoch,
      requestGeneration: requestGeneration
    )
    highestRequestedIntent[profile] = intent
    latestRequestIntent = intent
    return intent
  }

  private func requireHighestIntent(_ expected: RequestIntent) throws {
    guard
      highestRequestedIntent[expected.profile] == expected,
      latestRequestIntent == expected,
      requestGeneration == expected.requestGeneration
    else {
      throw CompanionSensingCoordinatorError.transitionSuperseded
    }
  }

  private func requireCurrentTransition(
    _ expected: UInt64,
    intent: RequestIntent
  ) throws {
    guard expected == transitionGeneration else {
      throw CompanionSensingCoordinatorError.transitionSuperseded
    }
    try requireHighestIntent(intent)
  }

  private func startSession(
    for configuration: CompanionSensingConfiguration,
    transition: UInt64,
    intent: RequestIntent
  ) async throws -> CompanionSensingSessionToken {
    try requireCurrentTransition(transition, intent: intent)
    generation &+= 1
    let newSession = CompanionSensingSessionToken(
      profile: configuration.profile,
      sensingEpoch: configuration.sensingEpoch,
      generation: generation,
      activeSince: configuration.effectiveAt
    )
    session = newSession
    sessionIsReady = false
    do {
      for adapter in adapters {
        try await adapter.start(session: newSession)
        try requireCurrentTransition(transition, intent: intent)
        guard session == newSession else {
          throw CompanionSensingCoordinatorError.transitionSuperseded
        }
        let access = await selectionAuthority.authorize(configuration.profile)
        try requireCurrentTransition(transition, intent: intent)
        guard
          session == newSession,
          access == .authorized
        else {
          throw CompanionSensingCoordinatorError.adapterStartFailed
        }
      }
      try requireCurrentTransition(transition, intent: intent)
      guard session == newSession else {
        throw CompanionSensingCoordinatorError.transitionSuperseded
      }
      sessionIsReady = true
    } catch {
      guard
        highestRequestedIntent[intent.profile] == intent,
        latestRequestIntent == intent,
        requestGeneration == intent.requestGeneration
      else {
        throw CompanionSensingCoordinatorError.transitionSuperseded
      }
      guard
        transition == transitionGeneration,
        session == newSession
      else {
        throw CompanionSensingCoordinatorError.transitionSuperseded
      }
      invalidateSession()
      do {
        try await stopAdapters(
          whileCurrent: transition,
          intent: intent
        )
        try requireCurrentTransition(transition, intent: intent)
      } catch {
        throw CompanionSensingCoordinatorError.transitionSuperseded
      }
      throw CompanionSensingCoordinatorError.adapterStartFailed
    }
    return newSession
  }

  private func stopAdapters(
    whileCurrent transition: UInt64,
    intent: RequestIntent
  ) async throws {
    for adapter in adapters {
      try requireCurrentTransition(transition, intent: intent)
      await adapter.stop()
      try requireCurrentTransition(transition, intent: intent)
    }
  }

  private func stopAdapters(
    whileCurrent transition: UInt64,
    requestGeneration expectedRequestGeneration: UInt64
  ) async throws {
    for adapter in adapters {
      guard
        transition == transitionGeneration,
        requestGeneration == expectedRequestGeneration
      else {
        throw CompanionSensingCoordinatorError.transitionSuperseded
      }
      await adapter.stop()
      guard
        transition == transitionGeneration,
        requestGeneration == expectedRequestGeneration
      else {
        throw CompanionSensingCoordinatorError.transitionSuperseded
      }
    }
  }
}
