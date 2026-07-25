import CryptoKit
import Foundation
import MoriDomain
import MoriPersistence

public protocol TaskSettlementEventStore: Sendable {
  func currentLedger() async throws -> ProfileLedger
  func recordLocal(_ envelope: ExperienceSyncEnvelope) async throws
}

extension ExperienceSyncRuntime: TaskSettlementEventStore {}

public enum TaskSettlementRuntimeError: Error, Equatable, Sendable {
  case invalidOriginDeviceID
  case invalidProfileState(MoriDomainRejection)
  case taskNotFound(TaskID)
  case ambiguousSettlement(TaskSettlementID)
  case completionRejected(MoriDomainRejection)
  case unresolvedReward(TaskSettlementID)
  case logicalClockOverflow
}

public struct TaskSettlementResult: Equatable, Sendable {
  public let taskID: TaskID
  public let settlementID: TaskSettlementID
  public let completionEventID: ExperienceEventID
  public let rewardEventID: ExperienceEventID
  public let didRecordCompletion: Bool
  public let didRecordReward: Bool
  public let balance: Int

  public init(
    taskID: TaskID,
    settlementID: TaskSettlementID,
    completionEventID: ExperienceEventID,
    rewardEventID: ExperienceEventID,
    didRecordCompletion: Bool,
    didRecordReward: Bool,
    balance: Int
  ) {
    self.taskID = taskID
    self.settlementID = settlementID
    self.completionEventID = completionEventID
    self.rewardEventID = rewardEventID
    self.didRecordCompletion = didRecordCompletion
    self.didRecordReward = didRecordReward
    self.balance = balance
  }
}

public struct TaskSettlementRepairReport: Equatable, Sendable {
  public let scannedCompletedTaskCount: Int
  public let repairedSettlementIDs: [TaskSettlementID]

  public init(
    scannedCompletedTaskCount: Int,
    repairedSettlementIDs: [TaskSettlementID]
  ) {
    self.scannedCompletedTaskCount = scannedCompletedTaskCount
    self.repairedSettlementIDs = repairedSettlementIDs
  }
}

