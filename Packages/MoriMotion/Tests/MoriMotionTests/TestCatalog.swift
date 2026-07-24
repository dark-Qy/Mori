import Foundation

@testable import MoriMotion

enum TestCatalog {
  static func make(aliases: [MoriMotionAlias] = []) -> MoriMotionCatalog {
    let base = MoriMotionCatalog.emergencyFallback
    return MoriMotionCatalog(
      schemaVersion: base.schemaVersion,
      status: .ready,
      characterIDs: ["penguin", "polar_bear"],
      fallbackMotionID: base.fallbackMotionID,
      assetKeyTemplate: base.assetKeyTemplate,
      cell: base.cell,
      layoutPresets: base.layoutPresets,
      defaults: base.defaults,
      priorityClasses: base.priorityClasses,
      motions: [
        motion("idle_neutral", priority: .idle, playback: .loop, returnPolicy: .remain),
        motion("idle_resting", priority: .idle, playback: .loop, returnPolicy: .remain),
        motion("idle_curious", priority: .attention, playback: .loop),
        motion("walk", priority: .companion, playback: .loop, cooldown: 0),
        motion("speaking", priority: .conversation, playback: .loop),
        motion(
          "action_success",
          priority: .conversation,
          haptic: .success,
          reduceMotionFrame: 5
        ),
        motion("story_reaction", priority: .event, reduceMotionFrame: 4),
        motion(
          "touch_head",
          priority: .touch,
          cooldown: 350,
          haptic: .click,
          reduceMotionFrame: 3
        ),
      ],
      aliases: aliases,
      poses: [],
      policies: [],
      forbiddenMappings: []
    )
  }

  static func alias(_ id: MoriMotionID, target: String) -> MoriMotionAlias {
    MoriMotionAlias(
      id: id,
      target: MoriAliasTarget(kind: .motion, id: target)
    )
  }

  static func hatchAlias(_ id: MoriMotionID, row: String) -> MoriMotionAlias {
    MoriMotionAlias(
      id: id,
      target: MoriAliasTarget(kind: .hatchV2Row, id: row)
    )
  }

  private static func motion(
    _ id: MoriMotionID,
    priority: MoriPriorityClass,
    playback: MoriPlayback = .oneShot,
    returnPolicy: MoriReturnPolicy = .currentIdle,
    cooldown: Int = 0,
    haptic: MoriHaptic = .none,
    reduceMotionFrame: Int = 2
  ) -> MoriMotionDefinition {
    MoriMotionDefinition(
      id: id,
      productionForm: .unique,
      authoringStatus: .ready,
      source: MoriMotionSource(kind: .productClip, id: id.rawValue),
      playback: playback,
      priorityClass: priority,
      triggers: ["test.\(id.rawValue)"],
      surfaces: ["watch.home", "phone.mori"],
      returnPolicy: returnPolicy,
      cooldownMilliseconds: cooldown,
      replacementPolicy: priority == .touch ? .restartNewest : .newestSameKind,
      haptic: haptic,
      hitTest: priority == .touch ? .head : .none,
      reduceMotionFrame: reduceMotionFrame,
      voiceOverKey: "motion.\(id.rawValue).voice_over",
      visibleAlternateKey: "motion.\(id.rawValue).visible",
      watchAllowed: true,
      apparelOcclusion: .compatible
    )
  }
}
