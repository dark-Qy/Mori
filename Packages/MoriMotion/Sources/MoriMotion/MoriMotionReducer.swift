import Foundation

public struct MoriMotionRequest: Equatable, Sendable {
  public let motionID: MoriMotionID
  public let identity: String
  public let characterID: String
  public let surface: String
  public let requestedAt: Date
  public let reduceMotion: Bool
  public let completionDeadline: Date?

  public init(
    motionID: MoriMotionID,
    identity: String,
    characterID: String,
    surface: String,
    requestedAt: Date,
    reduceMotion: Bool = false,
    completionDeadline: Date? = nil
  ) {
    self.motionID = motionID
    self.identity = identity
    self.characterID = characterID
    self.surface = surface
    self.requestedAt = requestedAt
    self.reduceMotion = reduceMotion
    self.completionDeadline = completionDeadline
  }

  public func isExpired(at date: Date) -> Bool {
    completionDeadline.map { $0 <= date } ?? false
  }
}

public enum MoriRenderingMode: Equatable, Sendable {
  case animated(framesPerSecond: Int, playback: MoriPlayback)
  case staticKeyframe(frameIndex: Int, fadeMilliseconds: Int)
}

public struct MoriMotionPresentation: Equatable, Sendable {
  public let requestIdentity: String
  public let requestedMotionID: MoriMotionID
  public let motionID: MoriMotionID
  public let characterID: String
  public let surface: String
  public let priorityClass: MoriPriorityClass
  public let frameNames: [String]
  public let renderingMode: MoriRenderingMode
  public let voiceOverKey: String
  public let visibleAlternateKey: String
}

public struct MoriActiveMotion: Equatable, Sendable {
  public let request: MoriMotionRequest
  public let resolved: MoriResolvedMotion
  public let presentation: MoriMotionPresentation
  public let activatedAt: Date
}

public struct MoriQueuedMotion: Equatable, Sendable {
  public let request: MoriMotionRequest
  public let resolved: MoriResolvedMotion
}

public struct MoriMotionState: Equatable, Sendable {
  public var currentIdle: MoriMotionID
  public var selectedCharacterID: String?
  public var selectedSurface: String?
  public var reduceMotion: Bool
  public var active: MoriActiveMotion?
  public var queued: [MoriQueuedMotion]
  public var isForeground: Bool
  public var seenRequestIdentities: Set<String>
  public var emittedHapticIdentities: Set<String>
  public var lastAcceptedAtByMotion: [MoriMotionID: Date]

  public init(
    currentIdle: MoriMotionID = .idleNeutral,
    selectedCharacterID: String? = nil,
    selectedSurface: String? = nil,
    reduceMotion: Bool = false,
    active: MoriActiveMotion? = nil,
    queued: [MoriQueuedMotion] = [],
    isForeground: Bool = true,
    seenRequestIdentities: Set<String> = [],
    emittedHapticIdentities: Set<String> = [],
    lastAcceptedAtByMotion: [MoriMotionID: Date] = [:]
  ) {
    self.currentIdle = currentIdle
    self.selectedCharacterID = selectedCharacterID
    self.selectedSurface = selectedSurface
    self.reduceMotion = reduceMotion
    self.active = active
    self.queued = queued
    self.isForeground = isForeground
    self.seenRequestIdentities = seenRequestIdentities
    self.emittedHapticIdentities = emittedHapticIdentities
    self.lastAcceptedAtByMotion = lastAcceptedAtByMotion
  }
}

public enum MoriMotionEvent: Equatable, Sendable {
  case request(MoriMotionRequest)
  case playbackCompleted(requestIdentity: String)
  case tick
  case setForeground(Bool)
  case assetUnavailable(requestIdentity: String)
}

public enum MoriCancellationReason: Equatable, Sendable {
  case interrupted
  case replaced
  case expired
  case background
  case missingAsset
}

public enum MoriMotionEffect: Equatable, Sendable {
  case transition(MoriMotionPresentation)
  case cancel(requestIdentity: String, reason: MoriCancellationReason)
  case haptic(requestIdentity: String, category: MoriHaptic)
}

