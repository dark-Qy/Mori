import Foundation

public enum EventSource: String, Codable, CaseIterable, Sendable {
  case watch
  case phone
  case server
  case mock
}

public struct StoryBeatCompletion: Codable, Equatable, Sendable {
  public var beatID: String
  public var chapter: Int
  public var memory: String?

  public init(beatID: String, chapter: Int, memory: String? = nil) {
    self.beatID = beatID
    self.chapter = max(1, chapter)
    self.memory = memory
  }
}

public struct SideStoryUnlock: Codable, Equatable, Sendable {
  public var storyID: String
  public var ruleID: String
  public var ruleSetVersion: Int
  public var triggerEventID: UUID

  public init(
    storyID: String,
    ruleID: String,
    ruleSetVersion: Int,
    triggerEventID: UUID
  ) {
    self.storyID = storyID
    self.ruleID = ruleID
    self.ruleSetVersion = ruleSetVersion
    self.triggerEventID = triggerEventID
  }
}

public struct PetInteraction: Codable, Equatable, Sendable {
  public var kind: String

  public init(kind: String) {
    self.kind = kind
  }
}

public enum DailyHabitKind: String, Codable, CaseIterable, Sendable {
  case microRest
  case shortWalk
  case windDown
  case companionCheckIn
}

public struct DailyHabitCompletion: Codable, Equatable, Sendable {
  public var kind: DailyHabitKind
  public var localDay: LocalDay
  public var ruleID: String
  public var ruleSetVersion: Int

  public init(
    kind: DailyHabitKind,
    localDay: LocalDay,
    ruleID: String = "phase1.habit.daily-opportunity",
    ruleSetVersion: Int = 1
  ) {
    self.kind = kind
    self.localDay = localDay
    self.ruleID = ruleID
    self.ruleSetVersion = ruleSetVersion
  }
}

/// Commitments are limited to controllable actions. Health outcomes such as sleeping a certain
/// duration or reaching a heart-rate value are intentionally not representable here.
public enum CommitmentKind: String, Codable, CaseIterable, Sendable {
  case beginWindDown
  case takeMicroRest
  case takeShortWalk
  case checkInWithMori
}

public struct CommitmentAcceptance: Codable, Equatable, Sendable {
  public var commitmentID: UUID
  public var kind: CommitmentKind
  public var targetDay: LocalDay
  public var timeZoneIdentifier: String
  public var ruleID: String
  public var ruleSetVersion: Int

  public init(
    commitmentID: UUID,
    kind: CommitmentKind,
    targetDay: LocalDay,
    timeZoneIdentifier: String,
    ruleID: String = "phase2.commitment.controllable-action",
    ruleSetVersion: Int = 1
  ) {
    self.commitmentID = commitmentID
    self.kind = kind
    self.targetDay = targetDay
    self.timeZoneIdentifier = timeZoneIdentifier
    self.ruleID = ruleID
    self.ruleSetVersion = ruleSetVersion
  }
}

public enum CommitmentResolutionKind: String, Codable, CaseIterable, Sendable {
  case fulfilled
  case missed
  case repaired
  case resized
  case released
}

public struct CommitmentResolution: Codable, Equatable, Sendable {
  public var commitmentID: UUID
  public var kind: CommitmentResolutionKind
  public var newTargetDay: LocalDay?
  public var ruleID: String
  public var ruleSetVersion: Int

  public init(
    commitmentID: UUID,
    kind: CommitmentResolutionKind,
    newTargetDay: LocalDay? = nil,
    ruleID: String = "phase2.commitment.controllable-action",
    ruleSetVersion: Int = 1
  ) {
    self.commitmentID = commitmentID
    self.kind = kind
    self.newTargetDay = newTargetDay
    self.ruleID = ruleID
    self.ruleSetVersion = ruleSetVersion
  }
}

public enum DomainEvent: Codable, Equatable, Sendable {
  case healthSnapshotReceived(HealthSnapshot)
  case storyBeatCompleted(StoryBeatCompletion)
  case sideStoryUnlocked(SideStoryUnlock)
  case petInteracted(PetInteraction)
  case dailyHabitCompleted(DailyHabitCompletion)
  case commitmentAccepted(CommitmentAcceptance)
  case commitmentResolved(CommitmentResolution)
}

public struct EventEnvelope: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var eventID: UUID
  public var occurredAt: Date
  public var recordedAt: Date
  public var source: EventSource
  public var payload: DomainEvent

  public init(
    schemaVersion: Int = EventEnvelope.currentSchemaVersion,
    eventID: UUID,
    occurredAt: Date,
    recordedAt: Date? = nil,
    source: EventSource,
    payload: DomainEvent
  ) {
    self.schemaVersion = schemaVersion
    self.eventID = eventID
    self.occurredAt = occurredAt
    self.recordedAt = recordedAt ?? occurredAt
    self.source = source
    self.payload = payload
  }
}

extension EventEnvelope {
  public static func canonicalOrder(_ lhs: EventEnvelope, _ rhs: EventEnvelope) -> Bool {
    if lhs.occurredAt != rhs.occurredAt {
      return lhs.occurredAt < rhs.occurredAt
    }
    if lhs.recordedAt != rhs.recordedAt {
      return lhs.recordedAt < rhs.recordedAt
    }
    return lhs.eventID.uuidString < rhs.eventID.uuidString
  }
}
