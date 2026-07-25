import AppRuntime
import SwiftUI
import UIKit

enum PhonePetInteraction: String, Equatable {
  case touchHead = "touch_head"
  case touchBody = "touch_body"

  var statusMessage: String {
    statusMessage(for: "Mori")
  }

  func statusMessage(for subjectName: String) -> String {
    switch self {
    case .touchHead: "\(subjectName) 开心地眨了眨眼"
    case .touchBody: "\(subjectName) 转过身回应了你"
    }
  }

  fileprivate func feedbackMessage(for subjectName: String) -> String {
    switch self {
    case .touchHead: "摸摸头 · \(subjectName) 眨了眨眼"
    case .touchBody: "碰一碰 · \(subjectName) 转身靠近"
    }
  }

  fileprivate var hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle {
    switch self {
    case .touchHead: .soft
    case .touchBody: .medium
    }
  }

  fileprivate var hapticIntensity: CGFloat {
    switch self {
    case .touchHead: 0.65
    case .touchBody: 0.8
    }
  }
}

struct PhoneCompanionSceneView: View {
  let characterID: String
  let backgroundID: String
  let onInteraction: (PhonePetInteraction) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var transientInteraction: PhonePetInteraction?
  @State private var transientStartedAt: Date?
  @State private var transientToken = 0
  @State private var lastInteractionAt = Date.distantPast

  private static let frameCount = 8
  private static let framesPerSecond = 6.0

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Image(backgroundAssetName)
          .resizable()
          .interpolation(.none)
          .scaledToFill()
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipped()
          .id(backgroundAssetName)
          .transition(.opacity)
          .accessibilityHidden(true)

        animatedCharacter(in: geometry.size)