public enum MoriAssetInventory: Equatable, Sendable {
  case unchecked
  case available(Set<String>)

  public func contains(_ assetName: String) -> Bool {
    switch self {
    case .unchecked: true
    case .available(let names): names.contains(assetName)
    }
  }
}

/// A convenience value wrapper around ``MoriMotionReducer``.
public struct MoriMotionCoordinator: Equatable, Sendable {
  public var state: MoriMotionState
  public var catalog: MoriMotionCatalog
  public var assets: MoriAssetInventory
  public var enabledCharacterIDs: Set<String>

  public init(
    state: MoriMotionState = MoriMotionState(),
    catalog: MoriMotionCatalog,
    assets: MoriAssetInventory = .unchecked,
    enabledCharacterIDs: Set<String> = ["penguin"]
  ) {
    self.state = state
    self.catalog = catalog
    self.assets = assets
    self.enabledCharacterIDs = enabledCharacterIDs
  }

  @discardableResult
  public mutating func send(
    _ event: MoriMotionEvent,
    now: Date
  ) -> [MoriMotionEffect] {
    MoriMotionReducer.reduce(
      state: &state,
      event: event,
      now: now,
      catalog: catalog,
      assets: assets,
      enabledCharacterIDs: enabledCharacterIDs
    )
  }
}

/// A deterministic value reducer. It performs no timers, I/O, rendering, or haptics.
public enum MoriMotionReducer {
  public static func reduce(
    state: inout MoriMotionState,
    event: MoriMotionEvent,
    now: Date,
    catalog: MoriMotionCatalog,
    assets: MoriAssetInventory = .unchecked,
    enabledCharacterIDs: Set<String> = ["penguin"]
  ) -> [MoriMotionEffect] {
    pruneExpiredQueue(state: &state, now: now)

    switch event {
    case .request(let request):
      return submit(
        request,
        state: &state,
        now: now,
        catalog: catalog,
        assets: assets,
        enabledCharacterIDs: enabledCharacterIDs
      )

    case .playbackCompleted(let identity):
      guard let active = state.active,
        active.request.identity == identity
      else { return [] }

      switch active.resolved.definition.returnPolicy {
      case .remain:
        return []
      case .currentIdle:
        state.active = nil
        return settle(
          state: &state,
          now: now,
          catalog: catalog,
          assets: assets,
          enabledCharacterIDs: enabledCharacterIDs
        )
      case .idleResting:
        if catalog.definition(for: .idleResting)?.priorityClass == .idle {
          state.currentIdle = .idleResting
        } else {
          state.currentIdle = .idleNeutral
        }
        state.active = nil
        return settle(
          state: &state,
          now: now,
          catalog: catalog,
          assets: assets,
          enabledCharacterIDs: enabledCharacterIDs
        )
      }

    case .tick:
      var effects: [MoriMotionEffect] = []
      if let active = state.active, active.request.isExpired(at: now) {
        effects.append(
          .cancel(requestIdentity: active.request.identity, reason: .expired)
        )
        state.active = nil
      }
      if state.active == nil, state.isForeground {
        effects += settle(
          state: &state,
          now: now,
          catalog: catalog,
          assets: assets,
          enabledCharacterIDs: enabledCharacterIDs
        )
      }
      return effects

    case .setForeground(false):
      guard state.isForeground else { return [] }
      state.isForeground = false
      state.queued.removeAll()
      guard let active = state.active else { return [] }
      state.active = nil
      return [.cancel(requestIdentity: active.request.identity, reason: .background)]

    case .setForeground(true):
      guard !state.isForeground else { return [] }
      state.isForeground = true
      state.active = nil
      state.queued.removeAll()
      return activateIdle(
        state: &state,
        now: now,
        catalog: catalog,
        assets: assets,
        enabledCharacterIDs: enabledCharacterIDs
      )

    case .assetUnavailable(let identity):
      guard let active = state.active,
        active.request.identity == identity
      else { return [] }
      state.active = nil
      let cancellation: [MoriMotionEffect] = [
        .cancel(requestIdentity: identity, reason: .missingAsset)
      ]
      guard active.resolved.motionID != catalog.fallbackMotionID else {
        return cancellation
      }
      return cancellation
        + settle(
          state: &state,
          now: now,
          catalog: catalog,
          assets: assets,
          enabledCharacterIDs: enabledCharacterIDs
        )
    }
  }

