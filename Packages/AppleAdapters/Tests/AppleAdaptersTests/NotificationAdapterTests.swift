import Foundation
import Testing

@testable import AppleAdapters

@Suite("Local notification adapter contract")
struct NotificationAdapterTests {
  @Test func responseParserRejectsMissingRouteAndPreservesParameters() {
    #expect(NotificationResponseParser.deepLink(from: [:]) == nil)
    #expect(
      NotificationResponseParser.deepLink(
        from: ["route": "pet/recovery", "parameters": ["source": "local"]]
      ) == NotificationDeepLink(route: "pet/recovery", parameters: ["source": "local"])
    )
  }
  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  @Test func quietHoursHandleOvernightWindow() {
    let quiet = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
    #expect(quiet.contains(minuteOfDay: 23 * 60))
    #expect(quiet.contains(minuteOfDay: 6 * 60 + 59))
    #expect(!quiet.contains(minuteOfDay: 12 * 60))
    #expect(!quiet.contains(minuteOfDay: 7 * 60))
  }

  @Test func permissionAndSameIdentifierSchedulingAreIdempotent() async throws {
    let client = MockLocalNotificationClient(calendar: utcCalendar)
    #expect(await client.requestPermission() == .authorized)
    #expect(await client.requestPermission() == .authorized)
    #expect(await client.permissionRequestCount == 1)

    let first = notification(id: "pet.greeting", offset: 10)
    let replacement = notification(id: "pet.greeting", offset: 20)
    #expect(try await client.schedule(first, policy: NotificationPolicy()) == .allow)
    #expect(try await client.schedule(replacement, policy: NotificationPolicy()) == .allow)
    #expect(await client.pending.count == 1)
    #expect(await client.pending["pet.greeting"] == replacement)
  }

  @Test func policySuppressesQuietHoursBeforeCooldown() async throws {
    let client = MockLocalNotificationClient(state: .authorized, calendar: utcCalendar)
    let fireDate = utcCalendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 23))!
    let result = try await client.schedule(
      LocalNotification(id: "quiet", title: "Mori", body: "Rest", fireDate: fireDate),
      policy: NotificationPolicy(
        quietHours: QuietHours(startMinute: 22 * 60, endMinute: 7 * 60),
        minimumCooldown: 3_600
      )
    )
    #expect(result == .suppressQuietHours)
    #expect(await client.pending.isEmpty)
  }

  @Test func cooldownUsesLastSuccessfullyScheduledDate() async throws {
    let client = MockLocalNotificationClient(state: .authorized, calendar: utcCalendar)
    #expect(
      try await client.schedule(
        notification(id: "one", offset: 0),
        policy: NotificationPolicy(minimumCooldown: 60)
      ) == .allow
    )
    #expect(
      try await client.schedule(
        notification(id: "two", offset: 10),
        policy: NotificationPolicy(minimumCooldown: 60)
      ) == .suppressCooldown(remainingSeconds: 50)
    )
    #expect(await client.pending.count == 1)
  }

  @Test func cooldownSurvivesClientRecreation() async throws {
    let cooldownStore = InMemoryNotificationCooldownStore()
    let first = MockLocalNotificationClient(
      state: .authorized,
      calendar: utcCalendar,
      cooldownStore: cooldownStore
    )
    #expect(
      try await first.schedule(
        notification(id: "first", offset: 0),
        policy: NotificationPolicy(minimumCooldown: 60)
      ) == .allow
    )

    let relaunched = MockLocalNotificationClient(
      state: .authorized,
      calendar: utcCalendar,
      cooldownStore: cooldownStore
    )
    #expect(
      try await relaunched.schedule(
        notification(id: "after-relaunch", offset: 10),
        policy: NotificationPolicy(minimumCooldown: 60)
      ) == .suppressCooldown(remainingSeconds: 50)
    )
    #expect(await relaunched.pending.isEmpty)
  }

  @Test func deepLinkRoundTripsAndCancelWorks() async throws {
    let client = MockLocalNotificationClient(state: .authorized, calendar: utcCalendar)
    let value = notification(id: "route", offset: 0)
    _ = try await client.schedule(value, policy: NotificationPolicy())
    #expect(await client.pending["route"]?.deepLink == value.deepLink)
    await client.cancel(id: "route")
    #expect(await client.pending.isEmpty)
  }

  @Test func deniedPermissionFailsWithoutScheduling() async {
    let client = MockLocalNotificationClient(state: .denied, calendar: utcCalendar)
    await #expect(throws: NotificationAdapterError.permissionDenied) {
      try await client.schedule(self.notification(id: "denied", offset: 0), policy: .init())
    }
  }

  private func notification(id: String, offset: TimeInterval) -> LocalNotification {
    LocalNotification(
      id: id,
      title: "Mori",
      body: "Hello",
      fireDate: Date(timeIntervalSince1970: 1_700_000_000 + offset),
      deepLink: NotificationDeepLink(route: "pet/story", parameters: ["chapter": "1"])
    )
  }
}
