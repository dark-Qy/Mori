import AppRuntime
import Domain
import Testing

@Suite("Movement scene presentation")
struct MovementScenePresentationTests {
  @Test("GPS speed and heart rate select deterministic scenes")
  func sceneSelection() {
    let cases: [(MovementTelemetry, MovementSceneState, String)] = [
      (
        MovementTelemetry(speedMetersPerSecond: 0, heartRateBPM: 72),
        .stationary,
        "rainy_reading_room"
      ),
      (
        MovementTelemetry(speedMetersPerSecond: 1.3, heartRateBPM: 96),
        .walking,
        "spring_meadow_stream"
      ),
      (
        MovementTelemetry(speedMetersPerSecond: 2.9, heartRateBPM: 138),
        .active,
        "summer_lake"
      ),
      (
        MovementTelemetry(speedMetersPerSecond: 0.2, heartRateBPM: 104),
        .recovering,
        "sunset_coast"
      ),
    ]

    for (telemetry, expectedState, expectedBackground) in cases {
      let presentation = MovementScenePresentation(telemetry: telemetry)
      #expect(presentation.state == expectedState)
      #expect(presentation.backgroundID == expectedBackground)
    }
  }

  @Test("A high heart rate wins over low GPS speed")
  func heartRateWins() {
    let presentation = MovementScenePresentation(
      telemetry: MovementTelemetry(speedMetersPerSecond: 0.1, heartRateBPM: 130)
    )

    #expect(presentation.state == .active)
    #expect(presentation.petMood == .lively)
  }
}
