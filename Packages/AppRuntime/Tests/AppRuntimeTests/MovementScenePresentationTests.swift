import AppRuntime
import Domain
import Testing

@Suite("Movement scene presentation")
struct MovementScenePresentationTests {
  @Test("GPS speed and heart rate select deterministic scenes")
  func sceneSelection() {
    let cases: [(MovementTelemetry, MovementSceneState, String, MovementSceneMotion)] = [
      (
        MovementTelemetry(speedMetersPerSecond: 0, heartRateBPM: 72),
        .stationary,
        "rainy_reading_room",
        .sitDown
      ),
      (
        MovementTelemetry(speedMetersPerSecond: 1.3, heartRateBPM: 96),
        .walking,
        "spring_meadow_stream",
        .walk
      ),
      (
        MovementTelemetry(speedMetersPerSecond: 2.9, heartRateBPM: 138),
        .active,
        "summer_lake",
        .briskMove
      ),
      (
        MovementTelemetry(speedMetersPerSecond: 0.2, heartRateBPM: 104),
        .recovering,
        "sunset_coast",
        .catchBreath
      ),
    ]

    for (telemetry, expectedState, expectedBackground, expectedMotion) in cases {
      let presentation = MovementScenePresentation(telemetry: telemetry)
      #expect(presentation.state == expectedState)
      #expect(presentation.backgroundID == expectedBackground)
      #expect(presentation.petMotion == expectedMotion)
    }
  }

  @Test("Walking motions loop while stop and recovery motions play once")
  func motionPlaybackSemantics() {
    #expect(MovementSceneMotion.walk.loopsWhileStateIsActive)
    #expect(MovementSceneMotion.briskMove.loopsWhileStateIsActive)
    #expect(!MovementSceneMotion.sitDown.loopsWhileStateIsActive)
    #expect(!MovementSceneMotion.catchBreath.loopsWhileStateIsActive)
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
