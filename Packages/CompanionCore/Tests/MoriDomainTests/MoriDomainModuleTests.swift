import MoriDomain
import Testing

@Suite("Mori domain module")
struct MoriDomainModuleTests {
  @Test("The isolated product domain is available")
  func moduleLoads() {
    #expect(MoriIdentity.allCases == [.penguin, .polarBear])
  }
}