/// Persists task completion and its coin reward as two deterministic,
/// independently replayable events.
///
/// Completion is always durable before reward. Call
/// `repairIncompleteSettlements()` after startup and after receiving peer
/// events so a process stop or an incomplete transfer cannot strand a
/// completed task without its reward. Concurrent phone and Watch rewards use
/// distinct event IDs but the same settlement ID; `CoinLedger` therefore
/// projects exactly one credit on every peer.
public actor TaskSettlementRuntime<Store: TaskSettlementEventStore> {
  private let originDeviceID: String
  private let store: Store

  public init(
    originDeviceID: String,
    store: Store
  ) {
    self.originDeviceID = originDeviceID
    self.store = store
  }

  public func complete(
    taskID: TaskID,
    method: TaskCompletionMethod,
    at completedAt: Date
  ) async throws -> TaskSettlementResult {
    try requireValidOrigin()
    let ledger = try await validatedLedger()
    let replay = ledger.replay()
    guard
      var task = replay.state.tasks.first(where: {
        $0.header.recordID == taskID
      })
    else {
      throw TaskSettlementRuntimeError.taskNotFound(taskID)
    }
    try requireUnambiguous(task.settlementID, in: replay.state)

    let completionEventID: ExperienceEventID
    let didRecordCompletion: Bool
    if task.lifecycle.isCompleted {
      completionEventID = try completionEnvelopeID(
        for: task,
        in: replay.state
      )
      didRecordCompletion = false
    } else {
      let metadata = try nextMetadata(
        in: ledger,
        minimumCounter: max(
          task.issuedRevision.counter,
          task.lifecycleRevision.counter
        )
      )
      let transition = TaskTransition(
        header: ProfileScopedRecordHeader(
          recordID: TaskTransitionID(
            Self.stableID(
              prefix: "task-transition",
              components: identityComponents(
                task: task,
                suffix: [method.rawValue, originDeviceID]
              )
            )
          ),
          profileID: replay.state.runtimeProfile.id,
          profileEpoch: replay.state.runtimeProfile.epoch,
          deletionEpoch: replay.state.runtimeProfile.deletionEpoch
        ),
        taskID: task.header.recordID,
        revision: metadata.revision,
        state: .completed(method: method, at: completedAt),
        settlementID: task.settlementID
      )
      switch task.apply(transition, in: replay.state.runtimeProfile) {
      case .applied, .duplicate:
        break
      case .rejected(let rejection):
        throw TaskSettlementRuntimeError.completionRejected(rejection)
      }
      let envelope = completionEnvelope(
        transition: transition,
        profile: replay.state.runtimeProfile,
        authoredAt: completedAt,
        metadata: metadata
      )
      try await store.recordLocal(envelope)
      completionEventID = envelope.eventID
      didRecordCompletion = true
    }

    let reward = try await recordRewardIfNeeded(
      taskID: taskID,
      expectedSettlementID: task.settlementID
    )
    return TaskSettlementResult(
      taskID: taskID,
      settlementID: task.settlementID,
      completionEventID: completionEventID,
      rewardEventID: reward.eventID,
      didRecordCompletion: didRecordCompletion,
      didRecordReward: reward.didRecord,
      balance: reward.balance
    )
  }

  /// Repairs every completed task whose settlement has no accepted reward.
  ///
  /// This method is intentionally safe to call on every foreground activation
  /// and after every synchronization pass.
  public func repairIncompleteSettlements() async throws
    -> TaskSettlementRepairReport
  {
    try requireValidOrigin()
    let replay = try await validatedLedger().replay()
    let completed = replay.state.tasks
      .filter(\.lifecycle.isCompleted)
      .sorted { $0.header.recordID < $1.header.recordID }
    try requireUniqueSettlements(in: completed)

    var repaired: [TaskSettlementID] = []
    for task in completed {
      let result = try await recordRewardIfNeeded(
        taskID: task.header.recordID,
        expectedSettlementID: task.settlementID
      )
      if result.didRecord {
        repaired.append(task.settlementID)
      }
    }
    return TaskSettlementRepairReport(
      scannedCompletedTaskCount: completed.count,
      repairedSettlementIDs: repaired
    )
  }

  private func recordRewardIfNeeded(
    taskID: TaskID,
    expectedSettlementID: TaskSettlementID
  ) async throws -> RewardResult {
    let ledger = try await validatedLedger()
    let replay = ledger.replay()
    guard
      let task = replay.state.tasks.first(where: {
        $0.header.recordID == taskID
      })
    else {
      throw TaskSettlementRuntimeError.taskNotFound(taskID)
    }
    guard task.settlementID == expectedSettlementID else {
      throw TaskSettlementRuntimeError.ambiguousSettlement(
        expectedSettlementID
      )
    }
    try requireUnambiguous(task.settlementID, in: replay.state)
    guard task.lifecycle.isCompleted else {
      throw TaskSettlementRuntimeError.completionRejected(
        .completionNotAllowed
      )
    }

    if let existing = rewardEnvelope(
      for: task.settlementID,
      in: replay.state
    ) {
      return RewardResult(
        eventID: existing.eventID,
        didRecord: false,
        balance: replay.state.coinLedger.balance
      )
    }
    if ledger.envelopes.contains(where: {
      guard case .coinTransaction(let transaction) = $0.payload else {
        return false
      }
      guard case .taskReward(let settlementID) = transaction.reason else {
        return false
      }
      return settlementID == task.settlementID
    }) {
      throw TaskSettlementRuntimeError.unresolvedReward(
        task.settlementID
      )
    }

    let metadata = try nextMetadata(
      in: ledger,
      minimumCounter: task.lifecycleRevision.counter
    )
    let completedAt: Date
    if case .completed(_, let date) = task.lifecycle {
      completedAt = date
    } else {
      throw TaskSettlementRuntimeError.completionRejected(
        .completionNotAllowed
      )
    }
    let transaction = CoinTransaction(
      header: ProfileScopedRecordHeader(
        recordID: CoinTransactionID(
          Self.stableID(
            prefix: "settlement-reward-transaction",
            components: identityComponents(
              task: task,
              suffix: [originDeviceID]
            )
          )
        ),
        profileID: replay.state.runtimeProfile.id,
        profileEpoch: replay.state.runtimeProfile.epoch,
        deletionEpoch: replay.state.runtimeProfile.deletionEpoch
      ),
      revision: metadata.revision,
      authoredAt: completedAt,
      direction: .credit,
      amount: task.rewardTier.rawValue,
      reason: .taskReward(task.settlementID)
    )
    let envelope = ExperienceSyncEnvelope(
      eventID: ExperienceEventID(
        Self.stableID(
          prefix: "settlement-reward-event",
          components: identityComponents(
            task: task,
            suffix: [originDeviceID]
          )
        )
      ),
      eventType: .coinEarned,
      profileID: replay.state.runtimeProfile.id,
      profileEpoch: replay.state.runtimeProfile.epoch,
      deletionEpoch: replay.state.runtimeProfile.deletionEpoch,
      profileSource: replay.state.runtimeProfile.source,
      originDeviceID: originDeviceID,
      originSequence: metadata.originSequence,
      revision: metadata.revision,
      observedAt: nil,
      authoredAt: completedAt,
      privacyClass: .productState,
      tombstone: nil,
      sourceEventID: nil,
      settlementID: task.settlementID,
      payload: .coinTransaction(transaction)
    )
    try await store.recordLocal(envelope)
    let updated = try await validatedLedger().replay()
    return RewardResult(
      eventID: envelope.eventID,
      didRecord: true,
      balance: updated.state.coinLedger.balance
    )
  }

  private func validatedLedger() async throws -> ProfileLedger {
    let ledger = try await store.currentLedger()
    let replay = ledger.replay()
    if let rejection = replay.state.validate() {
      throw TaskSettlementRuntimeError.invalidProfileState(rejection)
    }
    return ledger
  }

  private func requireValidOrigin() throws {
    guard
      !originDeviceID.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
    else {
      throw TaskSettlementRuntimeError.invalidOriginDeviceID
    }
  }

  private func requireUnambiguous(
    _ settlementID: TaskSettlementID,
    in state: ProfileState
  ) throws {
    guard
      state.tasks.filter({ $0.settlementID == settlementID }).count == 1
    else {
      throw TaskSettlementRuntimeError.ambiguousSettlement(settlementID)
    }
  }

  private func requireUniqueSettlements(
    in tasks: [TaskInstance]
  ) throws {
    var seen: Set<TaskSettlementID> = []
    for task in tasks {
      guard seen.insert(task.settlementID).inserted else {
        throw TaskSettlementRuntimeError.ambiguousSettlement(
          task.settlementID
        )
      }
    }
  }

  private func completionEnvelopeID(
    for task: TaskInstance,
    in state: ProfileState
  ) throws -> ExperienceEventID {
    guard
      let transitionID = task.winningTransitionID,
      let envelope = state.experienceLedger.first(where: {
        guard case .taskTransition(let transition) = $0.payload else {
          return false
        }
        return transition.header.recordID == transitionID
      })
    else {
      throw TaskSettlementRuntimeError.invalidProfileState(
        .invalidRecord
      )
    }
    return envelope.eventID
  }

  private func rewardEnvelope(
    for settlementID: TaskSettlementID,
    in state: ProfileState
  ) -> ExperienceSyncEnvelope? {
    state.experienceLedger.first {
      guard case .coinTransaction(let transaction) = $0.payload else {
        return false
      }
      guard case .taskReward(let candidate) = transaction.reason else {
        return false
      }
      return candidate == settlementID
    }
  }

  private func completionEnvelope(
    transition: TaskTransition,
    profile: RuntimeProfile,
    authoredAt: Date,
    metadata: EventMetadata
  ) -> ExperienceSyncEnvelope {
    ExperienceSyncEnvelope(
      eventID: ExperienceEventID(
        Self.stableID(
          prefix: "settlement-completion-event",
          components: [transition.header.recordID.rawValue]
        )
      ),
      eventType: .taskCompleted,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch,
      profileSource: profile.source,
      originDeviceID: originDeviceID,
      originSequence: metadata.originSequence,
      revision: metadata.revision,
      observedAt: nil,
      authoredAt: authoredAt,
      privacyClass: .productState,
      tombstone: nil,
      sourceEventID: nil,
      settlementID: transition.settlementID,
      payload: .taskTransition(transition)
    )
  }

  private func identityComponents(
    task: TaskInstance,
    suffix: [String]
  ) -> [String] {
    [
      task.header.profileID.rawValue,
      String(task.header.profileEpoch.revision.counter),
      task.header.profileEpoch.revision.originDeviceID,
      task.header.deletionEpoch.requestID.rawValue,
      String(task.header.deletionEpoch.revision.counter),
      task.header.deletionEpoch.revision.originDeviceID,
      task.header.recordID.rawValue,
      task.settlementID.rawValue,
    ] + suffix
  }

  private func nextMetadata(
    in ledger: ProfileLedger,
    minimumCounter: UInt64
  ) throws -> EventMetadata {
    let maximumCounter = max(
      minimumCounter,
      ledger.envelopes.map(\.revision.counter).max() ?? 0
    )
    let nextCounter = maximumCounter.addingReportingOverflow(1)
    let maximumSequence =
      ledger.envelopes
      .filter { $0.originDeviceID == originDeviceID }
      .map(\.originSequence)
      .max() ?? 0
    let nextSequence = maximumSequence.addingReportingOverflow(1)
    guard !nextCounter.overflow, !nextSequence.overflow else {
      throw TaskSettlementRuntimeError.logicalClockOverflow
    }
    return EventMetadata(
      revision: LamportRevision(
        counter: nextCounter.partialValue,
        originDeviceID: originDeviceID
      ),
      originSequence: nextSequence.partialValue
    )
  }

  private static func stableID(
    prefix: String,
    components: [String]
  ) -> String {
    let digest = SHA256.hash(
      data: CanonicalHashInput.data(
        ["mori-task-settlement-v1", prefix] + components
      )
    )
    return "\(prefix).\(digest.map { String(format: "%02x", $0) }.joined())"
  }

  private struct EventMetadata {
    let revision: LamportRevision
    let originSequence: UInt64
  }

  private struct RewardResult {
    let eventID: ExperienceEventID
    let didRecord: Bool
    let balance: Int
  }
}
