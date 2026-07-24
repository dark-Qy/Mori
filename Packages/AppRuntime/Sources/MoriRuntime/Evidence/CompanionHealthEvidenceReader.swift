import AppleAdapters
import Foundation
import MoriDomain

/// Reads display and companion HealthKit summaries through separate windows.
///
/// A daily cumulative step query starts at the calendar-day boundary. When
/// companionship begins later, reusing that aggregate would either expose
/// pre-enable steps or suppress companion steps until the next day. The second
/// query begins no earlier than `activeSince`, so HealthKit performs the
/// source-deduplicated delta without Mori retaining raw samples or guessing.
public struct CompanionHealthEvidenceReader<Client: HealthDataClient>: Sendable {
  private let client: Client
  private let normalizer: MoriEvidenceNormalizer

  public init(
    client: Client,
    normalizer: MoriEvidenceNormalizer = MoriEvidenceNormalizer()
  ) {
    self.client = client
    self.normalizer = normalizer
  }

  public func read(
    in displayWindow: HealthQueryWindow,
    profile: RuntimeProfile,
    admission: EvidenceAdmissionMode
  ) async throws -> NormalizedEvidenceBatch {
    let displaySnapshot = try await client.fetchSnapshot(in: displayWindow)
    let display = normalizer.normalizeHealth(
      displaySnapshot,
      profile: profile,
      admission: .displayOnly
    )
    guard
      case .companion(_, let activeSince) = admission,
      activeSince <= displayWindow.end
    else {
      return display
    }

    let companionStart = max(displayWindow.start, activeSince)
    let companionSleepStart = max(displayWindow.sleepStart, activeSince)
    let companionSnapshot = try await client.fetchSnapshot(
      in: HealthQueryWindow(
        start: companionStart,
        sleepStart: min(companionSleepStart, companionStart),
        end: displayWindow.end
      )
    )
    let companion = normalizer.normalizeHealth(
      companionSnapshot,
      profile: profile,
      admission: admission
    )
    return NormalizedEvidenceBatch(
      displayFacts: display.displayFacts,
      companionFacts: companion.companionFacts
    )
  }
}