  private static func submit(
    _ request: MoriMotionRequest,
    state: inout MoriMotionState,
    now: Date,
    catalog: MoriMotionCatalog,
    assets: MoriAssetInventory,
    enabledCharacterIDs: Set<String>
  ) -> [MoriMotionEffect] {
    if !request.identity.isEmpty {
      guard state.seenRequestIdentities.insert(request.identity).inserted else {
        return []
      }
    }
    guard state.isForeground else { return [] }

    guard !request.identity.isEmpty, !request.surface.isEmpty,
      request.completionDeadline.map({ $0 > request.requestedAt }) ?? true
    else {
      return arbitrateFallback(
        sourceRequest: request,
        state: &state,
        now: now,
        catalog: catalog,
        assets: assets,
        enabledCharacterIDs: enabledCharacterIDs
      )
    }
    guard !request.isExpired(at: now) else { return [] }

    let resolved: MoriResolvedMotion
    do {
      resolved = try catalog.resolve(request.motionID)
    } catch {
      return arbitrateFallback(
        sourceRequest: request,
        state: &state,
        now: now,
        catalog: catalog,
        assets: assets,
        enabledCharacterIDs: enabledCharacterIDs
      )
    }

    guard resolved.resolutionKind == .motion,
      enabledCharacterIDs.contains(request.characterID),
      catalog.characterIDs.contains(request.characterID),
      resolved.definition.surfaces.contains(request.surface)
    else {
      return arbitrateFallback(
        sourceRequest: request,
        state: &state,
        now: now,
        catalog: catalog,
        assets: assets,
        enabledCharacterIDs: enabledCharacterIDs
      )
    }

    guard
      hasRequiredAssets(
        request: request,
        resolved: resolved,
        catalog: catalog,
        assets: assets
      )
    else {
      return arbitrateFallback(
        sourceRequest: request,
        state: &state,
        now: now,
        catalog: catalog,
        assets: assets,
        enabledCharacterIDs: enabledCharacterIDs
      )
    }

    let cooldown = TimeInterval(resolved.definition.cooldownMilliseconds) / 1_000
    if cooldown > 0,
      let lastAcceptedAt = state.lastAcceptedAtByMotion[resolved.motionID],
      now.timeIntervalSince(lastAcceptedAt) < cooldown
    {
      return []
    }

    let queued = MoriQueuedMotion(request: request, resolved: resolved)
    guard let active = state.active else {
      commitAccepted(request, resolved: resolved, state: &state, now: now)
      return activate(
        queued,
        state: &state,
        now: now,
        catalog: catalog
      )
    }

    let incomingPriority = priority(of: resolved, catalog: catalog)
    let activePriority = priority(of: active.resolved, catalog: catalog)

    if incomingPriority > activePriority {
      commitAccepted(request, resolved: resolved, state: &state, now: now)
      state.active = nil
      return [
        .cancel(requestIdentity: active.request.identity, reason: .interrupted)
      ] + activate(queued, state: &state, now: now, catalog: catalog)
    }

    if incomingPriority == activePriority {
      guard
        shouldReplace(
          activeRequest: active.request,
          activeResolved: active.resolved,
          incoming: queued
        )
      else { return [] }
      commitAccepted(request, resolved: resolved, state: &state, now: now)
      state.active = nil
      return [
        .cancel(requestIdentity: active.request.identity, reason: .replaced)
      ] + activate(queued, state: &state, now: now, catalog: catalog)
    }

    if let sameClassIndex = state.queued.firstIndex(where: {
      $0.resolved.definition.priorityClass == resolved.definition.priorityClass
    }) {
      let existing = state.queued[sameClassIndex]
      guard
        shouldReplace(
          activeRequest: existing.request,
          activeResolved: existing.resolved,
          incoming: queued
        )
      else { return [] }
      state.queued.remove(at: sameClassIndex)
    }
    commitAccepted(request, resolved: resolved, state: &state, now: now)
    state.queued.append(queued)
    return []
  }

