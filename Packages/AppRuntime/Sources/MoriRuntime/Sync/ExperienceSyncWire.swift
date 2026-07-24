import Foundation
import MoriDomain
import MoriPersistence

public struct ExperienceSyncScope: Codable, Equatable, Sendable {
  public let schemaVersion: UInt16
  public let profileID: ProfileID
  public let profileEpoch: ProfileEpoch
  public let deletionEpoch: DeletionEpoch
  public let profileSource: RuntimeProfileSource

  public init(schemaVersion: UInt16 = 1, profile: RuntimeProfile) {
    self.schemaVersion = schemaVersion
    profileID = profile.id
    profileEpoch = profile.epoch
    deletionEpoch = profile.deletionEpoch
    profileSource = profile.source
  }

  public var profile: RuntimeProfile {
    RuntimeProfile(
      id: profileID,
      epoch: profileEpoch,
      deletionEpoch: deletionEpoch,
      source: profileSource
    )
  }

  public var isValid: Bool {
    schemaVersion == 1 && profile.isValid
  }

  public func contains(_ envelope: ExperienceSyncEnvelope) -> Bool {
    envelope.profileID == profileID
      && envelope.profileEpoch == profileEpoch
      && envelope.deletionEpoch == deletionEpoch
      && envelope.profileSource == profileSource
  }
}

public struct ExperienceSyncTransfer: Codable, Equatable, Sendable {
  public let schemaVersion: UInt16
  public let scope: ExperienceSyncScope
  public let envelopeBytes: [Data]

  public init(
    schemaVersion: UInt16 = 1,
    scope: ExperienceSyncScope,
    envelopeBytes: [Data]
  ) {
    self.schemaVersion = schemaVersion
    self.scope = scope
    self.envelopeBytes = envelopeBytes
  }
}

public struct ExperienceSyncAcknowledgement: Codable, Equatable, Sendable {
  public let schemaVersion: UInt16
  public let scope: ExperienceSyncScope
  public let eventIDs: [ExperienceEventID]
  public let terminalRejections: [ExperienceSyncTerminalRejection]

  public init(
    schemaVersion: UInt16 = 1,
    scope: ExperienceSyncScope,
    eventIDs: [ExperienceEventID],
    terminalRejections: [ExperienceSyncTerminalRejection] = []
  ) {
    self.schemaVersion = schemaVersion
    self.scope = scope
    self.eventIDs = eventIDs.sorted()
    self.terminalRejections = terminalRejections.sorted {
      $0.eventID < $1.eventID
    }
  }
}

public enum ExperienceSyncTerminalRejectionReason: String, Codable, Sendable {
  case supersededSensingEpoch
}

public struct ExperienceSyncTerminalRejection: Codable, Equatable, Sendable {
  public let eventID: ExperienceEventID
  public let reason: ExperienceSyncTerminalRejectionReason
  public let rejectedSensingEpoch: SensingEpoch
  public let winningSensingEpoch: SensingEpoch
  public let companionSensingEnabled: Bool

  public init(
    eventID: ExperienceEventID,
    reason: ExperienceSyncTerminalRejectionReason,
    rejectedSensingEpoch: SensingEpoch,
    winningSensingEpoch: SensingEpoch,
    companionSensingEnabled: Bool
  ) {
    self.eventID = eventID
    self.reason = reason
    self.rejectedSensingEpoch = rejectedSensingEpoch
    self.winningSensingEpoch = winningSensingEpoch
    self.companionSensingEnabled = companionSensingEnabled
  }
}

public enum ExperienceSyncWireError: Error, Equatable, Sendable {
  case oversized(actualBytes: Int, maximumBytes: Int)
  case malformed
  case unsupportedSchema(UInt16)
  case invalidScope
  case emptyTransfer
  case duplicateEventID(ExperienceEventID)
  case envelopeScopeMismatch(ExperienceEventID)
  case undeclaredField
}

/// A closed, versioned wire codec for the derived experience channel.
///
/// Individual envelopes still pass through `ExperienceEnvelopeCodec`, which
/// excludes raw health, route, contact, credential, social, and conversation
/// fields. The transfer wrapper adds only delivery metadata.
public struct ExperienceSyncWireCodec: Sendable {
  public static let defaultMaximumBytes = 512 * 1_024

  private let maximumBytes: Int
  private let codec: CanonicalJSONCodec
  private let envelopeCodec: ExperienceEnvelopeCodec

  public init(
    maximumBytes: Int = Self.defaultMaximumBytes,
    codec: CanonicalJSONCodec = CanonicalJSONCodec(),
    envelopeCodec: ExperienceEnvelopeCodec = ExperienceEnvelopeCodec()
  ) {
    self.maximumBytes = max(1, maximumBytes)
    self.codec = codec
    self.envelopeCodec = envelopeCodec
  }

