import AppRuntime
import SwiftUI
import WatchKit

struct TouchExchangePetTransferView: View {
  let presentation: TouchExchangeTransferPresentation

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hapticEventID: String?

  var body: some View {
    GeometryReader { geometry in
      TimelineView(.animation(minimumInterval: 1 / 30)) { context in
        let frame = presentation.frame(
          at: context.date,
          reduceMotion: reduceMotion
        )
        ZStack {
          Image(backgroundAssetName(width: geometry.size.width))
            .resizable()
            .interpolation(.none)
            .scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()

          if presentation.role == .destination {
            character(
              id: presentation.localCharacterID,
              animation: "idle_neutral",
              frameIndex: idleFrameIndex(at: context.date),
              width: geometry.size.width * 0.43
            )
            .position(
              x: geometry.size.width * 0.68,
              y: geometry.size.height * 0.67
            )
          }

          character(
            id: presentation.movingCharacterID,
            animation: "social_leap",
            frameIndex: frame.frameIndex,
            width: geometry.size.width * 0.5
          )
          .opacity(frame.movingCharacterOpacity)
          .position(
            x: geometry.size.width * frame.movingCharacterNormalizedX,
            y: geometry.size.height * 0.66
          )

          if frame.phase == .landed, presentation.role == .destination {
            Circle()
              .stroke(AdventurePalette.mint.opacity(0.7), lineWidth: 2)
              .frame(width: 32, height: 10)
              .scaleEffect(frame.progress)
              .position(
                x: geometry.size.width * 0.32,
                y: geometry.size.height * 0.86
              )
              .accessibilityHidden(true)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          presentation.role == .source
            ? "Mori 正在跳到对方手表"
            : "对方的 Mori 正在跳进这块手表"
        )
        .accessibilityValue(
          "event:\(presentation.eventID)|\(presentation.accessibilityRole)"
            + "|\(frame.phase.rawValue)|\(presentation.movingCharacterID)"
            + "|frame:\(frame.frameIndex)|late:\(presentation.isLateFallback)"
        )
        .accessibilityIdentifier(
          "watch.touch-exchange.transfer.\(presentation.accessibilityRole)"
        )
      }
    }
    .frame(height: 138)
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(AdventurePalette.blue.opacity(0.35), lineWidth: 1)
    )
    .accessibilityIdentifier(
      "watch.touch-exchange.transfer.\(presentation.accessibilityRole)"
    )
    .task(id: presentation.eventID) {
      let delay = max(0, presentation.playbackStartsAt.timeIntervalSinceNow)
      if delay > 0 {
        try? await Task.sleep(for: .seconds(delay))
      }
      guard !Task.isCancelled, hapticEventID != presentation.eventID else { return }
      hapticEventID = presentation.eventID
      WKInterfaceDevice.current().play(.success)
    }
  }

  private func character(
    id: String,
    animation: String,
    frameIndex: Int,
    width: Double
  ) -> some View {
    Image(
      "character_\(id)_\(animation)_\(String(format: "%02d", frameIndex))"
    )
    .resizable()
    .interpolation(.none)
    .scaledToFit()
    .frame(width: width, height: width * 1.08)
    .accessibilityHidden(true)
  }

  private func backgroundAssetName(width: Double) -> String {
    "scene_\(presentation.backgroundID)_\(width <= 198 ? "small" : "large")"
  }

  private func idleFrameIndex(at date: Date) -> Int {
    Int(date.timeIntervalSinceReferenceDate * 10) % 8
  }
}
