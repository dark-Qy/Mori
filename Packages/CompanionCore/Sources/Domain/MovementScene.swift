import Foundation

/// A privacy-minimized movement sample used to choose presentation state.
///
/// Raw coordinates stay at the capability boundary. Scene rules only need GPS-derived speed and
/// the latest heart-rate value.
public struct MovementTelemetry: Equatable, Sendable {
  public let speedMetersPerSecond: Double
  public let heartRateBPM: Double

  public init(speedMetersPerSecond: Double, heartRateBPM: Double) {
    self.speedMetersPerSecond = max(0, speedMetersPerSecond)
    self.heartRateBPM = max(0, heartRateBPM)
  }
}

public enum MovementSceneState: String, CaseIterable, Equatable, Sendable {
  case stationary
  case walking
  case active
  case recovering

  /// Deterministic thresholds shared by Mock presentation and a future live sensor adapter.
  ///
  /// A high heart rate wins over GPS speed. Once movement stops, an elevated heart rate is shown
  /// as recovery instead of being mislabeled as rest.
  public static func classify(_ telemetry: MovementTelemetry) -> Self {
    if telemetry.heartRateBPM >= 120 || telemetry.speedMetersPerSecond >= 2.2 {
      return .active
    }
    if telemetry.speedMetersPerSecond >= 0.6 {
      return .walking
    }
    if telemetry.heartRateBPM >= 90 {
      return .recovering
    }
    return .stationary
  }
}