  private static func arbitrateFallback(
    sourceRequest: MoriMotionRequest,
    state: inout MoriMotionState,
    now: Date,
    catalog: MoriMotionCatalog,
    assets: MoriAssetInventory,
    enabledCharacterIDs: Set<String>
  ) -> [MoriMotionEffect] {
    guard
      let fallback = fallbackQueued(
        sourceRequest: sourceRequest,
        catalog: catalog,
        enabledCharacterIDs: enabledCharacterIDs
      ),
      hasRequiredAssets(
        request: fallback.request,
        resolved: fallback.resolved,
        catalog: catalog,
        assets: assets
      )
    else { return [] }
    guard let active = state.active else {
      return activate(fallback, state: &state, now: now, catalog: catalog)
    }

    let fallbackPriority = priority(of: fallback.resolved, catalog: catalog)
    let activePriority = priority(of: active.resolved, catalog: catalog)
    if fallbackPriority >= activePriority {
      state.active = nil
      return [
        .cancel(requestIdentity: active.request.identity, reason: .replaced)
      ] + activate(fallback, state: &state, now: now, catalog: catalog)
    }
    state.queued.removeAll {
      $0.resolved.definition.priorityClass == fallback.resolved.definition.priorityClass
    }
    state.queued.append(fallback)
    return []
  }

  private static func settle(
    state: inout MoriMotionState,
    now: Date,
    catalog: MoriMotionCatalog,
    assets: MoriAssetInventory,
    enabledCharacterIDs: Set<String>
  ) -> [MoriMotionEffect] {
    pruneExpiredQueue(state: &state, now: now)
    if let nextIndex = state.queued.indices.max(by: {
      let lhs = state.queued[$0]
      let rhs = state.queued[$1]
      let lhsPriority = priority(of: lhs.resolved, catalog: catalog)
      let rhsPriority = priority(of: rhs.resolved, catalog: catalog)
      if lhsPriority == rhsPriority {
        return lhs.request.requestedAt < rhs.request.requestedAt
      }
      return lhsPriority < rhsPriority
    }) {
      let next = state.queued.remove(at: nextIndex)
      if hasRequiredAssets(
        request: next.request,
        resolved: next.resolved,
        catalog: catalog,
        assets: assets
      ), enabledCharacterIDs.contains(next.request.characterID) {
        return activate(next, state: &state, now: now, catalog: catalog)
      }
      return activateFallback(
        state: &state,
        sourceRequest: next.request,
        now: now,
        catalog: catalog,
        assets: assets,
        enabledCharacterIDs: enabledCharacterIDs
      )
    }
    return activateIdle(
      state: &state,
      now: now,
      catalog: catalog,
      assets: assets,
      enabledCharacterIDs: enabledCharacterIDs
    )
  }

