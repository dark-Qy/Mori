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
  let movementMotion: MovementSceneMotion?
  let onInteraction: (PhonePetInteraction) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var transientInteraction: PhonePetInteraction?
  @State private var transientStartedAt: Date?
  @State private var transientToken = 0
  @State private var sceneOneShotMotion: MovementSceneMotion?
  @State private var sceneOneShotStartedAt: Date?
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
    .accessibilityValue(
      [
        characterDisplayName,
        backgroundDisplayName,
        movementAccessibilityLabel,
      ]
      .compactMap(\.self)
      .joined(separator: "，")
    )
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
    .task(id: movementMotion) {
      sceneOneShotMotion = nil
      sceneOneShotStartedAt = nil
      guard let movementMotion, !movementMotion.loopsWhileStateIsActive else { return }
      sceneOneShotMotion = movementMotion
      sceneOneShotStartedAt = Date()
      try? await Task.sleep(
        for: .seconds(Double(Self.frameCount) / movementFramesPerSecond)
      )
      guard !Task.isCancelled, sceneOneShotMotion == movementMotion else { return }
      sceneOneShotMotion = nil
      sceneOneShotStartedAt = nil
    }
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
      TimelineView(.animation(minimumInterval: 1 / currentFramesPerSecond)) { context in
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
    let animation = currentMotionID
    let index: Int
    if reduceMotion {
      index = currentReduceMotionFrameIndex
    } else if let currentMotionStartedAt, currentMotionIsOneShot {
      let elapsed = max(0, date.timeIntervalSince(currentMotionStartedAt))
      index = min(Int(elapsed * currentFramesPerSecond), Self.frameCount - 1)
    } else {
      let tick = Int64(date.timeIntervalSinceReferenceDate * currentFramesPerSecond)
      index = Int(tick % Int64(Self.frameCount))
    }
    return "character_\(normalizedCharacterID)_\(animation)_\(String(format: "%02d", index))"
  }

  private var currentMotionID: String {
    if let transientInteraction {
      return transientInteraction.rawValue
    }
    if let currentMovementMotion {
      return currentMovementMotion.rawValue
    }
    return movementMotion == nil ? "idle_neutral" : "idle_resting"
  }

  private var currentMovementMotion: MovementSceneMotion? {
    guard transientInteraction == nil else { return nil }
    if let sceneOneShotMotion {
      return sceneOneShotMotion
    }
    guard let movementMotion, movementMotion.loopsWhileStateIsActive else { return nil }
    return movementMotion
  }

  private var currentMotionStartedAt: Date? {
    if transientInteraction != nil {
      return transientStartedAt
    }
    return sceneOneShotMotion == nil ? nil : sceneOneShotStartedAt
  }

  private var currentMotionIsOneShot: Bool {
    transientInteraction != nil || sceneOneShotMotion != nil
  }

  private var currentFramesPerSecond: Double {
    currentMovementMotion == nil ? Self.framesPerSecond : movementFramesPerSecond
  }

  private var currentReduceMotionFrameIndex: Int {
    if transientInteraction != nil {
      return 1
    }
    if let currentMovementMotion {
      return reduceMotionFrameIndex(for: currentMovementMotion)
    }
    return 0
  }

  private func reduceMotionFrameIndex(
    for motion: MovementSceneMotion
  ) -> Int {
    switch motion {
    case .sitDown: 7
    case .walk: 1
    case .briskMove: 3
    case .catchBreath: 4
    }
  }

  private var movementFramesPerSecond: Double { 10 }

  private var movementAccessibilityLabel: String? {
    switch movementMotion {
    case .sitDown: "坐下休息"
    case .walk: "散步"
    case .briskMove: "快速移动"
    case .catchBreath: "调整呼吸"
    case nil: nil
    }
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
    CompanionVisualCatalog.backgroundDisplayName(normalizedBackgroundID)
  }
}
