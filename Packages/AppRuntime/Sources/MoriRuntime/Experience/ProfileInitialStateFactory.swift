import Foundation
import MoriDomain

public enum ProfileInitialStateFactoryError:
  Error, Equatable, Sendable
{
  case invalidProfile
  case invalidSensingAuthority
  case invalidInitialState(MoriDomainRejection)
}

/// Creates the product ledger's content-free baseline from complete authority.
///
/// Product records never enter this state. Facts, events, tasks, coins, and
/// collection ownership must arrive later as replayable experience envelopes.
public struct ProfileInitialStateFactory: Sendable {
  public init() {}

  public func make(
    profile: RuntimeProfile,
    sensing: CompanionSensingPreference
  ) throws -> ProfileState {
    guard profile.isValid else {
      throw ProfileInitialStateFactoryError.invalidProfile
    }
    guard sensing.epoch.isValid else {
      throw ProfileInitialStateFactoryError.invalidSensingAuthority
    }

    let bootstrapRevision = LamportRevision(
      counter: 1,
      originDeviceID: "mori-product-bootstrap"
    )
    let state = ProfileState(
      header: header(profile.id, profile: profile),
      runtimeProfile: profile,
      companionSensingEnabled: sensing.enabled,
      currentSensingEpoch: sensing.epoch,
      selectedIdentity: .penguin,
      identityRevision: bootstrapRevision,
      tone: .gentle,
      coinLedger: CoinLedger(
        header: header(
          CoinLedgerID("mori-coin-ledger-v1"),
          profile: profile
        )
      ),
      collection: CollectionState(
        header: header(
          CollectionID("mori-collection-v1"),
          profile: profile
        )
      )
    )
    if let rejection = state.validate() {
      throw ProfileInitialStateFactoryError.invalidInitialState(rejection)
    }
    return state
  }

  private func header<RecordID>(
    _ recordID: RecordID,
    profile: RuntimeProfile
  ) -> ProfileScopedRecordHeader<RecordID>
  where RecordID: Hashable & Codable & Sendable {
    ProfileScopedRecordHeader(
      recordID: recordID,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch
    )
  }
}
