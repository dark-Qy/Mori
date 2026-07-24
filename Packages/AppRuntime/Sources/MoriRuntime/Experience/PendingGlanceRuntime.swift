import Foundation
import MoriDomain

extension CompanionQuietHours {
  public func contains(_ date: Date, timeZone: TimeZone) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.hour, .minute], from: date)
    guard let hour = components.hour, let minute = components.minute else {
      return false
    }
    return contains(minuteOfDay: hour * 60 + minute)
  }
}

public struct PendingGlanceTerminalDecision: Hashable, Sendable {
  public let eventID: EventID
  public let state: ReminderState

  public init(eventID: EventID, state: ReminderState) {
    self.eventID = eventID
    self.state = state
  }
}

public struct PendingGlancePresentation: Hashable, Sendable {
  public let eventID: EventID
  public let eventKind: PassiveEventKind
  public let sceneID: String?
  public let moriActionID: String
  public let shouldPlayHaptic: Bool

  public init(
    eventID: EventID,
    eventKind: PassiveEventKind,
    sceneID: String?,
    moriActionID: String,
    shouldPlayHaptic: Bool
  ) {
    self.eventID = eventID
    self.eventKind = eventKind
    self.sceneID = sceneID
    self.moriActionID = moriActionID
    self.shouldPlayHaptic = shouldPlayHaptic
  }
}

public struct PendingGlancePlan: Hashable, Sendable {
  public let terminalDecisions: [PendingGlanceTerminalDecision]
  public let presentation: PendingGlancePresentation?

  public init(
    terminalDecisions: [PendingGlanceTerminalDecision],
    presentation: PendingGlancePresentation?
  ) {
    self.terminalDecisions = terminalDecisions
    self.presentation = presentation
  }

  public static let empty = PendingGlancePlan(
    terminalDecisions: [],
    presentation: nil
  )
}

public struct PendingGlanceTransitionIdentity: Hashable, Sendable {
  public let transitionID: EventTransitionID
  public let revision: LamportRevision

  public init(
    transitionID: EventTransitionID,
    revision: LamportRevision
  ) {
    self.transitionID = transitionID
    self.revision = revision
  }
}

public enum PendingGlanceTransitionAssemblyError: Error, Hashable, Sendable {
  case eventMismatch
  case profileMismatch
  case nonAdvancingRevision
  case invalidTransition(MoriDomainRejection)
}

/// Turns a local terminal decision into the profile transition that the
/// experience outbox can synchronize.
public struct PendingGlanceTransitionAssembler: Sendable {
  public init() {}

  public func assemble(
    _ decision: PendingGlanceTerminalDecision,
    for event: PassiveCompanionEvent,
    activeProfile: RuntimeProfile,
    identity: PendingGlanceTransitionIdentity
  ) throws -> PassiveEventTransition {
    guard decision.eventID == event.header.recordID else {
      throw PendingGlanceTransitionAssemblyError.eventMismatch
    }
    guard event.header.scopeMatches(activeProfile) else {
      throw PendingGlanceTransitionAssemblyError.profileMismatch
    }
    guard identity.revision > event.reminderRevision else {
      throw PendingGlanceTransitionAssemblyError.nonAdvancingRevision
    }
    let transition = PassiveEventTransition(
      header: ProfileScopedRecordHeader(
        recordID: identity.transitionID,
        profileID: activeProfile.id,
        profileEpoch: activeProfile.epoch,
        deletionEpoch: activeProfile.deletionEpoch
      ),
      eventID: decision.eventID,
      revision: identity.revision,
      state: decision.state
    )
    var candidate = event
    if case .rejected(let rejection) = candidate.apply(
      transition,
      in: activeProfile
    ) {
      throw PendingGlanceTransitionAssemblyError.invalidTransition(rejection)
    }
    return transition
  }
}

/// Reduces every pending event to one newest slot. A slot is eligible for at
/// most two minutes, even if malformed input carries a later deadline.
public struct PendingGlancePolicy: Sendable {
  public static let eligibilityDuration: TimeInterval = 2 * 60

  public init() {}

