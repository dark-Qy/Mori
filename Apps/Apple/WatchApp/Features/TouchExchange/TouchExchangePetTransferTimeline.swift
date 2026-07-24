import AppRuntime
import Foundation

enum TouchExchangeTransferPlaybackPhase: String, Equatable {
  case scheduled
  case travelling
  case landed
}

struct TouchExchangeTransferFrame: Equatable {
  let phase: TouchExchangeTransferPlaybackPhase
  let progress: Double
  let frameIndex: Int
  let movingCharacterNormalizedX: Double
  let movingCharacterOpacity: Double
}

struct TouchExchangeTransferPresentation: Equatable {
  let eventID: String
  let role: PetTransferAnimationRole
  let scheduledStartsAt: Date
  let playbackStartsAt: Date
  let duration: TimeInterval
  let movingCharacterID: String
  let localCharacterID: String
  let backgroundID: String
  let isLateFallback: Bool

  var accessibilityRole: String {
    role == .source ? "source" : "destination"
  }

  func frame(at date: Date, reduceMotion: Bool) -> TouchExchangeTransferFrame {
    let rawProgress = date.timeIntervalSince(playbackStartsAt) / duration
    let progress = min(1, max(0, rawProgress))
    let phase: TouchExchangeTransferPlaybackPhase =
      rawProgress < 0 ? .scheduled : (rawProgress < 1 ? .travelling : .landed)
    let frameIndex = reduceMotion ? 7 : min(7, max(0, Int(progress * 8)))

    if reduceMotion {
      return TouchExchangeTransferFrame(
        phase: phase,
        progress: progress,
        frameIndex: frameIndex,
        movingCharacterNormalizedX: role == .source ? 0.5 : 0.32,
        movingCharacterOpacity: role == .source ? 1 - progress : progress
      )
    }

    // One shared global path covers two adjacent unit-width Watch screens.
    // Watch A spans 0...1 and Watch B spans 1...2. The source starts at
    // global x=0.5 and the destination landing slot is global x=1.32.
    let globalX = 0.5 + (0.82 * eased(progress))
    return TouchExchangeTransferFrame(
      phase: phase,
      progress: progress,
      frameIndex: frameIndex,
      movingCharacterNormalizedX: role == .source ? globalX : globalX - 1,
      movingCharacterOpacity: 1
    )
  }

  static func make(
    cue: PetTransferAnimationCue,
    localCharacterID: String,
    peerCharacterID: String,
    backgroundID: String,
    receivedAt: Date
  ) -> Self? {
    guard cue.isSupported else { return nil }
    let serverDuration = TimeInterval(cue.durationMilliseconds) / 1_000
    let scheduledEnd = cue.startsAt.addingTimeInterval(serverDuration)
    let isLate = receivedAt >= scheduledEnd
    return TouchExchangeTransferPresentation(
      eventID: cue.eventID,
      role: cue.role,
      scheduledStartsAt: cue.startsAt,
      playbackStartsAt: isLate ? receivedAt : cue.startsAt,
      duration: isLate ? 0.35 : serverDuration,
      movingCharacterID: normalizedCharacterID(
        cue.role == .source ? localCharacterID : peerCharacterID
      ),
      localCharacterID: normalizedCharacterID(localCharacterID),
      backgroundID: normalizedBackgroundID(backgroundID),
      isLateFallback: isLate
    )
  }

  private func eased(_ value: Double) -> Double {
    value < 0.5
      ? 4 * value * value * value
      : 1 - pow(-2 * value + 2, 3) / 2
  }

  private static func normalizedCharacterID(_ value: String) -> String {
    CompanionVisualCatalog.normalizedCharacterIDs([value]).first
      ?? CompanionVisualCatalog.defaultCharacterID
  }

  private static func normalizedBackgroundID(_ value: String) -> String {
    CompanionVisualCatalog.normalizedBackgroundID(value)
  }
}
