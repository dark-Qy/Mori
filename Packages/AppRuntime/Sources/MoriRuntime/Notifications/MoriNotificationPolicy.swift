import CryptoKit
import Foundation
import MoriDomain

public enum MoriNotificationAuthorization: String, Hashable, Codable, Sendable {
  case notDetermined
  case denied
  case authorized
}

public enum MoriNotificationKind: String, CaseIterable, Codable, Sendable {
  case dailyMemory
  case letter

  var requiredConsentKind: MoriConsentKind {
    switch self {
    case .dailyMemory: .dailyMemoryNotifications
    case .letter: .letterNotifications
    }
  }
}

public struct MoriNotificationRoute: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let kind: MoriNotificationKind
  public let profileID: ProfileID
  public let profileEpoch: ProfileEpoch
  public let objectID: String

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    kind: MoriNotificationKind,
    profileID: ProfileID,
    profileEpoch: ProfileEpoch,
    objectID: String
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.profileID = profileID
    self.profileEpoch = profileEpoch
    self.objectID = objectID
  }
}

public enum MoriNotificationNavigationIntent: Hashable, Sendable {
  case dailyMemory(MemoryID)
  case letter(LetterID)
}

public struct MoriNotificationRequest: Hashable, Codable, Sendable {
  public let stableRequestID: String
  public let kind: MoriNotificationKind
  public let title: String
  public let body: String
  public let route: MoriNotificationRoute
  public let profileDeletionEpoch: DeletionEpoch
  public let contentRevision: LamportRevision
  public let budgetDay: LocalDay
  public let timeZoneIdentifier: String
  public let scheduledAt: Date

  public init(
    stableRequestID: String,
    kind: MoriNotificationKind,
    title: String,
    body: String,
    route: MoriNotificationRoute,
    profileDeletionEpoch: DeletionEpoch,
    contentRevision: LamportRevision,
    budgetDay: LocalDay,
    timeZoneIdentifier: String,
    scheduledAt: Date
  ) {
    self.stableRequestID = stableRequestID
    self.kind = kind
    self.title = title
    self.body = body
    self.route = route
    self.profileDeletionEpoch = profileDeletionEpoch
    self.contentRevision = contentRevision
    self.budgetDay = budgetDay
    self.timeZoneIdentifier = timeZoneIdentifier
    self.scheduledAt = scheduledAt
  }
}

public struct MoriNotificationSchedulingContext: Hashable, Sendable {
  public let activeProfile: RuntimeProfile
  public let deviceRole: DailyMemoryDeviceRole
  public let consent: GlobalConsentState
  public let localAuthorization: MoriNotificationAuthorization
  public let quietHours: CompanionQuietHours
  public let timeZone: TimeZone
  public let now: Date

  public init(
    activeProfile: RuntimeProfile,
    deviceRole: DailyMemoryDeviceRole,
    consent: GlobalConsentState,
    localAuthorization: MoriNotificationAuthorization,
    quietHours: CompanionQuietHours,
    timeZone: TimeZone,
    now: Date
  ) {
    self.activeProfile = activeProfile
    self.deviceRole = deviceRole
    self.consent = consent
    self.localAuthorization = localAuthorization
    self.quietHours = quietHours
    self.timeZone = timeZone
    self.now = now
  }
}

public enum MoriNotificationSuppression: Error, Hashable, Sendable {
  case watchIsNotAuthority
  case consentDisabled
  case localAuthorizationUnavailable
  case quietHours
  case invalidContent
  case alreadyPending
  case kindDailyBudget
  case totalDailyBudget
  case cooldown
  case clockRollback
  case activeRequestCapacity
}

public enum MoriNotificationCandidatePlan: Hashable, Sendable {
  case schedule(MoriNotificationRequest)
  case suppressed(MoriNotificationSuppression)
}

/// Creates a typed request only after global consent, per-kind consent, local
/// authorization, profile scope, and quiet hours all pass. Product budget and
/// durable OS delivery are applied by `MoriNotificationRuntime`.
public struct MoriNotificationPolicy: Sendable {
  public init() {}

  public func plan(
    memory: MemoryRecord,
    context: MoriNotificationSchedulingContext
  ) -> MoriNotificationCandidatePlan {
    if let suppression = commonSuppression(
      kind: .dailyMemory,
      context: context
    ) {
      return .suppressed(suppression)
    }
    guard
      memory.validate(in: context.activeProfile) == nil,
      case .sealed(let content) = memory.lifecycle,
      content.sealedAt <= context.now,
      memory.localDay
        == MoriNotificationLocalDay.resolve(
          context.now,
          timeZone: context.timeZone
        ),
      MoriNotificationLocalDay.hour(
        context.now,
        timeZone: context.timeZone
      ) >= DailyMemoryCompositionPolicy.releaseHour
    else {
      return .suppressed(.invalidContent)
    }

    return .schedule(
      makeRequest(
        kind: .dailyMemory,
        objectID: memory.header.recordID.rawValue,
        title: "Mori 的今日回忆",
        body: content.narrative,
        contentRevision: memory.authoredRevision,
        context: context
      )
    )
  }

