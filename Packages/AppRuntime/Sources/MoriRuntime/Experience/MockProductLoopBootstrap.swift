#if DEBUG
  import Foundation
  import MoriDomain
  import MoriPersistence

  public enum MockProductLoopBootstrapError:
    Error, Equatable, Sendable
  {
    case realProfile
    case invalidSensingAuthority
    case profileScopeMismatch
    case unknownScenario(MockScenarioID)
    case invalidAssembly(InferenceAssemblyError)
    case logicalClockOverflow
  }

  public struct MockProductLoopBootstrapResult:
    Equatable, Sendable
  {
    public let plannedEventCount: Int
    public let newlyPersistedEventCount: Int
    public let finalEventCount: Int
    public let balance: Int

    public init(
      plannedEventCount: Int,
      newlyPersistedEventCount: Int,
      finalEventCount: Int,
      balance: Int
    ) {
      self.plannedEventCount = plannedEventCount
      self.newlyPersistedEventCount = newlyPersistedEventCount
      self.finalEventCount = finalEventCount
      self.balance = balance
    }
  }

  /// Seeds one selected Mock profile entirely through synchronized envelopes.
  ///
  /// The plan is deterministic for the complete profile and sensing authority.
  /// Repeating it after a crash writes byte-identical IDs and payloads. Real
  /// profiles and unknown fixture aliases fail closed before any mutation.
  public struct MockProductLoopBootstrap: Sendable {
    public static let welcomeGrantAmount = 18
    public static let defaultOutfitID = CosmeticID("default")
    public static let defaultSceneID =
      CosmeticID("spring_meadow_stream")

    private static let originDeviceID = "mori-mock-bootstrap"

    private let catalog: MoriMockScenarioCatalog
    private let pipeline: PassiveInferencePipeline
    private let assembler: InferenceProposalAssembler

    public init(
      catalog: MoriMockScenarioCatalog = MoriMockScenarioCatalog(),
      pipeline: PassiveInferencePipeline = PassiveInferencePipeline(),
      assembler: InferenceProposalAssembler =
        InferenceProposalAssembler()
    ) {
      self.catalog = catalog
      self.pipeline = pipeline
      self.assembler = assembler
    }

    public func bootstrap<Store: TaskSettlementEventStore>(
      profile: RuntimeProfile,
      sensing: CompanionSensingPreference,
      store: Store
    ) async throws -> MockProductLoopBootstrapResult {
      let plan = try envelopes(profile: profile, sensing: sensing)
      let before = try await store.currentLedger()
      guard before.initialState.runtimeProfile == profile else {
        throw MockProductLoopBootstrapError.profileScopeMismatch
      }
      let existingIDs = Set(before.envelopes.map(\.eventID))
      for envelope in plan {
        try await store.recordLocal(envelope)
      }
      let after = try await store.currentLedger()
      return MockProductLoopBootstrapResult(
        plannedEventCount: plan.count,
        newlyPersistedEventCount: plan.lazy.filter {
          existingIDs.contains($0.eventID) == false
        }.count,
        finalEventCount: after.envelopes.count,
        balance: after.replay().state.coinLedger.balance
      )
    }

    /// Produces the complete deterministic envelope manifest without I/O.
    public func envelopes(
      profile: RuntimeProfile,
      sensing: CompanionSensingPreference
    ) throws -> [ExperienceSyncEnvelope] {
      guard case .mock(let scenarioID, _) = profile.source else {
        throw MockProductLoopBootstrapError.realProfile
      }
      guard sensing.epoch.isValid else {
        throw MockProductLoopBootstrapError.invalidSensingAuthority
      }
      guard
        let seed = catalog.seed(
          for: scenarioID,
          profile: profile,
          sensingEpoch: sensing.epoch
        )
      else {
        throw MockProductLoopBootstrapError.unknownScenario(
          scenarioID
        )
      }

      var builder = ManifestBuilder(
        profile: profile,
        authoredAt: seed.evaluatedAt
      )
      builder.appendWelcomeGrant()
      builder.appendDefaultCollection()

      guard sensing.enabled else {
        return builder.envelopes
      }
      try builder.beginSensingEpoch(sensing.epoch)
      for fact in seed.facts.sorted(by: factIsOlder) {
        builder.appendFact(fact)
      }

      let outcome = pipeline.evaluate(
        PassiveInferenceRequest(
          profile: profile,
          sensingEpoch: sensing.epoch,
          evaluatedAt: seed.evaluatedAt,
          localHour: seed.localHour,
          activation: seed.activation,
          facts: seed.facts
        )
      )
      guard var eventProposal = outcome.eventProposal else {
        return builder.envelopes
      }
      let taskProposal =
        outcome.taskProposal
        ?? fallbackTaskProposal(
          event: eventProposal,
          evaluatedAt: seed.evaluatedAt
        )
      if let taskProposal,
        eventProposal.taskCooldownKey != taskProposal.cooldownKey
      {
        eventProposal = PassiveEventProposal(
          profileID: eventProposal.profileID,
          profileEpoch: eventProposal.profileEpoch,
          deletionEpoch: eventProposal.deletionEpoch,
          sensingEpoch: eventProposal.sensingEpoch,
          sourceCandidateID: eventProposal.sourceCandidateID,
          kind: eventProposal.kind,
          observedAt: eventProposal.observedAt,
          confidence: eventProposal.confidence,
          evidence: eventProposal.evidence,
          presentationDeadline:
            eventProposal.presentationDeadline,
          replacementKey: eventProposal.replacementKey,
          taskCooldownKey: taskProposal.cooldownKey,
          memoryEligibility: eventProposal.memoryEligibility,
          sceneID: eventProposal.sceneID,
          moriActionID: eventProposal.moriActionID,
          presentation: eventProposal.presentation
        )
      }

      do {
        let eventMetadata = builder.nextMetadata()
        let eventID = EventID(
          ProductLoopEventSupport.stableID(
            prefix: "mock-event",
            profile: profile,
            components: [eventProposal.sourceCandidateID]
          )
        )
        let event = try assembler.assembleEvent(
          eventProposal,
          identity: PassiveEventAssemblyIdentity(
            eventID: eventID,
            reminderRevision: eventMetadata.revision
          ),
          profile: profile,
          currentSensingEpoch: sensing.epoch,
          authorizedFacts: seed.facts
        )
        builder.append(
          payload: .passiveEvent(event),
          metadata: eventMetadata,
          observedAt: event.observedAt
        )

        if let taskProposal {
          let taskMetadata = builder.nextMetadata()
          let task = try assembler.assembleTask(
            taskProposal,
            identity: TaskAssemblyIdentity(
              taskID: TaskID(
                ProductLoopEventSupport.stableID(
                  prefix: "mock-task",
                  profile: profile,
                  components: [
                    event.header.recordID.rawValue,
                    taskProposal.kind.rawValue,
                  ]
                )
              ),
              settlementID: TaskSettlementID(
                ProductLoopEventSupport.stableID(
                  prefix: "mock-settlement",
                  profile: profile,
                  components: [
                    event.header.recordID.rawValue,
                    taskProposal.kind.rawValue,
                  ]
                )
              ),
              issuedRevision: taskMetadata.revision
            ),
            sourceEvent: event,
            profile: profile
          )
          builder.append(
            payload: .task(task),
            metadata: taskMetadata,
            observedAt: nil
          )
        }
      } catch let error as InferenceAssemblyError {
        throw MockProductLoopBootstrapError.invalidAssembly(error)
      }
      return builder.envelopes
    }

    private func fallbackTaskProposal(
      event: PassiveEventProposal,
      evaluatedAt: Date
    ) -> MoriTaskProposal? {
      guard event.kind == .sharedWalk else { return nil }
      return MoriTaskProposal(
        sourceCandidateID: event.sourceCandidateID,
        kind: .reflectOnDay,
        cooldownKey: TaskCooldownKey(
          "task.reflect-day.shared-walk"
        ),
        recommendationPriority: .recommended,
        completionPolicy: .userConfirmation,
        issuedAt: evaluatedAt,
        cooldownDuration: 6 * 60 * 60,
        expiresAt: nil,
        rewardTier: .smallest
      )
    }

    private func factIsOlder(
      _ lhs: DerivedFactRecord,
      _ rhs: DerivedFactRecord
    ) -> Bool {
      if lhs.observedAt != rhs.observedAt {
        return lhs.observedAt < rhs.observedAt
      }
      return lhs.header.recordID < rhs.header.recordID
    }

    private struct ManifestBuilder {
      let profile: RuntimeProfile
      let authoredAt: Date
      private(set) var envelopes: [ExperienceSyncEnvelope] = []
      private var nextCounter: UInt64 = 1

      init(profile: RuntimeProfile, authoredAt: Date) {
        self.profile = profile
        self.authoredAt = authoredAt
      }

      mutating func beginSensingEpoch(
        _ sensingEpoch: SensingEpoch
      ) throws {
        let base = sensingEpoch.revision.counter
          .multipliedReportingOverflow(by: 64)
        guard base.overflow == false, base.partialValue < UInt64.max else {
          throw MockProductLoopBootstrapError.logicalClockOverflow
        }
        nextCounter = max(nextCounter, base.partialValue + 1)
      }

      mutating func nextMetadata() -> ProductLoopEventMetadata {
        defer { nextCounter &+= 1 }
        return ProductLoopEventMetadata(
          revision: LamportRevision(
            counter: nextCounter,
            originDeviceID: MockProductLoopBootstrap.originDeviceID
          ),
          originSequence: nextCounter
        )
      }

      mutating func appendWelcomeGrant() {
        let metadata = nextMetadata()
        let transaction = CoinTransaction(
          header: header(
            CoinTransactionID(
              ProductLoopEventSupport.stableID(
                prefix: "mock-welcome-grant",
                profile: profile,
                components: ["1"]
              )
            )
          ),
          revision: metadata.revision,
          authoredAt: authoredAt,
          direction: .credit,
          amount: MockProductLoopBootstrap.welcomeGrantAmount,
          reason: .welcomeGrant(schemaVersion: 1)
        )
        append(
          payload: .coinTransaction(transaction),
          metadata: metadata,
          observedAt: nil
        )
      }

      mutating func appendDefaultCollection() {
        let defaults: [(CosmeticID, CosmeticSlot)] = [
          (MockProductLoopBootstrap.defaultOutfitID, .outfit),
          (MockProductLoopBootstrap.defaultSceneID, .scene),
        ]
        for (itemID, slot) in defaults {
          let metadata = nextMetadata()
          let ownership = CollectionOwnershipRecord(
            header: header(
              CollectionOwnershipID(
                ProductLoopEventSupport.stableID(
                  prefix: "mock-default-ownership",
                  profile: profile,
                  components: [itemID.rawValue, slot.rawValue]
                )
              )
            ),
            cosmeticID: itemID,
            slot: slot,
            acquiredAt: authoredAt,
            purchaseTransactionID: nil,
            revision: metadata.revision
          )
          append(
            payload: .collectionOwnership(ownership),
            metadata: metadata,
            observedAt: nil
          )
        }
        for (itemID, slot) in defaults {
          let metadata = nextMetadata()
          let transition = CollectionTransition(
            header: header(
              CollectionTransitionID(
                ProductLoopEventSupport.stableID(
                  prefix: "mock-default-equip",
                  profile: profile,
                  components: [itemID.rawValue, slot.rawValue]
                )
              )
            ),
            cosmeticID: itemID,
            slot: slot,
            revision: metadata.revision
          )
          append(
            payload: .collectionTransition(transition),
            metadata: metadata,
            observedAt: nil
          )
        }
      }

      mutating func appendFact(_ fact: DerivedFactRecord) {
        let metadata = nextMetadata()
        append(
          payload: .derivedFact(fact),
          metadata: metadata,
          observedAt: fact.observedAt
        )
      }

      mutating func append(
        payload: ExperienceSyncPayload,
        metadata: ProductLoopEventMetadata,
        observedAt: Date?
      ) {
        envelopes.append(
          ProductLoopEventSupport.envelope(
            payload: payload,
            profile: profile,
            originDeviceID:
              MockProductLoopBootstrap.originDeviceID,
            metadata: metadata,
            observedAt: observedAt,
            authoredAt: authoredAt
          )
        )
      }

      private func header<RecordID>(
        _ recordID: RecordID
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
  }
#endif
