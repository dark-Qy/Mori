import Foundation
import Testing

@testable import MoriRuntime

@Suite("Deterministic Mock experience clock")
struct ExperienceClockTests {
  @Test("Mock time advances and can be reset without reading wall clock")
  func deterministicControl() async {
    let initial = Date(timeIntervalSince1970: 1_000)
    let clock = DeterministicMockExperienceClock(now: initial)

    #expect(await clock.now() == initial)
    await clock.advance(by: 120)
    #expect(await clock.now() == initial.addingTimeInterval(120))
    await clock.set(initial.addingTimeInterval(-60))
    #expect(await clock.now() == initial.addingTimeInterval(-60))
  }

  @Test("A non-finite interval cannot corrupt Mock time")
  func invalidAdvanceIsIgnored() async {
    let initial = Date(timeIntervalSince1970: 2_000)
    let clock = DeterministicMockExperienceClock(now: initial)

    await clock.advance(by: .infinity)

    #expect(await clock.now() == initial)
  }
}
