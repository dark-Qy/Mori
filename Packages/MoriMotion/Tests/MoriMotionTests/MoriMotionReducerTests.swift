import Foundation
import Testing

@testable import MoriMotion

@Suite("Mori motion reducer")
struct MoriMotionReducerTests {
  private let epoch = Date(timeIntervalSinceReferenceDate: 1_000)

  @Test("strictly arbitrates touch over event, conversation, companion, attention, and idle")
  func strictPriorityOrder() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    let sequence: [MoriMotionID] = [
      "idle_neutral", "idle_curious", "walk", "speaking", "story_reaction", "touch_head",
    ]

    for (offset, id) in sequence.enumerated() {
      let timestamp = time(Double(offset))
      let effects = coordinator.send(
        .request(request(id, identity: "p\(offset)", at: timestamp)),
        now: timestamp
      )
      #expect(coordinator.state.active?.resolved.motionID == id)
      if offset > 0 {
        #expect(
          effects.contains {
            if case .cancel(_, .interrupted) = $0 { return true }
            return false
          }
        )
      }
    }
    #expect(
      coordinator.state.active?.resolved.definition.priorityClass == .touch
    )
  }

  @Test("lower work waits, while a newer reality event replaces the older event")
  func queueAndNewestEventReplacement() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    _ = coordinator.send(
      .request(request("touch_head", identity: "touch", at: time(0))),
      now: time(0)
    )
    _ = coordinator.send(
      .request(request("story_reaction", identity: "event-old", at: time(1))),
      now: time(1)
    )
    _ = coordinator.send(
      .request(request("story_reaction", identity: "event-new", at: time(2))),
      now: time(2)
    )

    #expect(coordinator.state.queued.map(\.request.identity) == ["event-new"])
    let effects = coordinator.send(
      .playbackCompleted(requestIdentity: "touch"),
      now: time(3)
    )
    #expect(coordinator.state.active?.request.identity == "event-new")
    #expect(effects.contains { if case .transition = $0 { true } else { false } })
  }

  @Test("a delayed older same-class request cannot replace the newest request")
  func replacementPolicyKeepsNewest() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    _ = coordinator.send(
      .request(
        MoriMotionRequest(
          motionID: "story_reaction",
          identity: "newest",
          characterID: "penguin",
          surface: "phone.mori",
          requestedAt: time(2),
          reduceMotion: true
        )
      ),
      now: time(2)
    )
    let effects = coordinator.send(
      .request(request("story_reaction", identity: "delayed-old", at: time(1))),
      now: time(3)
    )

    #expect(effects.isEmpty)
    #expect(coordinator.state.active?.request.identity == "newest")
    #expect(coordinator.state.selectedSurface == "phone.mori")
    #expect(coordinator.state.reduceMotion)
  }

  @Test("a rejected delayed request does not consume cooldown or presentation state")
  func rejectedRequestDoesNotMutateAcceptedState() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    _ = coordinator.send(
      .request(request("touch_head", identity: "accepted", at: time(2))),
      now: time(2)
    )
    let delayed = MoriMotionRequest(
      motionID: "touch_head",
      identity: "delayed",
      characterID: "penguin",
      surface: "phone.mori",
      requestedAt: time(1),
      reduceMotion: true
    )
    #expect(coordinator.send(.request(delayed), now: time(3)).isEmpty)
    #expect(coordinator.state.selectedSurface == "watch.home")
    #expect(!coordinator.state.reduceMotion)
    #expect(coordinator.state.lastAcceptedAtByMotion["touch_head"] == time(2))

    let accepted = coordinator.send(
      .request(request("touch_head", identity: "actually-new", at: time(3.1))),
      now: time(3.1)
    )
    #expect(accepted.presentation?.requestIdentity == "actually-new")
  }

  @Test("duplicate identity never restarts and same-motion cooldown debounces")
  func duplicateCooldownAndHapticOnce() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)

    let first = coordinator.send(
      .request(request("touch_head", identity: "touch-1", at: time(0))),
      now: time(0)
    )
    let duplicate = coordinator.send(
      .request(request("touch_head", identity: "touch-1", at: time(1))),
      now: time(1)
    )
    let coolingDown = coordinator.send(
      .request(request("touch_head", identity: "touch-2", at: time(0.1))),
      now: time(0.1)
    )
    let afterCooldown = coordinator.send(
      .request(request("touch_head", identity: "touch-3", at: time(0.4))),
      now: time(0.4)
    )

    #expect(first.hapticCount == 1)
    #expect(duplicate.isEmpty)
    #expect(coolingDown.isEmpty)
    #expect(afterCooldown.hapticCount == 1)
    #expect(coordinator.state.emittedHapticIdentities == ["touch-1", "touch-3"])
  }

  @Test("release allowlist defaults to penguin and future characters require explicit enablement")
  func characterReadinessAllowlist() {
    let catalog = TestCatalog.make()
    let polarRequest = MoriMotionRequest(
      motionID: "walk",
      identity: "polar",
      characterID: "polar_bear",
      surface: "watch.home",
      requestedAt: time(0)
    )

    var releaseCoordinator = MoriMotionCoordinator(catalog: catalog)
    let fallback = releaseCoordinator.send(.request(polarRequest), now: time(0))
    #expect(fallback.presentation?.motionID == .idleNeutral)
    #expect(fallback.presentation?.characterID == "penguin")

    var futureCoordinator = MoriMotionCoordinator(
      catalog: catalog,
      enabledCharacterIDs: ["penguin", "polar_bear"]
    )
    let enabled = futureCoordinator.send(.request(polarRequest), now: time(0))
    #expect(enabled.presentation?.motionID == "walk")
    #expect(enabled.presentation?.characterID == "polar_bear")
  }

  @Test("active and queued requests expire instead of replaying stale work")
  func expiry() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    _ = coordinator.send(
      .request(
        request(
          "story_reaction",
          identity: "expiring",
          at: time(0),
          deadline: time(2)
        )
      ),
      now: time(0)
    )
    _ = coordinator.send(
      .request(
        request(
          "walk",
          identity: "queued-expiring",
          at: time(1),
          deadline: time(2)
        )
      ),
      now: time(1)
    )

    let effects = coordinator.send(.tick, now: time(2))
    #expect(
      effects.contains {
        $0 == .cancel(requestIdentity: "expiring", reason: .expired)
      }
    )
    #expect(coordinator.state.queued.isEmpty)
    #expect(coordinator.state.active?.resolved.motionID == .idleNeutral)
  }

  @Test("an already stale request is discarded without replacing visible feedback")
  func staleSubmissionIsDiscarded() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    let stale = request(
      "story_reaction",
      identity: "already-stale",
      at: time(0),
      deadline: time(1)
    )

    #expect(coordinator.send(.request(stale), now: time(2)).isEmpty)
    #expect(coordinator.state.active == nil)
  }

  @Test("background clears playback and foreground starts the selected idle")
  func foregroundLifecycle() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(
      catalog: catalog,
      enabledCharacterIDs: ["penguin", "polar_bear"]
    )
    _ = coordinator.send(
      .request(
        MoriMotionRequest(
          motionID: "idle_resting",
          identity: "idle-choice",
          characterID: "polar_bear",
          surface: "phone.mori",
          requestedAt: time(0),
          reduceMotion: true
        )
      ),
      now: time(0)
    )
    _ = coordinator.send(
      .request(
        MoriMotionRequest(
          motionID: "story_reaction",
          identity: "event",
          characterID: "polar_bear",
          surface: "phone.mori",
          requestedAt: time(1),
          reduceMotion: true
        )
      ),
      now: time(1)
    )

    let background = coordinator.send(.setForeground(false), now: time(2))
    #expect(!coordinator.state.isForeground)
    #expect(coordinator.state.active == nil)
    #expect(coordinator.state.queued.isEmpty)
    #expect(
      background == [.cancel(requestIdentity: "event", reason: .background)]
    )

    let foreground = coordinator.send(.setForeground(true), now: time(3))
    #expect(coordinator.state.active?.resolved.motionID == .idleResting)
    #expect(coordinator.state.active?.request.characterID == "polar_bear")
    #expect(coordinator.state.active?.request.surface == "phone.mori")
    #expect(coordinator.state.active?.request.reduceMotion == true)
    #expect(foreground.count == 1)
  }

  @Test("requests received in background cannot replay after foreground return")
  func backgroundRequestIdentityIsConsumed() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    _ = coordinator.send(.setForeground(false), now: time(0))
    let request = request("story_reaction", identity: "stale-event", at: time(1))
    #expect(coordinator.send(.request(request), now: time(1)).isEmpty)
    _ = coordinator.send(.setForeground(true), now: time(2))

    #expect(coordinator.send(.request(request), now: time(3)).isEmpty)
    #expect(coordinator.state.active?.resolved.motionID == .idleNeutral)
  }

  @Test("Reduce Motion uses one reviewed keyframe and the catalog cross-fade")
  func reduceMotion() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    let effects = coordinator.send(
      .request(
        request(
          "story_reaction",
          identity: "reduced",
          at: time(0),
          reduceMotion: true
        )
      ),
      now: time(0)
    )

    let presentation = effects.presentation
    #expect(presentation?.frameNames == ["character_penguin_story_reaction_04"])
    #expect(
      presentation?.renderingMode
        == .staticKeyframe(frameIndex: 4, fadeMilliseconds: 150)
    )
    #expect(presentation?.voiceOverKey == "motion.story_reaction.voice_over")
    #expect(presentation?.visibleAlternateKey == "motion.story_reaction.visible")
  }

  @Test("unknown, malformed, unsupported, and missing assets resolve to neutral idle")
  func invalidRequestsFallback() throws {
    let catalog = TestCatalog.make()
    let incompleteWalkAssets = Set(
      try catalog.frameNames(characterID: "penguin", motionID: "walk").dropLast()
    )
    let neutralAssets = Set(
      try catalog.frameNames(characterID: "penguin", motionID: .idleNeutral)
    )
    let invalidRequests: [(MoriMotionRequest, MoriAssetInventory)] = [
      (request("not_known", identity: "unknown", at: time(0)), .unchecked),
      (
        MoriMotionRequest(
          motionID: "walk",
          identity: "",
          characterID: "penguin",
          surface: "watch.home",
          requestedAt: time(0)
        ),
        .unchecked
      ),
      (
        MoriMotionRequest(
          motionID: "walk",
          identity: "bad-character",
          characterID: "rabbit",
          surface: "watch.home",
          requestedAt: time(0)
        ),
        .unchecked
      ),
      (
        MoriMotionRequest(
          motionID: "walk",
          identity: "bad-surface",
          characterID: "penguin",
          surface: "phone.chat",
          requestedAt: time(0)
        ),
        .unchecked
      ),
      (
        request("walk", identity: "missing-frame", at: time(0)),
        .available(incompleteWalkAssets.union(neutralAssets))
      ),
    ]

    for (request, assets) in invalidRequests {
      var coordinator = MoriMotionCoordinator(catalog: catalog, assets: assets)
      let effects = coordinator.send(.request(request), now: time(0))
      #expect(coordinator.state.active?.resolved.motionID == .idleNeutral)
      #expect(effects.presentation?.motionID == .idleNeutral)
      #expect(effects.hapticCount == 0)
    }
  }

  @Test("missing neutral assets stop fallback instead of entering a transition loop")
  func missingFallbackAssetsStop() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(
      catalog: catalog,
      assets: .available([])
    )

    #expect(
      coordinator.send(
        .request(request("walk", identity: "missing-everything", at: time(0))),
        now: time(0)
      ).isEmpty
    )
    #expect(coordinator.state.active == nil)
  }

  @Test("late renderer asset failure cancels once and transitions to neutral")
  func asynchronousAssetFailure() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    _ = coordinator.send(
      .request(request("walk", identity: "walk", at: time(0))),
      now: time(0)
    )

    let effects = coordinator.send(
      .assetUnavailable(requestIdentity: "walk"),
      now: time(1)
    )
    #expect(
      effects.first == .cancel(requestIdentity: "walk", reason: .missingAsset)
    )
    #expect(effects.presentation?.motionID == .idleNeutral)
  }

  @Test("asset failure settles queued work before idle fallback")
  func assetFailureActivatesQueuedMotion() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    _ = coordinator.send(
      .request(request("story_reaction", identity: "event", at: time(0))),
      now: time(0)
    )
    _ = coordinator.send(
      .request(request("walk", identity: "walk", at: time(1))),
      now: time(1)
    )

    let effects = coordinator.send(
      .assetUnavailable(requestIdentity: "event"),
      now: time(2)
    )

    #expect(
      effects.first == .cancel(requestIdentity: "event", reason: .missingAsset)
    )
    #expect(effects.presentation?.motionID == "walk")
    #expect(coordinator.state.active?.request.identity == "walk")
    #expect(coordinator.state.queued.isEmpty)
  }

  @Test("a missing neutral frame cancels neutral without transitioning to neutral again")
  func neutralAssetFailureStops() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    _ = coordinator.send(
      .request(request("not_known", identity: "fallback", at: time(0))),
      now: time(0)
    )

    let effects = coordinator.send(
      .assetUnavailable(requestIdentity: "fallback"),
      now: time(1)
    )
    #expect(
      effects == [.cancel(requestIdentity: "fallback", reason: .missingAsset)]
    )
    #expect(coordinator.state.active == nil)
  }

  @Test("hatch row aliases remain asset references and cannot become runtime loops")
  func hatchAliasCannotPlay() {
    let catalog = TestCatalog.make(
      aliases: [TestCatalog.hatchAlias("greeting", row: "waving")]
    )
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    let effects = coordinator.send(
      .request(request("greeting", identity: "greeting", at: time(0))),
      now: time(0)
    )

    #expect(effects.presentation?.motionID == .idleNeutral)
    #expect(effects.presentation?.requestedMotionID == .idleNeutral)
    #expect(coordinator.state.active?.request.motionID == .idleNeutral)
    #expect(coordinator.state.currentIdle == .idleNeutral)
    #expect(coordinator.state.active?.resolved.resolutionKind == .motion)
  }

  @Test("each accepted request emits at most one haptic even after queued activation")
  func queuedHapticOnce() {
    let catalog = TestCatalog.make()
    var coordinator = MoriMotionCoordinator(catalog: catalog)
    _ = coordinator.send(
      .request(request("story_reaction", identity: "event", at: time(0))),
      now: time(0)
    )
    let queued = coordinator.send(
      .request(request("action_success", identity: "success", at: time(1))),
      now: time(1)
    )
    #expect(queued.hapticCount == 0)

    let activated = coordinator.send(
      .playbackCompleted(requestIdentity: "event"),
      now: time(2)
    )
    let duplicate = coordinator.send(
      .request(request("action_success", identity: "success", at: time(3))),
      now: time(3)
    )
    #expect(activated.hapticCount == 1)
    #expect(duplicate.hapticCount == 0)
  }

  private func request(
    _ motionID: MoriMotionID,
    identity: String,
    at: Date,
    reduceMotion: Bool = false,
    deadline: Date? = nil
  ) -> MoriMotionRequest {
    MoriMotionRequest(
      motionID: motionID,
      identity: identity,
      characterID: "penguin",
      surface: "watch.home",
      requestedAt: at,
      reduceMotion: reduceMotion,
      completionDeadline: deadline
    )
  }

  private func time(_ offset: Double) -> Date {
    epoch.addingTimeInterval(offset)
  }
}

extension Array where Element == MoriMotionEffect {
  fileprivate var hapticCount: Int {
    count { if case .haptic = $0 { true } else { false } }
  }

  fileprivate var presentation: MoriMotionPresentation? {
    compactMap {
      if case .transition(let presentation) = $0 { presentation } else { nil }
    }.last
  }
}