  public func encode(_ transfer: ExperienceSyncTransfer) throws -> Data {
    _ = try validatedEnvelopes(in: transfer)
    let data = try codec.encode(transfer)
    try validateSize(data)
    return data
  }

  public func decodeTransfer(_ data: Data) throws -> ExperienceSyncTransfer {
    try validateSize(data)
    let transfer: ExperienceSyncTransfer
    do {
      transfer = try codec.decode(ExperienceSyncTransfer.self, from: data)
    } catch {
      throw ExperienceSyncWireError.malformed
    }
    try requireClosedShape(data, canonical: codec.encode(transfer))
    _ = try validatedEnvelopes(in: transfer)
    return transfer
  }

  public func decodeEnvelopes(
    in transfer: ExperienceSyncTransfer
  ) throws -> [ExperienceSyncEnvelope] {
    try validatedEnvelopes(in: transfer)
  }

  public func encode(_ acknowledgement: ExperienceSyncAcknowledgement) throws -> Data {
    try validate(acknowledgement)
    let data = try codec.encode(acknowledgement)
    try validateSize(data)
    return data
  }

  public func decodeAcknowledgement(
    _ data: Data
  ) throws -> ExperienceSyncAcknowledgement {
    try validateSize(data)
    let acknowledgement: ExperienceSyncAcknowledgement
    do {
      acknowledgement = try codec.decode(ExperienceSyncAcknowledgement.self, from: data)
    } catch {
      throw ExperienceSyncWireError.malformed
    }
    try requireClosedShape(data, canonical: codec.encode(acknowledgement))
    try validate(acknowledgement)
    return acknowledgement
  }

  private func validatedEnvelopes(
    in transfer: ExperienceSyncTransfer
  ) throws -> [ExperienceSyncEnvelope] {
    guard transfer.schemaVersion == 1 else {
      throw ExperienceSyncWireError.unsupportedSchema(transfer.schemaVersion)
    }
    guard transfer.scope.isValid else {
      throw ExperienceSyncWireError.invalidScope
    }
    guard transfer.envelopeBytes.isEmpty == false else {
      throw ExperienceSyncWireError.emptyTransfer
    }

    var seen: Set<ExperienceEventID> = []
    return try transfer.envelopeBytes.map { bytes in
      let envelope = try envelopeCodec.decode(bytes)
      guard transfer.scope.contains(envelope) else {
        throw ExperienceSyncWireError.envelopeScopeMismatch(envelope.eventID)
      }
      guard seen.insert(envelope.eventID).inserted else {
        throw ExperienceSyncWireError.duplicateEventID(envelope.eventID)
      }
      return envelope
    }
  }

  private func validate(
    _ acknowledgement: ExperienceSyncAcknowledgement
  ) throws {
    guard acknowledgement.schemaVersion == 1 else {
      throw ExperienceSyncWireError.unsupportedSchema(acknowledgement.schemaVersion)
    }
    guard acknowledgement.scope.isValid else {
      throw ExperienceSyncWireError.invalidScope
    }
    var seen: Set<ExperienceEventID> = []
    for eventID in acknowledgement.eventIDs {
      guard eventID.isValid else {
        throw ExperienceSyncWireError.malformed
      }
      guard seen.insert(eventID).inserted else {
        throw ExperienceSyncWireError.duplicateEventID(eventID)
      }
    }
    for rejection in acknowledgement.terminalRejections {
      guard
        rejection.eventID.isValid,
        rejection.rejectedSensingEpoch.isValid,
        rejection.winningSensingEpoch.isValid
      else {
        throw ExperienceSyncWireError.malformed
      }
      let isSuperseded =
        rejection.rejectedSensingEpoch < rejection.winningSensingEpoch
        || (rejection.rejectedSensingEpoch == rejection.winningSensingEpoch
          && rejection.companionSensingEnabled == false)
      guard isSuperseded else {
        throw ExperienceSyncWireError.malformed
      }
      guard seen.insert(rejection.eventID).inserted else {
        throw ExperienceSyncWireError.duplicateEventID(rejection.eventID)
      }
    }
  }

  private func validateSize(_ data: Data) throws {
    guard data.count <= maximumBytes else {
      throw ExperienceSyncWireError.oversized(
        actualBytes: data.count,
        maximumBytes: maximumBytes
      )
    }
  }

  private func requireClosedShape(_ source: Data, canonical: Data) throws {
    guard source == canonical else {
      throw ExperienceSyncWireError.undeclaredField
    }
  }
}
