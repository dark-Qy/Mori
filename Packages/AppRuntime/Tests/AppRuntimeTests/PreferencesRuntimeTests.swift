import AppRuntime
import Foundation
import Testing

@Suite("Application preferences")
struct PreferencesRuntimeTests {
  @Test("Sharing starts disabled while care summary is the selected future scope")
  func privacyDefaults() {
    let value = AppPreferences()

    #expect(!value.socialSharingEnabled)
    #expect(value.healthSharingScope == .careSummary)
    #expect(value.proactiveMessagesEnabled)
  }

  @Test("Preferences persist across repository instances")
  func roundTrip() async throws {
    let store = InMemoryPreferencesDataStore()
    let first = PreferencesRepository(store: store)
    var value = try await first.load()
    value.selectedOutfitID = "leaf"
    value.healthSharingScope = .limitedHealthSummary
    try await first.save(value)

    let second = PreferencesRepository(store: store)
    #expect(try await second.load() == value)
  }

  @Test("Future schemas fail closed")
  func schemaGuard() async {
    let repository = PreferencesRepository(store: InMemoryPreferencesDataStore())
    let future = AppPreferences(schemaVersion: AppPreferences.currentSchemaVersion + 1)

    await #expect(throws: PreferencesRepositoryError.unsupportedSchema(2)) {
      try await repository.save(future)
    }
  }
}
