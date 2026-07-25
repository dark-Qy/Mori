import Foundation
import Testing

@testable import MoriDomain

@Suite("Bounded UI projections")
struct ProjectionTests {
  @Test("Watch shows two secondary tasks and iPhone shows three")
  func todayBounds() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    let event = MoriTestFixtures.event(profile: profile)
    state.tasks = (0..<7).map { index in
      MoriTestFixtures.task(
        "task-\(index)",
        event: event,
        profile: profile,
        issuedRevision: MoriTestFixtures.revision(UInt64(100 + index)),
        priority: index == 6 ? .recommended : .normal
      )
    }

    let watch = ProfileQueries.watchToday(from: state, at: MoriTestFixtures.now)
    let phone = ProfileQueries.phoneToday(from: state, at: MoriTestFixtures.now)
    #expect(watch.recommended?.header.recordID == TaskID("task-6"))
    #expect(watch.secondary.count == 2)
    #expect(phone.recommended?.header.recordID == TaskID("task-6"))
    #expect(phone.secondary.count == 3)
  }

  @Test("Expired tasks never occupy recommendation slots")
  func expiredTaskIsHidden() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    let event = MoriTestFixtures.event(profile: profile)
    let expired = MoriTestFixtures.task(
      "expired",
      event: event,
      profile: profile,
      issuedAt: MoriTestFixtures.now.addingTimeInterval(-7_200)
    )
    let active = MoriTestFixtures.task("active", event: event, profile: profile)
    state.tasks = [expired, active]

    let projection = ProfileQueries.phoneToday(from: state, at: MoriTestFixtures.now)
    #expect(projection.recommended?.header.recordID == active.header.recordID)
    #expect(projection.secondary.isEmpty)
  }

  @Test("Watch glance and facts honor confidence, deadline, freshness, and profile")
  func watchHomeBounds() {
    let profile = MoriTestFixtures.profile()
    let foreign = MoriTestFixtures.profile("foreign")
    var state = MoriTestFixtures.state(profile: profile)
    state.derivedFacts = [
      MoriTestFixtures.fact(
        "expired-steps",
        profile: profile,
        observedAt: MoriTestFixtures.now.addingTimeInterval(-7_200),
        freshUntil: MoriTestFixtures.now.addingTimeInterval(-1),
        value: .stepTotal(99_999)
      ),
      MoriTestFixtures.fact("current-steps", profile: profile, value: .stepTotal(3_250)),
      MoriTestFixtures.fact(
        "foreign-sleep",
        profile: foreign,
        value: .sleepDuration(99_999)
      ),
      MoriTestFixtures.fact(
        "current-sleep",
        profile: profile,
        value: .sleepDuration(27_000)
      ),
    ]
    state.passiveEvents = [
      MoriTestFixtures.event(
        "low",
        profile: profile,
        confidence: .low,
        observedAt: MoriTestFixtures.now.addingTimeInterval(10)
      ),
      MoriTestFixtures.event(
        "expired-glance",
        profile: profile,
        observedAt: MoriTestFixtures.now.addingTimeInterval(20),
        deadline: MoriTestFixtures.now.addingTimeInterval(-1)
      ),
      MoriTestFixtures.event(
        "visible",
        profile: profile,
        observedAt: MoriTestFixtures.now.addingTimeInterval(30),
        deadline: MoriTestFixtures.now.addingTimeInterval(120)
      ),
    ]

    let projection = ProfileQueries.watchHome(from: state, at: MoriTestFixtures.now)
    #expect(projection.pendingGlance?.header.recordID == EventID("visible"))
    #expect(projection.stepTotal == 3_250)
    #expect(projection.sleepDuration == 27_000)
  }

  @Test("Chat projection respects zero, negative, and positive message limits")
  func chatBounds() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    state.conversation = (0..<20).map { index in
      MoriTestFixtures.conversation(
        "message-\(index)",
        profile: profile,
        revision: MoriTestFixtures.revision(UInt64(100 + index))
      )
    }

    #expect(ProfileQueries.chatContext(from: state, recentMessageLimit: -1).recentMessages.isEmpty)
    #expect(ProfileQueries.chatContext(from: state, recentMessageLimit: 0).recentMessages.isEmpty)
    let bounded = ProfileQueries.chatContext(from: state, recentMessageLimit: 12)
    #expect(bounded.recentMessages.count == 12)
    #expect(bounded.recentMessages.first?.header.recordID == ConversationRecordID("message-8"))
  }

  @Test("Missing daily memory distinguishes before availability from preparing")
  func dailyMemoryAvailability() {
    let state = MoriTestFixtures.state()
    let day = LocalDay("2026-07-24")

    #expect(
      ProfileQueries.dailyMemory(
        from: state,
        localDay: day,
        timeZoneIdentifier: "Asia/Shanghai",
        afterAvailabilityTime: false
      ) == .unavailable
    )
    #expect(
      ProfileQueries.dailyMemory(
        from: state,
        localDay: day,
        timeZoneIdentifier: "Asia/Shanghai",
        afterAvailabilityTime: true
      ) == .preparing
    )
  }
}