  public func foregroundActivationPlan(
    events: [PassiveCompanionEvent],
    activeProfile: RuntimeProfile,
    currentSensingEpoch: SensingEpoch,
    at date: Date,
    reminderMode: CompanionReminderMode,
    quietHours: CompanionQuietHours,
    timeZone: TimeZone
  ) -> PendingGlancePlan {
    let pending =
      events
      .filter {
        guard
          $0.validate(
            in: activeProfile,
            sensingEpoch: currentSensingEpoch
          ) == nil
        else {
          return false
        }
        if case .pending = $0.reminderState { return true }
        return false
      }
      .sorted(by: Self.isOlder)
    guard let newest = pending.last else { return .empty }

    var decisions = pending.dropLast().map {
      PendingGlanceTerminalDecision(
        eventID: $0.header.recordID,
        state: .replaced(by: newest.header.recordID, at: date)
      )
    }

    let maximumDeadline = newest.observedAt.addingTimeInterval(
      Self.eligibilityDuration
    )
    let effectiveDeadline = min(
      newest.presentationDeadline ?? maximumDeadline,
      maximumDeadline
    )
    guard date <= effectiveDeadline else {
      decisions.append(
        PendingGlanceTerminalDecision(
          eventID: newest.header.recordID,
          state: .expired(at: date)
        )
      )
      return PendingGlancePlan(
        terminalDecisions: decisions,
        presentation: nil
      )
    }
    guard date >= newest.observedAt else {
      return PendingGlancePlan(
        terminalDecisions: decisions,
        presentation: nil
      )
    }

    decisions.append(
      PendingGlanceTerminalDecision(
        eventID: newest.header.recordID,
        state: .presented(at: date)
      )
    )
    return PendingGlancePlan(
      terminalDecisions: decisions,
      presentation: PendingGlancePresentation(
        eventID: newest.header.recordID,
        eventKind: newest.kind,
        sceneID: newest.sceneID,
        moriActionID: newest.moriActionID,
        shouldPlayHaptic: reminderMode == .gentleHaptic
          && !quietHours.contains(date, timeZone: timeZone)
      )
    )
  }

  private static func isOlder(
    _ lhs: PassiveCompanionEvent,
    _ rhs: PassiveCompanionEvent
  ) -> Bool {
    if lhs.observedAt != rhs.observedAt {
      return lhs.observedAt < rhs.observedAt
    }
    return lhs.header.recordID < rhs.header.recordID
  }
}

/// Device-local protection against showing the same glance twice before its
/// terminal transition has reached the synchronized profile ledger.
///
/// Every terminal decision is committed to the presentation fence before a
/// presentation is returned. There is no suspension point after that commit,
/// so a crash can lose a presentation but cannot cause the same scoped event
/// to be returned again after relaunch.
public actor PendingGlanceRuntime<Clock: MoriExperienceClock> {
  private let clock: Clock
  private let policy: PendingGlancePolicy
  private let storage: any PendingGlancePresentationFenceStorage
  private let codec = PendingGlancePresentationFenceCodec()
  private var cachedSnapshot: PendingGlancePresentationFenceSnapshot?
  private var operationIsActive = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    clock: Clock,
    policy: PendingGlancePolicy = PendingGlancePolicy(),
    storage: any PendingGlancePresentationFenceStorage
  ) {
    self.clock = clock
    self.policy = policy
    self.storage = storage
  }

  public func foregroundActivation(
    events: [PassiveCompanionEvent],
    activeProfile: RuntimeProfile,
    currentSensingEpoch: SensingEpoch,
    reminderMode: CompanionReminderMode,
    quietHours: CompanionQuietHours,
    timeZone: TimeZone
  ) async throws -> PendingGlancePlan {
    await acquireOperation()
    defer { releaseOperation() }

    guard activeProfile.isValid else {
      throw PendingGlancePresentationFenceError.invalidProfile
    }
    let snapshot = try await loadSnapshot()
    let date = await clock.now()
    let terminalEventIDs = snapshot.terminalEventIDs(
      for: activeProfile
    )
    let eligibleEvents = events.filter {
      !terminalEventIDs.contains($0.header.recordID)
    }
    let plan = policy.foregroundActivationPlan(
      events: eligibleEvents,
      activeProfile: activeProfile,
      currentSensingEpoch: currentSensingEpoch,
      at: date,
      reminderMode: reminderMode,
      quietHours: quietHours,
      timeZone: timeZone
    )
    guard plan.terminalDecisions.isEmpty == false else {
      return plan
    }
    let updated = snapshot.appending(
      eventIDs: plan.terminalDecisions.map(\.eventID),
      for: activeProfile
    )
    try await storage.save(codec.encode(updated))
    cachedSnapshot = updated
    return plan
  }

  private func loadSnapshot() async throws
    -> PendingGlancePresentationFenceSnapshot
  {
    if let cachedSnapshot {
      return cachedSnapshot
    }
    let snapshot: PendingGlancePresentationFenceSnapshot
    if let data = try await storage.load() {
      snapshot = try codec.decode(data)
    } else {
      snapshot = PendingGlancePresentationFenceSnapshot()
    }
    cachedSnapshot = snapshot
    return snapshot
  }

  private func acquireOperation() async {
    guard operationIsActive else {
      operationIsActive = true
      return
    }
    await withCheckedContinuation { continuation in
      operationWaiters.append(continuation)
    }
  }

  private func releaseOperation() {
    guard operationWaiters.isEmpty == false else {
      operationIsActive = false
      return
    }
    operationWaiters.removeFirst().resume()
  }
}
