import Foundation
import MoriPersistence
import Testing

@Suite("One-time legacy development reset")
struct LegacyDevelopmentResetTests {
  private let reset = LegacyDevelopmentReset()

  @Test("Empty legacy storage initializes a fresh store without a deletion")
  func emptyStore() throws {
    let scope = try realScope()

    let plan = reset.plan(
      scope: scope,
      progressionData: nil,
      preferencesData: nil,
      markerData: nil
    )

    guard case .apply(let marker, let preferences, let deleteProgression) = plan else {
      Issue.record("expected a fresh reset plan")
      return
    }
    #expect(marker.scope == scope)
    #expect(preferences == LegacyPreservedPreferences())
    #expect(deleteProgression == false)
  }

  @Test("Valid choices survive while every progression value is discarded")
  func validLegacyState() throws {
    let plan = reset.plan(
      scope: try realScope(),
      progressionData: try fixture("valid-progression"),
      preferencesData: try fixture("valid-preferences"),
      markerData: nil
    )

    guard case .apply(_, let preferences, let deleteProgression) = plan else {
      Issue.record("expected reset to apply")
      return
    }
    #expect(deleteProgression)
    #expect(preferences.hasCompletedOnboarding)
    #expect(preferences.companionID == "polar_bear")
    #expect(preferences.outfitID == "raincoat")
    #expect(preferences.backgroundID == "spring_valley")
    #expect(preferences.reminderMode == .lightHaptic)
    #expect(preferences.quietHoursStartMinute == 1_320)
    #expect(preferences.quietHoursEndMinute == 420)
    #expect(preferences.socialSharingEnabled == true)
    #expect(preferences.healthSharingScope == "careSummary")
  }

  @Test("Malformed progression resets cleanly and preserves independent preferences")
  func malformedProgression() throws {
    let plan = reset.plan(
      scope: try realScope(),
      progressionData: try fixture("malformed"),
      preferencesData: try fixture("valid-preferences"),
      markerData: nil
    )

    guard case .apply(_, let preferences, let deleteProgression) = plan else {
      Issue.record("malformed legacy progression must not poison the new store")
      return
    }
    #expect(deleteProgression)
    #expect(preferences.companionID == "polar_bear")
  }

  @Test("Future progression and preference schemas fail closed")
  func futureSchemas() throws {
    #expect(
      reset.plan(
        scope: try realScope(),
        progressionData: try fixture("future-progression"),
        preferencesData: nil,
        markerData: nil
      ) == .blocked(.futureProgressionSchema(99))
    )
    #expect(
      reset.plan(
        scope: try realScope(),
        progressionData: nil,
        preferencesData: try fixture("future-preferences"),
        markerData: nil
      ) == .blocked(.futurePreferencesSchema(99))
    )
  }

  @Test("Persisted marker makes relaunch idempotent")
  func repeatedReset() throws {
    let scope = try realScope()
    let marker = LegacyResetMarker(scope: scope)
    let markerData = try reset.encodeMarker(marker)

    #expect(
      reset.plan(
        scope: scope,
        progressionData: try fixture("valid-progression"),
        preferencesData: try fixture("valid-preferences"),
        markerData: markerData
      ) == .alreadyApplied(marker: marker)
    )
  }

  @Test("Real and Mock markers cannot authorize each other")
  func profileIsolation() throws {
    let real = try realScope()
    let mock = try LegacyStoreScope(kind: .mock, storeKey: "mock/ordinary-day")
    let realMarker = try reset.encodeMarker(LegacyResetMarker(scope: real))

    #expect(
      reset.plan(
        scope: mock,
        progressionData: nil,
        preferencesData: nil,
        markerData: realMarker
      ) == .blocked(.markerScopeMismatch)
    )
  }

  @Test("Malformed or future markers never authorize destructive work")
  func invalidMarkers() throws {
    let scope = try realScope()
    #expect(
      reset.plan(
        scope: scope,
        progressionData: nil,
        preferencesData: nil,
        markerData: try fixture("malformed")
      ) == .blocked(.malformedMarker)
    )

    let future = """
      {"schemaVersion":99,"resetVersion":1,"scope":{"kind":"real","storeKey":"real"}}
      """
    #expect(
      reset.plan(
        scope: scope,
        progressionData: nil,
        preferencesData: nil,
        markerData: Data(future.utf8)
      ) == .blocked(.futureMarkerSchema(99))
    )
  }

  private func realScope() throws -> LegacyStoreScope {
    try LegacyStoreScope(kind: .real, storeKey: "real")
  }

  private func fixture(_ name: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(
        forResource: name,
        withExtension: "json"
      )
    )
    return try Data(contentsOf: url)
  }
}
