import AppRuntime
import SwiftUI
import WatchKit

struct CompanionSceneView: View {
  let scene: WatchScenePresentation
  var reaction: WatchSceneReaction?
  var usesStaticArtwork = false
  var cornerRadius: CGFloat = 22
  var showsTouchHint = true
  var sceneAccessibilityIdentifier = "watch.companion-scene"
  var onLongPress: () -> Void = {}
  var onInteraction: (WatchCharacterAnimation) -> Void = { _ in }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var transientAnimation: WatchCharacterAnimation?
  @State private var transientStartedAt: Date?
  @State private var transientToken = 0
  @State private var lastInteractionAt = Date.distantPast

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Image(scene.backgroundAssetName(for: geometry.size.width))
          .resizable()
          .interpolation(.none)
          .scaledToFill()
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipped()
          .id(scene.backgroundID)
          .transition(.opacity)
          .accessibilityHidden(true)

        ForEach(scene.slots) { slot in
          animatedCharacter(slot: slot, size: geometry.size)
            .zIndex(slot.layout.zIndex)
        }

        if let foregroundAssetName = scene.foregroundAssetName {
          Image(foregroundAssetName)
            .resizable()
            .interpolation(.none)
            .scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(100)
        }
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: scene.backgroundID)
      .contentShape(Rectangle())
      .gesture(
        LongPressGesture(minimumDuration: 0.55)
          .exclusively(before: SpatialTapGesture())
          .onEnded { value in
            switch value {
            case .first:
              onLongPress()
            case .second(let tap):
              guard let animation = interaction(at: tap.location, in: geometry.size) else {
                return
              }
              respondToTouch(animation)
            }
          }
      )
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay(alignment: .topTrailing) {
      if showsTouchHint {
        Image(systemName: "hand.tap.fill")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.white.opacity(0.9))
          .padding(8)
          .background(.black.opacity(0.28), in: Circle())
          .padding(8)
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("互动伙伴场景，\(scene.accessibilityDescription)")
    .accessibilityValue(
      "\(scene.slots.map(characterDisplayName).joined(separator: "、"))，\(scene.backgroundDisplayName)"
    )
    .accessibilityHint("轻点 Mori 会得到回应；长按打开功能菜单")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      respondToTouch(.touchBody)
    }
    .accessibilityAction(named: Text("打开功能菜单")) {
      onLongPress()
    }
    .accessibilityIdentifier(sceneAccessibilityIdentifier)
    .onChange(of: reaction) { _, value in
      guard let value else { return }
      play(value.animation, recordsInteraction: false)
    }
  }

  @ViewBuilder
  private func animatedCharacter(
    slot: WatchCharacterSlotPresentation,
    size: CGSize
  ) -> some View {
    let animation = transientAnimation ?? slot.idleAnimation
    let characterSize = characterSize(for: slot, in: size)
    if usesStaticArtwork || reduceMotion {
      characterFrame(
        slot: slot,
        animation: animation,
        frameIndex: animation.reduceMotionFrameIndex,
        characterSize: characterSize,
        sceneSize: size
      )
    } else {
      TimelineView(.animation(minimumInterval: 1 / WatchScenePresentation.framesPerSecond)) {
        context in
        characterFrame(
          slot: slot,
          animation: animation,
          frameIndex: frameIndex(for: animation, at: context.date),
          characterSize: characterSize,
          sceneSize: size
        )
      }
    }
  }

  private func characterFrame(
    slot: WatchCharacterSlotPresentation,
    animation: WatchCharacterAnimation,
    frameIndex: Int,
    characterSize: CGSize,
    sceneSize: CGSize
  ) -> some View {
    Image(
      scene.frameAssetName(
        characterID: slot.characterID,
        animation: animation,
        index: frameIndex
      )
    )
    .resizable()
    .interpolation(.none)
    .scaledToFit()
    .frame(width: characterSize.width, height: characterSize.height)
    .scaleEffect(transientAnimation == .touchHead && !reduceMotion ? 1.04 : 1)
    .rotationEffect(.degrees(transientAnimation == .touchBody && !reduceMotion ? 2 : 0))
    .position(
      x: sceneSize.width * slot.layout.normalizedX,
      y: sceneSize.height * slot.layout.normalizedFootY
        - characterSize.height / 2
    )
    .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: transientAnimation)
  }

  private func interaction(at point: CGPoint, in size: CGSize) -> WatchCharacterAnimation? {
    for slot in scene.slots.sorted(by: { $0.layout.zIndex > $1.layout.zIndex }) {
      let slotSize = characterSize(for: slot, in: size)
      let center = CGPoint(
        x: size.width * slot.layout.normalizedX,
        y: size.height * slot.layout.normalizedFootY - slotSize.height / 2
      )
      let hitFrame = CGRect(
        x: center.x - slotSize.width / 2,
        y: center.y - slotSize.height / 2,
        width: slotSize.width,
        height: slotSize.height
      ).insetBy(dx: -4, dy: -4)
      guard hitFrame.contains(point) else { continue }
      return point.y < hitFrame.midY ? .touchHead : .touchBody
    }
    return nil
  }

  private func characterSize(
    for slot: WatchCharacterSlotPresentation,
    in size: CGSize
  ) -> CGSize {
    CGSize(
      width: min(size.width * 0.72, size.height * 0.61) * slot.layout.scale,
      height: min(size.width * 0.78, size.height * 0.66) * slot.layout.scale
    )
  }

  private func respondToTouch(_ animation: WatchCharacterAnimation) {
    let now = Date()
    guard now.timeIntervalSince(lastInteractionAt) >= 0.35 else { return }
    lastInteractionAt = now
    play(animation, recordsInteraction: true)
  }

  private func play(
    _ animation: WatchCharacterAnimation,
    recordsInteraction: Bool
  ) {
    transientToken += 1
    let token = transientToken
    transientAnimation = animation
    transientStartedAt = Date()
    switch animation {
    case .touchHead:
      WKInterfaceDevice.current().play(.click)
    case .touchBody:
      WKInterfaceDevice.current().play(.directionUp)
    case .actionSuccess, .socialLeap:
      WKInterfaceDevice.current().play(.success)
    case .storyReaction:
      WKInterfaceDevice.current().play(.notification)
    case .idleNeutral, .idleResting, .idleCurious, .idleLively:
      break
    }
    if recordsInteraction {
      onInteraction(animation)
    }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(850))
      guard token == transientToken else { return }
      transientAnimation = nil
      transientStartedAt = nil
    }
  }

  private func frameIndex(
    for animation: WatchCharacterAnimation,
    at date: Date
  ) -> Int {
    guard let transientStartedAt, transientAnimation != nil else {
      let tick = Int64(
        date.timeIntervalSinceReferenceDate * WatchScenePresentation.framesPerSecond
      )
      return Int(tick % Int64(WatchScenePresentation.frameCount))
    }
    let elapsed = max(0, date.timeIntervalSince(transientStartedAt))
    let index = Int(elapsed * WatchScenePresentation.framesPerSecond)
    return animation.isOneShot
      ? min(index, WatchScenePresentation.frameCount - 1)
      : index % WatchScenePresentation.frameCount
  }

  private func characterDisplayName(_ slot: WatchCharacterSlotPresentation) -> String {
    CompanionVisualCatalog.characterDisplayName(slot.characterID)
  }
}
