import MoriDomain
import MoriRuntime
import Testing

@Suite("Product-loop initial state")
struct ProfileInitialStateFactoryTests {
  @Test("Both peers derive the same content-free baseline")
  func deterministicContentFreeBaseline() throws {
    let profile = ExperienceTestFixtures.profile()
    let sensing = CompanionSensingPreference(
      enabled: true,
      epoch: ExperienceTestFixtures.sensingEpoch()
    )
    let factory = ProfileInitialStateFactory()

    let phone = try factory.make(profile: profile, sensing: sensing)
    let watch = try factory.make(profile: profile, sensing: sensing)

    #expect(phone == watch)
    #expect(phone.validate() == nil)
    #expect(phone.selectedIdentity == .penguin)
    #expect(phone.tone == .gentle)
    #expect(phone.derivedFacts.isEmpty)
    #expect(phone.passiveEvents.isEmpty)
    #expect(phone.tasks.isEmpty)
    #expect(phone.cooldowns.isEmpty)
    #expect(phone.coinLedger.transactions.isEmpty)
    #expect(phone.collection.ownership.isEmpty)
    #expect(phone.collection.equipped.isEmpty)
    #expect(phone.memories.isEmpty)
    #expect(phone.letters.isEmpty)
    #expect(phone.conversation.isEmpty)
    #expect(phone.experienceLedger.isEmpty)
  }

  @Test("Invalid profile and sensing authority fail before state creation")
  func invalidAuthorityFailsClosed() {
    let validProfile = ExperienceTestFixtures.profile()
    let invalidProfile = RuntimeProfile(
      id: ProfileID(""),
      epoch: validProfile.epoch,
      deletionEpoch: validProfile.deletionEpoch,
      source: .real
    )
    let validSensing = CompanionSensingPreference(
      enabled: true,
      epoch: ExperienceTestFixtures.sensingEpoch()
    )
    let invalidSensing = CompanionSensingPreference(
      enabled: true,
      epoch: SensingEpoch(
        LamportRevision(counter: 0, originDeviceID: "")
      )
    )
    let factory = ProfileInitialStateFactory()

    #expect(
      throws: ProfileInitialStateFactoryError.invalidProfile
    ) {
      _ = try factory.make(
        profile: invalidProfile,
        sensing: validSensing
      )
    }
    #expect(
      throws:
        ProfileInitialStateFactoryError.invalidSensingAuthority
    ) {
      _ = try factory.make(
        profile: validProfile,
        sensing: invalidSensing
      )
    }
  }
}