  public func plan(
    letter: LetterRecord,
    context: MoriNotificationSchedulingContext
  ) -> MoriNotificationCandidatePlan {
    if let suppression = commonSuppression(
      kind: .letter,
      context: context
    ) {
      return .suppressed(suppression)
    }
    guard
      letter.validate(in: context.activeProfile) == nil,
      letter.deliveredAt <= context.now,
      !letter.isRead,
      !letter.isDeleted
    else {
      return .suppressed(.invalidContent)
    }

    return .schedule(
      makeRequest(
        kind: .letter,
        objectID: letter.header.recordID.rawValue,
        title: letter.title,
        body: letter.body,
        contentRevision: letter.authoredRevision,
        context: context
      )
    )
  }

  private func commonSuppression(
    kind: MoriNotificationKind,
    context: MoriNotificationSchedulingContext
  ) -> MoriNotificationSuppression? {
    guard context.deviceRole == .iPhone else {
      return .watchIsNotAuthority
    }
    guard
      context.consent.isValid,
      context.consent.proactiveNotifications.enabled,
      context.consent.proactiveNotifications.isValid(
        for: .proactiveNotifications
      ),
      context.consent[kind.requiredConsentKind].enabled,
      context.consent[kind.requiredConsentKind].isValid(
        for: kind.requiredConsentKind
      )
    else {
      return .consentDisabled
    }
    guard context.localAuthorization == .authorized else {
      return .localAuthorizationUnavailable
    }
    guard
      !context.quietHours.contains(
        context.now,
        timeZone: context.timeZone
      )
    else {
      return .quietHours
    }
    return nil
  }

  private func makeRequest(
    kind: MoriNotificationKind,
    objectID: String,
    title: String,
    body: String,
    contentRevision: LamportRevision,
    context: MoriNotificationSchedulingContext
  ) -> MoriNotificationRequest {
    MoriNotificationRequest(
      stableRequestID: MoriNotificationRequestIdentity.make(
        kind: kind,
        profileID: context.activeProfile.id,
        profileEpoch: context.activeProfile.epoch,
        objectID: objectID
      ),
      kind: kind,
      title: title,
      body: body,
      route: MoriNotificationRoute(
        kind: kind,
        profileID: context.activeProfile.id,
        profileEpoch: context.activeProfile.epoch,
        objectID: objectID
      ),
      profileDeletionEpoch: context.activeProfile.deletionEpoch,
      contentRevision: contentRevision,
      budgetDay: MoriNotificationLocalDay.resolve(
        context.now,
        timeZone: context.timeZone
      ),
      timeZoneIdentifier: context.timeZone.identifier,
      scheduledAt: context.now
    )
  }
}

/// Resolves current durable content to navigation data only. There is no
/// reducer, task, coin, or notification side effect on this path.
public struct MoriNotificationRouteResolver: Sendable {
  public init() {}

  public func resolve(
    _ route: MoriNotificationRoute,
    state: ProfileState
  ) -> MoriNotificationNavigationIntent? {
    guard
      route.schemaVersion == MoriNotificationRoute.currentSchemaVersion,
      route.profileID == state.runtimeProfile.id,
      route.profileEpoch == state.runtimeProfile.epoch,
      !route.objectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }

    switch route.kind {
    case .dailyMemory:
      let memoryID = MemoryID(route.objectID)
      guard
        let memory = state.memories.first(where: {
          $0.header.recordID == memoryID
        }),
        memory.validate(in: state.runtimeProfile) == nil,
        memory.lifecycle.isSealed
      else {
        return nil
      }
      return .dailyMemory(memoryID)
    case .letter:
      let letterID = LetterID(route.objectID)
      guard
        let letter = state.letters.first(where: {
          $0.header.recordID == letterID
        }),
        letter.validate(in: state.runtimeProfile) == nil,
        !letter.isDeleted
      else {
        return nil
      }
      return .letter(letterID)
    }
  }
}

enum MoriNotificationRequestIdentity {
  static func make(
    kind: MoriNotificationKind,
    profileID: ProfileID,
    profileEpoch: ProfileEpoch,
    objectID: String
  ) -> String {
    let digest = SHA256.hash(
      data: CanonicalHashInput.data([
        "mori-notification-v1",
        kind.rawValue,
        profileID.rawValue,
        String(profileEpoch.revision.counter),
        profileEpoch.revision.originDeviceID,
        objectID,
      ])
    )
    return
      "mori.\(kind.rawValue).\(digest.map { String(format: "%02x", $0) }.joined())"
  }
}

enum MoriNotificationLocalDay {
  static func resolve(
    _ date: Date,
    timeZone: TimeZone
  ) -> LocalDay {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents(
      [.year, .month, .day],
      from: date
    )
    return LocalDay(
      String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
      )
    )
  }

  static func hour(
    _ date: Date,
    timeZone: TimeZone
  ) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.component(.hour, from: date)
  }
}
