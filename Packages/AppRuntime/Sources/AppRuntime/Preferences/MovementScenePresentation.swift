import Domain
import Foundation

public enum MovementSceneMotion: String, CaseIterable, Equatable, Sendable {
  case sitDown = "sit_down"
  case walk
  case briskMove = "brisk_move"
  case catchBreath = "catch_breath"

  public var loopsWhileStateIsActive: Bool {
    switch self {
    case .walk, .briskMove:
      true
    case .sitDown, .catchBreath:
      false
    }
  }
}

public struct MovementScenePresentation: Equatable, Sendable {
  public let state: MovementSceneState
  public let backgroundID: String
  public let title: String
  public let detail: String
  public let systemImage: String
  public let petMood: PetMood
  public let petMotion: MovementSceneMotion

  public init(telemetry: MovementTelemetry) {
    state = MovementSceneState.classify(telemetry)
    detail = Self.detail(telemetry)
    switch state {
    case .stationary:
      backgroundID = "rainy_reading_room"
      title = "原地休息"
      systemImage = "pause.circle.fill"
      petMood = .resting
      petMotion = .sitDown
    case .walking:
      backgroundID = "spring_meadow_stream"
      title = "正在散步"
      systemImage = "figure.walk"
      petMood = .curious
      petMotion = .walk
    case .active:
      backgroundID = "summer_lake"
      title = "快速移动"
      systemImage = "figure.run"
      petMood = .lively
      petMotion = .briskMove
    case .recovering:
      backgroundID = "sunset_coast"
      title = "停下恢复"
      systemImage = "heart.circle.fill"
      petMood = .resting
      petMotion = .catchBreath
    }
  }

  private static func detail(_ telemetry: MovementTelemetry) -> String {
    let speed = telemetry.speedMetersPerSecond.formatted(
      .number.precision(.fractionLength(1))
    )
    let heartRate = Int(telemetry.heartRateBPM.rounded())
    return "GPS \(speed) m/s · 心率 \(heartRate)"
  }
}
