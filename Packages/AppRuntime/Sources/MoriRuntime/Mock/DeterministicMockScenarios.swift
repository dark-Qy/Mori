#if DEBUG
  import AppleAdapters
  import Foundation
  import MoriDomain

  public enum MoriMockScenario: String, CaseIterable, Codable, Sendable {
    case normalDay = "normal-day"
    case fastWalking = "fast-walking"
    case walkAndStop = "walk-and-stop"
    case lateSleep = "late-sleep"
    case deniedPermission = "denied-permission"
    case staleEvidence = "stale-evidence"
    case offlineSynchronization = "offline-synchronization"

    public var id: MockScenarioID { MockScenarioID(rawValue) }
  }

  public struct MoriMockScenarioSeed: Sendable {
    public let scenario: MoriMockScenario
    public let evaluatedAt: Date
    public let localHour: Int
    public let activation: CompanionActivationFact
    public let facts: [DerivedFactRecord]

    public init(
      scenario: MoriMockScenario,
      evaluatedAt: Date,
      localHour: Int,
      activation: CompanionActivationFact,
      facts: [DerivedFactRecord]
    ) {
      self.scenario = scenario
      self.evaluatedAt = evaluatedAt
      self.localHour = localHour
      self.activation = activation
      self.facts = facts
    }
  }

  /// The catalog has no fallback to production data. Unknown or profile-mismatched
  /// IDs resolve to `nil`, leaving the Mock runtime local and visibly invalid.
  public struct MoriMockScenarioCatalog: Sendable {
    private let normalizer: MoriEvidenceNormalizer

    public init(normalizer: MoriEvidenceNormalizer = MoriEvidenceNormalizer()) {
      self.normalizer = normalizer
    }

    /// Resolves reviewed UI fixture aliases to one deterministic runtime
    /// scenario. Unknown identifiers never fall back to production data.
    ///
    /// `mock2` intentionally follows the recovery-oriented fixture (short
    /// sleep and stress) rather than the older walk-and-stop placeholder.
    public func resolvedScenario(
      for scenarioID: MockScenarioID
    ) -> MoriMockScenario? {
      switch scenarioID.rawValue {
      case "mock1":
        .normalDay
      case "mock5":
        .normalDay
      case "mock2":
        .lateSleep
      case "mock6":
        .lateSleep
      case "mock3", "activity_high":
        .fastWalking
      default:
        MoriMockScenario(rawValue: scenarioID.rawValue)
      }
    }

    public func seed(
      for scenarioID: MockScenarioID,
      profile: RuntimeProfile,
      sensingEpoch: SensingEpoch
    ) -> MoriMockScenarioSeed? {
      guard
        let scenario = resolvedScenario(for: scenarioID),
        case .mock(let selectedScenarioID, _) = profile.source,
        selectedScenarioID == scenarioID
      else {
        return nil
      }

      let evaluatedAt =
        scenarioID.rawValue == "mock5" || scenarioID.rawValue == "mock6"
        ? Date(timeIntervalSince1970: 1_785_075_600)
        : Date(timeIntervalSince1970: 1_760_000_000)
      let activeSince = evaluatedAt.addingTimeInterval(-9 * 60 * 60)
      let admission = EvidenceAdmissionMode.companion(
        sensingEpoch,
        activeSince: activeSince
      )
      let activationStatus: CompanionActivationStatus =
        switch scenario {
        case .deniedPermission: .permissionDenied
        case .offlineSynchronization: .peerOffline
        default: .active
        }
      let activation = CompanionActivationFact(
        profileID: profile.id,
        profileEpoch: profile.epoch,
        deletionEpoch: profile.deletionEpoch,
        sensingEpoch: sensingEpoch,
        observedAt: evaluatedAt.addingTimeInterval(-60),
        freshUntil: evaluatedAt.addingTimeInterval(60),
        status: activationStatus
      )

      return MoriMockScenarioSeed(
        scenario: scenario,
        evaluatedAt: evaluatedAt,
        localHour:
          scenarioID.rawValue == "mock5"
          ? 22
          : scenarioID.rawValue == "mock6"
            ? 23
            : (scenario == .lateSleep ? 9 : 12),
        activation: activation,
        facts: facts(
          for: scenario,
          evaluatedAt: evaluatedAt,
          activeSince: activeSince,
          profile: profile,
          admission: admission
        )
      )
    }

    private func facts(
      for scenario: MoriMockScenario,
      evaluatedAt: Date,
      activeSince: Date,
      profile: RuntimeProfile,
      admission: EvidenceAdmissionMode
    ) -> [DerivedFactRecord] {
      switch scenario {
      case .normalDay, .offlineSynchronization:
        return companionHealthFacts(
          steps: 3_250,
          capturedAt: evaluatedAt.addingTimeInterval(-30),
          activeSince: activeSince,
          profile: profile,
          admission: admission
        )
      case .fastWalking:
        let olderAt = evaluatedAt.addingTimeInterval(-5 * 60)
        let newerAt = evaluatedAt.addingTimeInterval(-60)
        return
          companionHealthFacts(
            steps: 2_800,
            capturedAt: olderAt,
            activeSince: activeSince,
            profile: profile,
            admission: admission
          )
          + companionHealthFacts(
            steps: 3_300,
            capturedAt: newerAt,
            activeSince: activeSince,
            profile: profile,
            admission: admission
          )
          + [
            normalizer.normalizeMotion(
              BroadMotionObservation(
                activity: .walking,
                confidence: .high,
                observedAt: newerAt
              ),
              profile: profile,
              admission: admission
            )
          ].compactMap { $0 }
      case .walkAndStop:
        return [
          normalizer.normalizeMotion(
            BroadMotionObservation(
              activity: .walking,
              confidence: .high,
              observedAt: evaluatedAt.addingTimeInterval(-90)
            ),
            profile: profile,
            admission: admission
          ),
          normalizer.normalizeMotion(
            BroadMotionObservation(
              activity: .stationary,
              confidence: .high,
              observedAt: evaluatedAt.addingTimeInterval(-30)
            ),
            profile: profile,
            admission: admission
          ),
        ].compactMap { $0 }
      case .lateSleep:
        let sleepStart = evaluatedAt.addingTimeInterval(-5 * 60 * 60)
        let snapshot = mockHealthSnapshot(
          capturedAt: evaluatedAt.addingTimeInterval(-15 * 60),
          steps: nil,
          sleep: [
            SleepSample(
              start: sleepStart,
              end: sleepStart.addingTimeInterval(4 * 60 * 60 + 50 * 60),
              stage: .core
            )
          ]
        )
        return normalizer.normalizeHealth(
          snapshot,
          profile: profile,
          admission: admission
        ).companionFacts
      case .deniedPermission:
        return []
      case .staleEvidence:
        return companionHealthFacts(
          steps: 4_000,
          capturedAt: evaluatedAt.addingTimeInterval(-60 * 60),
          activeSince: activeSince,
          profile: profile,
          admission: admission
        )
      }
    }

    private func companionHealthFacts(
      steps: Int,
      capturedAt: Date,
      activeSince: Date,
      profile: RuntimeProfile,
      admission: EvidenceAdmissionMode
    ) -> [DerivedFactRecord] {
      normalizer.normalizeHealth(
        mockHealthSnapshot(
          capturedAt: capturedAt,
          steps: TimedQuantity(
            start: activeSince,
            end: capturedAt,
            value: Double(steps)
          ),
          sleep: []
        ),
        profile: profile,
        admission: admission
      ).companionFacts
    }

    private func mockHealthSnapshot(
      capturedAt: Date,
      steps: TimedQuantity?,
      sleep: [SleepSample]
    ) -> AppleAdapters.HealthSnapshot {
      AppleAdapters.HealthSnapshot(
        capturedAt: capturedAt,
        sleep: HealthReading(
          availability: sleep.isEmpty ? .noData : .available,
          values: sleep
        ),
        steps: HealthReading(
          availability: steps == nil ? .noData : .available,
          values: steps.map { [$0] } ?? []
        ),
        restingHeartRate: HealthReading(availability: .noData, values: []),
        workouts: HealthReading(availability: .noData, values: [])
      )
    }
  }
#endif
