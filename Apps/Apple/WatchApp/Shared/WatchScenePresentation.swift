import AppRuntime
import Domain
import Foundation

enum WatchCharacterAnimation: String, CaseIterable {
  case idleNeutral = "idle_neutral"
  case idleResting = "idle_resting"
  case idleCurious = "idle_curious"
  case idleLively = "idle_lively"
  case touchHead = "touch_head"
  case touchBody = "touch_body"
  case actionSuccess = "action_success"
  case storyReaction = "story_reaction"
  case socialLeap = "social_leap"

  var reduceMotionFrameIndex: Int {
    switch self {
    case .touchHead, .touchBody: 1
    case .actionSuccess, .storyReaction: 2
    case .socialLeap: 7
    case .idleNeutral, .idleResting, .idleCurious, .idleLively: 0
    }
  }

  var isOneShot: Bool {
    self == .actionSuccess || self == .storyReaction || self == .socialLeap
  }
}

struct WatchSceneReaction: Equatable {
  let sequence: Int
  let animation: WatchCharacterAnimation
}

enum WatchCharacterSlotPlacement: String, Hashable {
  case soloCenter
  case duoLeft
  case duoRight

  var normalizedX: Double {
    switch self {
    case .soloCenter: 0.5
    case .duoLeft: 0.32
    case .duoRight: 0.68
    }
  }

  var normalizedFootY: Double {
    switch self {
    case .soloCenter: 0.78
    case .duoLeft, .duoRight: 0.79
    }
  }

  var scale: Double {
    switch self {
    case .soloCenter: 1
    case .duoLeft, .duoRight: 0.76
    }
  }

  var zIndex: Double {
    switch self {
    case .soloCenter, .duoLeft: 10
    case .duoRight: 11
    }
  }

  var defaultLayout: WatchCharacterSlotLayout {
    WatchCharacterSlotLayout(
      normalizedX: normalizedX,
      normalizedFootY: normalizedFootY,
      scale: scale,
      zIndex: zIndex,
      facing: facing
    )
  }

  private var facing: WatchCharacterFacing {
    switch self {
    case .soloCenter: .front
    case .duoLeft: .screenRight
    case .duoRight: .screenLeft
    }
  }
}

enum WatchCharacterFacing: String {
  case front
  case screenLeft
  case screenRight
}

struct WatchCharacterSlotLayout {
  let normalizedX: Double
  let normalizedFootY: Double
  let scale: Double
  let zIndex: Double
  let facing: WatchCharacterFacing
}

struct WatchCharacterSlotPresentation: Identifiable {
  let id: String
  let characterID: String
  let placement: WatchCharacterSlotPlacement
  let layout: WatchCharacterSlotLayout
  let idleAnimation: WatchCharacterAnimation
}

struct WatchScenePresentation {
  static let frameCount = 8
  static let framesPerSecond = 6.0

  let backgroundID: String
  let backgroundDisplayName: String
  let accessibilityDescription: String
  let foregroundAssetName: String?
  let slots: [WatchCharacterSlotPresentation]

  static func make(
    peerValues: [String: String]?,
    mood: PetMood,
    allowsDuo: Bool = false
  ) -> Self {
    let backgroundID = CompanionVisualCatalog.normalizedBackgroundID(
      peerValues?["background"] ?? CompanionVisualCatalog.defaultBackgroundID
    )
    let requestedCharacterIDs = CompanionVisualCatalog.normalizedCharacterIDs(
      peerValues?["characters"]?
        .split(separator: ",")
        .map(String.init) ?? [CompanionVisualCatalog.defaultCharacterID]
    )
    let visibleCharacterIDs = Array(
      requestedCharacterIDs.prefix(allowsDuo ? CompanionVisualCatalog.maximumCharacterCount : 1)
    )
    let placements: [WatchCharacterSlotPlacement] =
      visibleCharacterIDs.count == 2 ? [.duoLeft, .duoRight] : [.soloCenter]
    let sceneDefinition = definition(for: backgroundID)
    return WatchScenePresentation(
      backgroundID: backgroundID,
      backgroundDisplayName: sceneDefinition.displayName,
      accessibilityDescription: sceneDefinition.accessibilityDescription,
      foregroundAssetName: sceneDefinition.foregroundAssetName,
      slots: zip(visibleCharacterIDs, placements).map { characterID, placement in
        WatchCharacterSlotPresentation(
          id: "\(placement.rawValue)-\(characterID)",
          characterID: characterID,
          placement: placement,
          layout: sceneDefinition.slotOverrides[placement] ?? placement.defaultLayout,
          idleAnimation: idleAnimation(for: mood)
        )
      }
    )
  }

