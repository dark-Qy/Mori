import Domain
import Foundation

public struct MovementScenePresentation: Equatable, Sendable {
  public let state: MovementSceneState
  public let backgroundID: String
  public let title: String
  public let detail: String
  public let systemImage: String
  public let petMood: PetMood

  public init(telemetry: MovementTelemetry) {
    state = MovementSceneState.classify(telemetry)
    detail = Self.detail(telemetry)
    switch state {
    case .stationary:
      backgroundID = "rainy_reading_room"
      title = "原地休息"
      systemImage = "pause.circle.fill"
      petMood = .resting
    case .walking:
      backgroundID = "spring_meadow_stream"
      title = "正在散步"
      systemImage = "figure.walk"
      petMood = .curious
    case .active:
      backgroundID = "summer_lake"
      title = "快速移动"
      systemImage = "figure.run"
      petMood = .lively
    case .recovering:
      backgroundID = "sunset_coast"
      title = "停下恢复"
      systemImage = "heart.circle.fill"
      petMood = .resting
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
