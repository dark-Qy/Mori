import Domain
import Foundation

public enum CommitmentTransition: Equatable, Sendable {
  case accepted(CommitmentRecord)
  case updated(CommitmentRecord, bondAward: Int)
  case rejected
}

/// Authoritative responsibility rules. Missing a commitment creates a repairable relationship
/// state; it never removes growth, harms the pet, or turns an observed health result into blame.
public struct CommitmentRuleEngine: Sendable {
  public static let ruleID = "phase2.commitment.controllable-action"
  public static let ruleSetVersion = 1

  public init() {}

  public func accepting(
    _ acceptance: CommitmentAcceptance,
    at occurredAt: Date,
    existing: [CommitmentRecord]
  ) -> CommitmentTransition {
    guard isTrusted(ruleID: acceptance.ruleID, version: acceptance.ruleSetVersion) else {
      return .rejected
    }
    guard !existing.contains(where: { $0.commitmentID == acceptance.commitmentID }) else {
      return .rejected
    }
    guard !existing.contains(where: { $0.status == .active || $0.status == .needsRepair }) else {
      return .rejected
    }
    guard let timeZone = TimeZone(identifier: acceptance.timeZoneIdentifier) else {
      return .rejected
    }
    let acceptedDay = LocalDay.containing(occurredAt, in: timeZone)
    guard acceptance.targetDay >= acceptedDay else { return .rejected }
    guard
      !existing.contains(where: { record in
        guard let recordTimeZone = TimeZone(identifier: record.timeZoneIdentifier) else {
          return true
        }
        return LocalDay.containing(record.acceptedAt, in: recordTimeZone) == acceptedDay
      })
    else { return .rejected }

    return .accepted(
      CommitmentRecord(
        commitmentID: acceptance.commitmentID,
        kind: acceptance.kind,
        targetDay: acceptance.targetDay,
        timeZoneIdentifier: acceptance.timeZoneIdentifier,
        acceptedAt: occurredAt
      )
    )
  }

  public func resolving(
    _ resolution: CommitmentResolution,
    at occurredAt: Date,
    current: CommitmentRecord
  ) -> CommitmentTransition {
    guard
      isTrusted(ruleID: resolution.ruleID, version: resolution.ruleSetVersion),
      resolution.commitmentID == current.commitmentID,
      let timeZone = TimeZone(identifier: current.timeZoneIdentifier)
    else { return .rejected }

    let today = LocalDay.containing(occurredAt, in: timeZone)
    var updated = current
    updated.lastUpdatedAt = occurredAt

    switch (current.status, resolution.kind) {
    case (.active, .fulfilled):
      guard resolution.newTargetDay == nil, today <= current.targetDay else { return .rejected }
      updated.status = .fulfilled
      updated.revision += 1
      return .updated(updated, bondAward: 3)

    case (.active, .missed):
      guard resolution.newTargetDay == nil, today > current.targetDay else { return .rejected }
      updated.status = .needsRepair
      updated.revision += 1
      return .updated(updated, bondAward: 0)

    case (.active, .resized), (.needsRepair, .resized):
      guard let newTargetDay = resolution.newTargetDay, newTargetDay >= today else {
        return .rejected
      }
      updated.targetDay = newTargetDay
      updated.status = .active
      updated.revision += 1
      return .updated(updated, bondAward: 0)

    case (.needsRepair, .repaired):
      guard resolution.newTargetDay == nil else { return .rejected }
      updated.status = .repaired
      updated.revision += 1
      return .updated(updated, bondAward: 1)

    case (.active, .released), (.needsRepair, .released):
      guard resolution.newTargetDay == nil else { return .rejected }
      updated.status = .released
      updated.revision += 1
      return .updated(updated, bondAward: 0)

    default:
      return .rejected
    }
  }

  private func isTrusted(ruleID: String, version: Int) -> Bool {
    ruleID == Self.ruleID && version == Self.ruleSetVersion
  }
}