        if let transientInteraction {
          Text(transientInteraction.feedbackMessage(for: interactionSubjectName))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.58), in: Capsule())
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
            .accessibilityIdentifier("phone.pet-interaction-feedback")
        }
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: backgroundAssetName)
      .contentShape(Rectangle())
      .gesture(
        SpatialTapGesture()
          .onEnded { value in
            guard let interaction = interaction(at: value.location, in: geometry.size) else {
              return
            }
            respond(to: interaction)
          }
      )
    }
    .aspectRatio(4 / 3, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(alignment: .topTrailing) {
      Label("摸摸 \(interactionSubjectName)", systemImage: "hand.tap.fill")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.black.opacity(0.42), in: Capsule())
        .padding(10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("可以互动的 \(interactionSubjectName)")
    .accessibilityValue("\(characterDisplayName)，\(backgroundDisplayName)")
    .accessibilityHint("双击会轻触身体；上下轻扫可选择摸摸头或轻触身体")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      respond(to: .touchBody)
    }
    .accessibilityAction(named: "摸摸头") {
      respond(to: .touchHead)
    }
    .accessibilityAction(named: "轻触身体") {
      respond(to: .touchBody)
    }
    .accessibilityIdentifier("phone.companion-interaction")
  }

  @ViewBuilder
  private func animatedCharacter(in size: CGSize) -> some View {
    let characterSize = characterSize(in: size)
    let interaction = transientInteraction
    if reduceMotion {
      characterFrame(
        assetName: frameAssetName(at: Date()),
        characterSize: characterSize,
        sceneSize: size,
        interaction: interaction
      )
    } else {
      TimelineView(.animation(minimumInterval: 1 / Self.framesPerSecond)) { context in
        characterFrame(
          assetName: frameAssetName(at: context.date),
          characterSize: characterSize,
          sceneSize: size,
          interaction: interaction
        )
      }
    }
  }

  private func characterFrame(
    assetName: String,
    characterSize: CGSize,
    sceneSize: CGSize,
    interaction: PhonePetInteraction?
  ) -> some View {
    Image(assetName)
      .resizable()
      .interpolation(.none)
      .scaledToFit()
      .frame(width: characterSize.width, height: characterSize.height)
      .scaleEffect(interaction == .touchHead && !reduceMotion ? 1.04 : 1)
      .rotationEffect(.degrees(interaction == .touchBody && !reduceMotion ? 2 : 0))
      .position(
        x: sceneSize.width * 0.5,
        y: sceneSize.height * 0.78 - characterSize.height / 2
      )
      .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: interaction)
      .accessibilityHidden(true)
  }

  private func interaction(at point: CGPoint, in size: CGSize) -> PhonePetInteraction? {
    let characterSize = characterSize(in: size)
    let center = CGPoint(
      x: size.width * 0.5,
      y: size.height * 0.78 - characterSize.height / 2
    )
    let hitFrame = CGRect(
      x: center.x - characterSize.width / 2,
      y: center.y - characterSize.height / 2,
      width: characterSize.width,
      height: characterSize.height
    ).insetBy(dx: -10, dy: -10)
    guard hitFrame.contains(point) else { return nil }
    return point.y < hitFrame.midY ? .touchHead : .touchBody
  }

  private func characterSize(in size: CGSize) -> CGSize {
    CGSize(
      width: min(size.width * 0.72, size.height * 0.68),
      height: min(size.width * 0.78, size.height * 0.74)
    )
  }

  private func respond(to interaction: PhonePetInteraction) {
    let now = Date()
    guard now.timeIntervalSince(lastInteractionAt) >= 0.35 else { return }
    lastInteractionAt = now
    transientToken += 1
    let token = transientToken

    withAnimation(reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.18)) {
      transientInteraction = interaction
      transientStartedAt = now
    }

    let haptic = UIImpactFeedbackGenerator(style: interaction.hapticStyle)
    haptic.prepare()
    haptic.impactOccurred(intensity: interaction.hapticIntensity)
    UIAccessibility.post(
      notification: .announcement,
      argument: interaction.statusMessage(for: interactionSubjectName)
    )
    onInteraction(interaction)

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1_350))
      guard token == transientToken else { return }
      withAnimation(reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.15)) {
        transientInteraction = nil
        transientStartedAt = nil
      }
    }
  }

  private func frameAssetName(at date: Date) -> String {
    let animation = transientInteraction?.rawValue ?? "idle_neutral"
    let index: Int
    if reduceMotion {
      index = transientInteraction == nil ? 0 : 1
    } else if let transientStartedAt, transientInteraction != nil {
      let elapsed = max(0, date.timeIntervalSince(transientStartedAt))
      index = min(Int(elapsed * Self.framesPerSecond), Self.frameCount - 1)
    } else {
      let tick = Int64(date.timeIntervalSinceReferenceDate * Self.framesPerSecond)
      index = Int(tick % Int64(Self.frameCount))
    }
    return "character_\(normalizedCharacterID)_\(animation)_\(String(format: "%02d", index))"
  }

  private var normalizedCharacterID: String {
    CompanionVisualCatalog.normalizedCharacterIDs([characterID]).first
      ?? CompanionVisualCatalog.defaultCharacterID
  }

  private var backgroundAssetName: String {
    "scene_\(normalizedBackgroundID)_large"
  }

  private var normalizedBackgroundID: String {
    CompanionVisualCatalog.normalizedBackgroundID(backgroundID)
  }

  private var characterDisplayName: String {
    CompanionVisualCatalog.characterDisplayName(normalizedCharacterID)
  }

  private var interactionSubjectName: String {
    switch normalizedCharacterID {
    case "bili_22", "bili_33": characterDisplayName
    default: "Mori"
    }
  }

  private var backgroundDisplayName: String {
    switch normalizedBackgroundID {
    case "spring_meadow_stream": "春日花溪"
    case "rainy_cabin_dusk": "雨夜木屋"
    case "moonlit_forest_camp": "月光森林营地"
    case "snow_birch_sunrise": "雪林日出"
    case "summer_lake": "夏日湖畔"
    case "rainy_reading_room": "雨日阅读室"
    case "aurora_observatory": "极光观星台"
    case "sunset_coast": "黄昏海岸"
    case "lantern_festival_square": "灯火节日广场"
    default: "冰海白昼"
    }
  }
}