  private static func activateIdle(
    state: inout MoriMotionState,
    now: Date,
    catalog: MoriMotionCatalog,
    assets: MoriAssetInventory,
    enabledCharacterIDs: Set<String>
  ) -> [MoriMotionEffect] {
    guard
      let character = state.selectedCharacterID.flatMap({
        catalog.characterIDs.contains($0) && enabledCharacterIDs.contains($0) ? $0 : nil
      }) ?? catalog.characterIDs.first(where: enabledCharacterIDs.contains)
    else {
      return []
    }
    let idleResolution = try? catalog.resolve(state.currentIdle)
    let idleID =
      idleResolution?.definition.priorityClass == .idle
        && idleResolution?.resolutionKind == .motion ? state.currentIdle : catalog.fallbackMotionID
    let idleSurfaces = (try? catalog.resolve(idleID))?.definition.surfaces ?? ["watch.home"]
    let surface =
      state.selectedSurface.flatMap {
        idleSurfaces.contains($0) ? $0 : nil
      } ?? idleSurfaces.first ?? "watch.home"
    let request = MoriMotionRequest(
      motionID: idleID,
      identity: "mori.system.idle.\(now.timeIntervalSinceReferenceDate)",
      characterID: character,
      surface: surface,
      requestedAt: now,
      reduceMotion: state.reduceMotion
    )
    let resolved =
      (try? catalog.resolve(idleID))
      ?? (try! MoriMotionCatalog.emergencyFallback.resolve(.idleNeutral))
    if hasRequiredAssets(
      request: request,
      resolved: resolved,
      catalog: catalog,
      assets: assets
    ) {
      return activate(
        MoriQueuedMotion(request: request, resolved: resolved),
        state: &state,
        now: now,
        catalog: catalog
      )
    }
    return activateFallback(
      state: &state,
      sourceRequest: request,
      now: now,
      catalog: catalog,
      assets: assets,
      enabledCharacterIDs: enabledCharacterIDs
    )
  }

  private static func activateFallback(
    state: inout MoriMotionState,
    sourceRequest: MoriMotionRequest,
    now: Date,
    catalog: MoriMotionCatalog,
    assets: MoriAssetInventory,
    enabledCharacterIDs: Set<String>
  ) -> [MoriMotionEffect] {
    guard
      let fallback = fallbackQueued(
        sourceRequest: sourceRequest,
        catalog: catalog,
        enabledCharacterIDs: enabledCharacterIDs
      ),
      hasRequiredAssets(
        request: fallback.request,
        resolved: fallback.resolved,
        catalog: catalog,
        assets: assets
      )
    else { return [] }
    return activate(
      fallback,
      state: &state,
      now: now,
      catalog: catalog
    )
  }

  private static func fallbackQueued(
    sourceRequest: MoriMotionRequest,
    catalog: MoriMotionCatalog,
    enabledCharacterIDs: Set<String>
  ) -> MoriQueuedMotion? {
    let fallbackCatalog =
      (try? catalog.resolve(catalog.fallbackMotionID)) != nil
      ? catalog
      : MoriMotionCatalog.emergencyFallback
    let resolved = try! fallbackCatalog.resolve(fallbackCatalog.fallbackMotionID)
    guard
      let character =
        (fallbackCatalog.characterIDs.contains(sourceRequest.characterID)
          && enabledCharacterIDs.contains(sourceRequest.characterID))
        ? sourceRequest.characterID
        : fallbackCatalog.characterIDs.first(where: enabledCharacterIDs.contains)
    else { return nil }
    let fallbackRequest = MoriMotionRequest(
      motionID: fallbackCatalog.fallbackMotionID,
      identity: sourceRequest.identity.isEmpty
        ? "mori.fallback.\(sourceRequest.requestedAt.timeIntervalSinceReferenceDate)"
        : sourceRequest.identity,
      characterID: character,
      surface: sourceRequest.surface.isEmpty ? "watch.home" : sourceRequest.surface,
      requestedAt: sourceRequest.requestedAt,
      reduceMotion: sourceRequest.reduceMotion,
      completionDeadline: nil
    )
    return MoriQueuedMotion(request: fallbackRequest, resolved: resolved)
  }

  private static func activate(
    _ queued: MoriQueuedMotion,
    state: inout MoriMotionState,
    now: Date,
    catalog: MoriMotionCatalog
  ) -> [MoriMotionEffect] {
    let presentation = makePresentation(
      request: queued.request,
      resolved: queued.resolved,
      catalog: catalog
    )
    state.active = MoriActiveMotion(
      request: queued.request,
      resolved: queued.resolved,
      presentation: presentation,
      activatedAt: now
    )
    var effects: [MoriMotionEffect] = [.transition(presentation)]
    let haptic = queued.resolved.definition.haptic
    if haptic != .none,
      state.emittedHapticIdentities.insert(queued.request.identity).inserted
    {
      effects.append(
        .haptic(requestIdentity: queued.request.identity, category: haptic)
      )
    }
    return effects
  }