  func backgroundAssetName(for width: Double) -> String {
    "scene_\(backgroundID)_\(width <= 198 ? "small" : "large")"
  }

  func frameAssetName(
    characterID: String,
    animation: WatchCharacterAnimation,
    index: Int
  ) -> String {
    let boundedIndex = ((index % Self.frameCount) + Self.frameCount) % Self.frameCount
    return "character_\(characterID)_\(animation.rawValue)_\(String(format: "%02d", boundedIndex))"
  }

  func applying(mood: PetMood) -> Self {
    WatchScenePresentation(
      backgroundID: backgroundID,
      backgroundDisplayName: backgroundDisplayName,
      accessibilityDescription: accessibilityDescription,
      foregroundAssetName: foregroundAssetName,
      slots: slots.map { slot in
        WatchCharacterSlotPresentation(
          id: slot.id,
          characterID: slot.characterID,
          placement: slot.placement,
          layout: slot.layout,
          idleAnimation: Self.idleAnimation(for: mood)
        )
      }
    )
  }

  func applying(backgroundID requestedID: String) -> Self {
    let backgroundID = CompanionVisualCatalog.normalizedBackgroundID(requestedID)
    let sceneDefinition = Self.definition(for: backgroundID)
    return WatchScenePresentation(
      backgroundID: backgroundID,
      backgroundDisplayName: sceneDefinition.displayName,
      accessibilityDescription: sceneDefinition.accessibilityDescription,
      foregroundAssetName: sceneDefinition.foregroundAssetName,
      slots: slots.map { slot in
        WatchCharacterSlotPresentation(
          id: slot.id,
          characterID: slot.characterID,
          placement: slot.placement,
          layout: sceneDefinition.slotOverrides[slot.placement] ?? slot.placement.defaultLayout,
          idleAnimation: slot.idleAnimation
        )
      }
    )
  }

  private static func idleAnimation(for mood: PetMood) -> WatchCharacterAnimation {
    switch mood {
    case .neutral: .idleNeutral
    case .resting: .idleResting
    case .curious: .idleCurious
    case .lively: .idleLively
    }
  }

  private static func definition(for id: String) -> WatchSceneDefinition {
    let scenes: [String: (String, String)] = [
      "ice_ocean_day": ("冰海白昼", "明亮冰海、远处冰山和开阔雪地"),
      "spring_meadow_stream": ("春日花溪", "春日花草、小溪和远处缓坡"),
      "rainy_cabin_dusk": ("雨夜木屋", "黄昏雨幕外的木屋和温暖灯光"),
      "moonlit_forest_camp": ("月光森林营地", "月光、松林、萤火虫和安静营地"),
      "snow_birch_sunrise": ("雪林日出", "粉金色日出照亮白桦与雪地"),
      "summer_lake": ("夏日湖畔", "晴朗夏日的湖面、芦苇和远山"),
      "rainy_reading_room": ("雨日阅读室", "雨窗、书架、植物和暖灯组成的阅读角"),
      "aurora_observatory": ("极光观星台", "极光、星空、远山和山顶观测平台"),
      "sunset_coast": ("黄昏海岸", "桃紫色晚霞、平静海面和开阔海岸"),
      "lantern_festival_square": ("灯火节日广场", "暖色灯笼围绕夜晚的石质小广场"),
    ]
    let scene = scenes[id] ?? ("共享场景", "伙伴共享场景")
    return WatchSceneDefinition(
      displayName: scene.0,
      accessibilityDescription: scene.1,
      foregroundAssetName: nil,
      slotOverrides: [:]
    )
  }
}

private struct WatchSceneDefinition {
  let displayName: String
  let accessibilityDescription: String
  let foregroundAssetName: String?
  let slotOverrides: [WatchCharacterSlotPlacement: WatchCharacterSlotLayout]
}
