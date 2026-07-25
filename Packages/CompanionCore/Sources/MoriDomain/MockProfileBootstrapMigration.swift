import CryptoKit
import Foundation

/// Reproduces the historical Mock profile identity exactly.
///
/// This is intentionally a migration contract, not a permissive shape check:
/// scenario, Lamport counter, and origin device are all framed and hashed
/// using the original version-one derivation.
public enum MockProfileBootstrapMigration {
  public static func derivedProfileID(
    scenarioID: MockScenarioID,
    revision: LamportRevision
  ) -> ProfileID {
    ProfileID("mock-profile-\(digest(scenarioID: scenarioID, revision: revision))")
  }

  public static func legacyDeletionRequestID(
    scenarioID: MockScenarioID,
    revision: LamportRevision
  ) -> DeletionRequestID {
    DeletionRequestID(
      "mock-baseline-\(digest(scenarioID: scenarioID, revision: revision))"
    )
  }

  /// Returns a valid bootstrap profile only for an authentic historical
  /// derivation. All merely shape-compatible or tampered profiles fail closed.
  public static func migrate(_ profile: RuntimeProfile) -> RuntimeProfile? {
    guard
      case .mock(let scenarioID, let selectionEpoch) = profile.source,
      scenarioID.isValid,
      selectionEpoch == profile.epoch,
      profile.epoch.isValid,
      profile.deletionEpoch.revision == profile.epoch.revision,
      profile.id
        == derivedProfileID(
          scenarioID: scenarioID,
          revision: profile.epoch.revision
        ),
      profile.deletionEpoch.requestID
        == legacyDeletionRequestID(
          scenarioID: scenarioID,
          revision: profile.epoch.revision
        )
    else {
      return nil
    }
    return RuntimeProfile(
      id: profile.id,
      epoch: profile.epoch,
      deletionEpoch: .bootstrap,
      source: profile.source
    )
  }

  private static func digest(
    scenarioID: MockScenarioID,
    revision: LamportRevision
  ) -> String {
    let components = [
      "mori-mock-profile-v1",
      scenarioID.rawValue,
      String(revision.counter),
      revision.originDeviceID,
    ]
    let framed = Data(
      components
        .map { component in
          "\(component.utf8.count):\(component)"
        }
        .joined()
        .utf8
    )
    return SHA256.hash(data: framed)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