  private static func makePresentation(
    request: MoriMotionRequest,
    resolved: MoriResolvedMotion,
    catalog: MoriMotionCatalog
  ) -> MoriMotionPresentation {
    let frames = catalog.defaults.frameOrder.map {
      catalog.assetKeyTemplate
        .replacingOccurrences(of: "{character}", with: request.characterID)
        .replacingOccurrences(of: "{motion}", with: resolved.assetMotionID)
        .replacingOccurrences(of: "{frame}", with: $0)
    }
    let mode: MoriRenderingMode
    let visibleFrames: [String]
    if request.reduceMotion {
      mode = .staticKeyframe(
        frameIndex: resolved.definition.reduceMotionFrame,
        fadeMilliseconds: catalog.defaults.reduceMotionTransitionMilliseconds
      )
      visibleFrames = [frames[resolved.definition.reduceMotionFrame]]
    } else {
      mode = .animated(
        framesPerSecond: catalog.defaults.framesPerSecond,
        playback: resolved.definition.playback
      )
      visibleFrames = frames
    }
    return MoriMotionPresentation(
      requestIdentity: request.identity,
      requestedMotionID: request.motionID,
      motionID: resolved.motionID,
      characterID: request.characterID,
      surface: request.surface,
      priorityClass: resolved.definition.priorityClass,
      frameNames: visibleFrames,
      renderingMode: mode,
      voiceOverKey: resolved.definition.voiceOverKey,
      visibleAlternateKey: resolved.definition.visibleAlternateKey
    )
  }

  private static func hasRequiredAssets(
    request: MoriMotionRequest,
    resolved: MoriResolvedMotion,
    catalog: MoriMotionCatalog,
    assets: MoriAssetInventory
  ) -> Bool {
    guard case .available = assets else { return true }
    let names = catalog.defaults.frameOrder.map {
      catalog.assetKeyTemplate
        .replacingOccurrences(of: "{character}", with: request.characterID)
        .replacingOccurrences(of: "{motion}", with: resolved.assetMotionID)
        .replacingOccurrences(of: "{frame}", with: $0)
    }
    if request.reduceMotion {
      return assets.contains(names[resolved.definition.reduceMotionFrame])
    }
    return names.allSatisfy(assets.contains)
  }

  private static func priority(
    of resolved: MoriResolvedMotion,
    catalog: MoriMotionCatalog
  ) -> Int {
    catalog.priority(for: resolved.definition.priorityClass)
  }

  private static func commitAccepted(
    _ request: MoriMotionRequest,
    resolved: MoriResolvedMotion,
    state: inout MoriMotionState,
    now: Date
  ) {
    state.selectedCharacterID = request.characterID
    state.selectedSurface = request.surface
    state.reduceMotion = request.reduceMotion
    state.lastAcceptedAtByMotion[resolved.motionID] = now
    if resolved.definition.priorityClass == .idle {
      state.currentIdle = resolved.motionID
    }
  }

  private static func shouldReplace(
    activeRequest: MoriMotionRequest,
    activeResolved: MoriResolvedMotion,
    incoming: MoriQueuedMotion
  ) -> Bool {
    guard
      activeResolved.definition.priorityClass
        == incoming.resolved.definition.priorityClass
    else { return false }

    switch incoming.resolved.definition.replacementPolicy {
    case .ignoreDuplicateIdentity:
      return activeRequest.identity != incoming.request.identity
    case .replaceSameKind:
      return true
    case .newestSameKind, .restartNewest:
      return incoming.request.requestedAt >= activeRequest.requestedAt
    }
  }

  private static func pruneExpiredQueue(state: inout MoriMotionState, now: Date) {
    state.queued.removeAll { $0.request.isExpired(at: now) }
  }
}
