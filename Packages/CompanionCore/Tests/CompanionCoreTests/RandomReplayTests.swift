import Domain
import MockKit
import Story
import Testing

@Suite("Seeded random story replay")
struct RandomReplayTests {
  @Test("The same seed produces the same sequence")
  func sameSeed() {
    var first = SeededRandomSource(seed: 42)
    var second = SeededRandomSource(seed: 42)

    let firstValues = (0..<20).map { _ in first.nextUnitInterval() }
    let secondValues = (0..<20).map { _ in second.nextUnitInterval() }

    #expect(firstValues == secondValues)
    #expect(firstValues.allSatisfy { (0..<1).contains($0) })
  }

  @Test("Lottery replay is independent of candidate input ordering")
  func stableCandidateOrder() {
    let candidates = [
      SideStoryCandidate(id: "soccer", probability: 0.35),
      SideStoryCandidate(id: "rain-walk", probability: 0.5),
    ]
    var first = SeededRandomSource(seed: 9_001)
    var second = SeededRandomSource(seed: 9_001)
    let lottery = SideStoryLottery()

    let firstDraws = (0..<30).map { _ in lottery.draw(from: candidates, using: &first) }
    let secondDraws = (0..<30).map { _ in lottery.draw(from: candidates.reversed(), using: &second)
    }

    #expect(firstDraws == secondDraws)
  }
}
