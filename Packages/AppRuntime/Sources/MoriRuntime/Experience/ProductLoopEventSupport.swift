import CryptoKit
import Foundation
import MoriDomain
import MoriPersistence

enum ProductLoopEventSupportError: Error, Equatable {
  case invalidOriginDeviceID
  case logicalClockOverflow
}

struct ProductLoopEventMetadata: Sendable {
  let revision: LamportRevision
  let originSequence: UInt64
}

enum ProductLoopEventSupport {
  static func nextMetadata(
    in ledger: ProfileLedger,
    originDeviceID: String,
    minimumCounter: UInt64 = 0
  ) throws -> ProductLoopEventMetadata {
    let origin = originDeviceID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard origin.isEmpty == false else {
      throw ProductLoopEventSupportError.invalidOriginDeviceID
    }
    let maximumCounter = max(
      minimumCounter,
      ledger.envelopes.map(\.revision.counter).max() ?? 0
    )
    let maximumSequence =
      ledger.envelopes
      .filter { $0.originDeviceID == origin }
      .map(\.originSequence)
      .max() ?? 0
    let nextCounter = maximumCounter.addingReportingOverflow(1)
    let nextSequence = maximumSequence.addingReportingOverflow(1)
    guard nextCounter.overflow == false, nextSequence.overflow == false else {
      throw ProductLoopEventSupportError.logicalClockOverflow
    }
    return ProductLoopEventMetadata(
      revision: LamportRevision(
        counter: nextCounter.partialValue,
        originDeviceID: origin
      ),
      originSequence: nextSequence.partialValue
    )
  }

  static func stableID(
    prefix: String,
    profile: RuntimeProfile,
    components: [String]
  ) -> String {
    let sourceComponents: [String] =
      switch profile.source {
      case .real:
        ["real"]
      case .mock(let scenarioID, let selectionEpoch):
        [
          "mock",
          scenarioID.rawValue,
          String(selectionEpoch.revision.counter),
          selectionEpoch.revision.originDeviceID,
        ]
      }
    let framed = CanonicalHashInput.data(
      [
        "mori-product-loop-v1",
        prefix,
        profile.id.rawValue,
        String(profile.epoch.revision.counter),
        profile.epoch.revision.originDeviceID,
        profile.deletionEpoch.requestID.rawValue,
        String(profile.deletionEpoch.revision.counter),
        profile.deletionEpoch.revision.originDeviceID,
      ] + sourceComponents + components
    )
    let digest = SHA256.hash(data: framed)
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(prefix)-\(digest)"
  }

  static func envelope(
    payload: ExperienceSyncPayload,
    profile: RuntimeProfile,
    originDeviceID: String,
    metadata: ProductLoopEventMetadata,
    observedAt: Date?,
    authoredAt: Date
  ) -> ExperienceSyncEnvelope {
    ExperienceSyncEnvelope(
      eventID: ExperienceEventID(
        stableID(
          prefix: "experience",
          profile: profile,
          components: [
            payload.eventType.rawValue,
            payload.aggregateRecordID,
            payloadRecordIdentity(payload),
            originDeviceID,
          ]
        )
      ),
      eventType: payload.eventType,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch,
      profileSource: profile.source,
      originDeviceID: originDeviceID,
      originSequence: metadata.originSequence,
      revision: metadata.revision,
      observedAt: observedAt,
      authoredAt: authoredAt,
      privacyClass: payload.expectedPrivacyClass,
      tombstone: nil,
      sourceEventID: sourceEventID(for: payload),
      settlementID: settlementID(for: payload),
      payload: payload
    )
  }

  private static func sourceEventID(
    for payload: ExperienceSyncPayload
  ) -> EventID? {
    switch payload {
    case .task(let task):
      task.sourceEventID
    case .letter(let letter):
      if case .event(let eventID) = letter.source {
        eventID
      } else {
        nil
      }
    default:
      nil
    }
  }

  private static func payloadRecordIdentity(
    _ payload: ExperienceSyncPayload
  ) -> String {
    switch payload {
    case .derivedFact(let record):
      record.header.recordID.rawValue
    case .passiveEvent(let record):
      record.header.recordID.rawValue
    case .passiveEventTransition(let record):
      record.header.recordID.rawValue
    case .task(let record):
      record.header.recordID.rawValue
    case .taskTransition(let record):
      record.header.recordID.rawValue
    case .coinTransaction(let record):
      record.header.recordID.rawValue
    case .memory(let record):
      record.header.recordID.rawValue
    case .memoryTransition(let record):
      record.header.recordID.rawValue
    case .letter(let record):
      record.header.recordID.rawValue
    case .letterTransition(let record):
      record.header.recordID.rawValue
    case .identitySelection(let record):
      record.header.recordID.rawValue
    case .collectionPurchase(let record):
      record.ownership.header.recordID.rawValue
    case .collectionOwnership(let record):
      record.header.recordID.rawValue
    case .collectionTransition(let record):
      record.header.recordID.rawValue
    }
  }

  private static func settlementID(
    for payload: ExperienceSyncPayload
  ) -> TaskSettlementID? {
    switch payload {
    case .task(let task):
      task.settlementID
    case .taskTransition(let transition):
      transition.settlementID
    case .coinTransaction(let transaction):
      if case .taskReward(let settlementID) = transaction.reason {
        settlementID
      } else {
        nil
      }
    default:
      nil
    }
  }
}
