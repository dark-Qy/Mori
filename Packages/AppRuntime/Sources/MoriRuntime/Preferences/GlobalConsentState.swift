import Foundation
import MoriDomain

public enum ConsentAuthorDevice: String, CaseIterable, Codable, Sendable {
  case phone
  case watch
}

public enum MoriConsentKind: String, CaseIterable, Codable, Sendable {
  case remoteChat
  case memoryContext
  case friendSharing
  case publicPetPublication
  case proactiveNotifications
  case dailyMemoryNotifications
  case letterNotifications

  public var requiredDisclosureVersion: UInt16 { 1 }
}

public struct MoriConsentRecord: Hashable, Codable, Sendable {
  public let enabled: Bool
  public let disclosureVersion: UInt16
  public let revision: LamportRevision
  public let authorDevice: ConsentAuthorDevice

  public init(
    enabled: Bool,
    disclosureVersion: UInt16,
    revision: LamportRevision,
    authorDevice: ConsentAuthorDevice
  ) {
    self.enabled = enabled
    self.disclosureVersion = disclosureVersion
    self.revision = revision
    self.authorDevice = authorDevice
  }

  public func isValid(for kind: MoriConsentKind) -> Bool {
    revision.isValid
      && (!enabled || disclosureVersion >= kind.requiredDisclosureVersion)
      && (!enabled || authorDevice == .phone)
  }
}

public struct GlobalConsentState: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let remoteChat: MoriConsentRecord
  public let memoryContext: MoriConsentRecord
  public let friendSharing: MoriConsentRecord
  public let publicPetPublication: MoriConsentRecord
  public let proactiveNotifications: MoriConsentRecord
  public let dailyMemoryNotifications: MoriConsentRecord
  public let letterNotifications: MoriConsentRecord

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    remoteChat: MoriConsentRecord,
    memoryContext: MoriConsentRecord,
    friendSharing: MoriConsentRecord,
    publicPetPublication: MoriConsentRecord,
    proactiveNotifications: MoriConsentRecord,
    dailyMemoryNotifications: MoriConsentRecord,
    letterNotifications: MoriConsentRecord
  ) {
    self.schemaVersion = schemaVersion
    self.remoteChat = remoteChat
    self.memoryContext = memoryContext
    self.friendSharing = friendSharing
    self.publicPetPublication = publicPetPublication
    self.proactiveNotifications = proactiveNotifications
    self.dailyMemoryNotifications = dailyMemoryNotifications
    self.letterNotifications = letterNotifications
  }

  public static func disabled(
    revision: LamportRevision,
    authorDevice: ConsentAuthorDevice
  ) -> Self {
    let record = MoriConsentRecord(
      enabled: false,
      disclosureVersion: 0,
      revision: revision,
      authorDevice: authorDevice
    )
    return Self(
      remoteChat: record,
      memoryContext: record,
      friendSharing: record,
      publicPetPublication: record,
      proactiveNotifications: record,
      dailyMemoryNotifications: record,
      letterNotifications: record
    )
  }

  public var isValid: Bool {
    schemaVersion == Self.currentSchemaVersion
      && MoriConsentKind.allCases.allSatisfy {
        self[$0].isValid(for: $0)
      }
  }

  public subscript(kind: MoriConsentKind) -> MoriConsentRecord {
    switch kind {
    case .remoteChat: remoteChat
    case .memoryContext: memoryContext
    case .friendSharing: friendSharing
    case .publicPetPublication: publicPetPublication
    case .proactiveNotifications: proactiveNotifications
    case .dailyMemoryNotifications: dailyMemoryNotifications
    case .letterNotifications: letterNotifications
    }
  }

  public func replacing(
    _ kind: MoriConsentKind,
    with record: MoriConsentRecord
  ) -> Self {
    Self(
      remoteChat: kind == .remoteChat ? record : remoteChat,
      memoryContext: kind == .memoryContext ? record : memoryContext,
      friendSharing: kind == .friendSharing ? record : friendSharing,
      publicPetPublication:
        kind == .publicPetPublication ? record : publicPetPublication,
      proactiveNotifications:
        kind == .proactiveNotifications ? record : proactiveNotifications,
      dailyMemoryNotifications:
        kind == .dailyMemoryNotifications ? record : dailyMemoryNotifications,
      letterNotifications:
        kind == .letterNotifications ? record : letterNotifications
    )
  }
}

public enum GlobalConsentMergeRejection: Error, Equatable, Sendable {
  case invalidCurrent
  case invalidIncoming
  case conflictingRecord(MoriConsentKind)
}

public enum GlobalConsentMergeResult: Equatable, Sendable {
  case applied(GlobalConsentState)
  case duplicate(GlobalConsentState)
  case rejected(GlobalConsentMergeRejection)
}

/// Consent is merged independently from ordinary preferences. At the same
/// logical counter a revocation wins over an expansion, regardless of device
/// ID. A causally later disclosed iPhone choice may expand consent again.
public enum GlobalConsentMerger {
  public static func merge(
    current: GlobalConsentState,
    incoming: GlobalConsentState
  ) -> GlobalConsentMergeResult {
    guard current.isValid else { return .rejected(.invalidCurrent) }
    guard incoming.isValid else { return .rejected(.invalidIncoming) }

    var merged = current
    for kind in MoriConsentKind.allCases {
      let record: MoriConsentRecord
      switch select(current: merged[kind], incoming: incoming[kind]) {
      case .selected(let selected):
        record = selected
      case .conflict:
        return .rejected(.conflictingRecord(kind))
      }
      merged = merged.replacing(kind, with: record)
    }
    guard merged.isValid else { return .rejected(.invalidIncoming) }
    return merged == current ? .duplicate(current) : .applied(merged)
  }

  private enum Selection {
    case selected(MoriConsentRecord)
    case conflict
  }

  private static func select(
    current: MoriConsentRecord,
    incoming: MoriConsentRecord
  ) -> Selection {
    if incoming.revision == current.revision {
      guard incoming != current else { return .selected(current) }
      if incoming.enabled != current.enabled {
        return .selected(incoming.enabled ? current : incoming)
      }
      guard incoming.enabled else {
        return .selected(
          MoriConsentRecord(
            enabled: false,
            disclosureVersion: min(
              current.disclosureVersion,
              incoming.disclosureVersion
            ),
            revision: current.revision,
            authorDevice:
              current.authorDevice == .watch
              || incoming.authorDevice == .watch
              ? .watch
              : .phone
          )
        )
      }
      // Reusing one logical identity for two different enabled disclosures is
      // corrupted authority. Converge to a synthetic revocation so a conflict
      // can never preserve or expand access.
      return .selected(
        MoriConsentRecord(
          enabled: false,
          disclosureVersion: 0,
          revision: current.revision,
          authorDevice: .phone
        )
      )
    }
    if incoming.revision.counter == current.revision.counter {
      if incoming.enabled != current.enabled {
        return .selected(incoming.enabled ? current : incoming)
      }
      return incoming.revision > current.revision
        ? .selected(incoming)
        : .selected(current)
    }
    return incoming.revision.counter > current.revision.counter
      ? .selected(incoming)
      : .selected(current)
  }
}
