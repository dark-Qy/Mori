import Foundation

/// Interests Mori may learn from explicit choices or repeated, concrete behaviour.
/// Health measurements such as sleep duration, stages, and heart rate have no representation here.
public enum OwnerInterest: String, Codable, CaseIterable, Hashable, Sendable {
  case exploration
  case movement
  case outdoors
  case quietMoments
  case racketSports
  case teamSports
  case waterSports
}

public enum MoriExpressionStyle: String, Codable, CaseIterable, Hashable, Sendable {
  case gentle
  case concise
  case playful
}

public enum CompanionshipRhythm: String, Codable, CaseIterable, Hashable, Sendable {
  case quiet
  case balanced
  case lively
}

/// Coarse, non-diagnostic bedtime bands. Exact sleep times never cross into personalization.
public enum SleepRoutineBand: String, Codable, CaseIterable, Hashable, Sendable {
  case before2200
  case from2200To2359
  case afterMidnight
}

public enum SleepRoutineRegularity: String, Codable, CaseIterable, Hashable, Sendable {
  case steady
  case varied
}

/// A compact routine hint for choosing when Mori should be lively or quiet. It says nothing about
/// sleep quality, health, or personality.
public struct SleepRoutineProjection: Codable, Equatable, Sendable {
  public var band: SleepRoutineBand
  public var regularity: SleepRoutineRegularity
  public var confidence: Double

  public init(
    band: SleepRoutineBand,
    regularity: SleepRoutineRegularity,
    confidence: Double
  ) {
    self.band = band
    self.regularity = regularity
    self.confidence = PersonalizationMemory.clamp(confidence, to: 0...1)
  }
}

/// Mori's non-negotiable identity. Adaptive traits may change, but the core cannot.
public enum MoriCorePersonality: String, Codable, Sendable {
  case warmCuriousNonJudgmental
}

public enum PersonalizationEvidenceSource: String, Codable, Sendable {
  /// A setting or choice made directly by the owner.
  case explicitPreference
  /// A concrete interaction with Mori, such as opening a scene or choosing a response.
  case observedInteraction
  /// A completed workout supplied by the app's verified workout pipeline.
  case verifiedWorkout
  /// A multi-day, coarse routine aggregate. Individual sleep samples are discarded upstream.
  case aggregateRoutine
}

public struct PersonalizationEvidence: Codable, Equatable, Hashable, Sendable {
  public var id: String
  public var source: PersonalizationEvidenceSource
  public var observedAt: Date

  public init(id: String, source: PersonalizationEvidenceSource, observedAt: Date) {
    self.id = id
    self.source = source
    self.observedAt = observedAt
  }
}

/// A deliberately small set of learnable subjects. There is no free-form diagnostic field.
public enum PersonalizationMemorySubject: Codable, Equatable, Hashable, Sendable {
  case activity(WorkoutSummary.Activity)
  case expression(MoriExpressionStyle)
  case interest(OwnerInterest)
  case rhythm(CompanionshipRhythm)
  case sleepRoutine(band: SleepRoutineBand, regularity: SleepRoutineRegularity)
}

/// Internal learned evidence. Product UI should expose only enable/clear controls, not this ledger.
public struct PersonalizationMemory: Codable, Equatable, Sendable {
  public static let maximumEvidenceCount = 12

  public var subject: PersonalizationMemorySubject
  public var affinity: Double
  public var weight: Double
  public var decayPerDay: Double
  public var firstObservedAt: Date
  public var lastReinforcedAt: Date
  public var expiresAt: Date
  public var reinforcementCount: Int
  public var evidence: [PersonalizationEvidence]

  public init(
    subject: PersonalizationMemorySubject,
    affinity: Double,
    weight: Double,
    decayPerDay: Double,
    firstObservedAt: Date,
    lastReinforcedAt: Date,
    expiresAt: Date,
    reinforcementCount: Int = 1,
    evidence: [PersonalizationEvidence]
  ) {
    self.subject = subject
    self.affinity = Self.clamp(affinity, to: -1...1)
    self.weight = Self.clamp(weight, to: 0...1)
    self.decayPerDay = Self.clamp(decayPerDay, to: 0...1)
    self.firstObservedAt = min(firstObservedAt, lastReinforcedAt)
    self.lastReinforcedAt = max(firstObservedAt, lastReinforcedAt)
    self.expiresAt = max(expiresAt, self.lastReinforcedAt)
    self.reinforcementCount = max(1, reinforcementCount)
    self.evidence = Array(
      evidence
        .sorted {
          if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
          return $0.id < $1.id
        }
        .suffix(Self.maximumEvidenceCount)
    )
  }

  public func decayedWeight(at date: Date) -> Double {
    guard date > lastReinforcedAt else { return weight }
    let elapsedDays = date.timeIntervalSince(lastReinforcedAt) / 86_400
    return Self.clamp(weight - (elapsedDays * decayPerDay), to: 0...1)
  }

  public func isActive(at date: Date) -> Bool {
    date < expiresAt && decayedWeight(at: date) >= 0.05
  }

  fileprivate func maintained(at date: Date) -> PersonalizationMemory? {
    guard isActive(at: date) else { return nil }
    var updated = self
    updated.weight = decayedWeight(at: date)
    updated.lastReinforcedAt = max(lastReinforcedAt, date)
    return updated
  }

  fileprivate static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(range.upperBound, max(range.lowerBound, value))
  }
}

/// The only inputs that can become learned memory. AI text, individual sleep/heart measurements,
/// and inferred medical or psychological labels cannot be passed to the engine.
public enum PersonalizationSignal: Equatable, Sendable {
  public static let minimumSleepRoutineSampleCount = 5

  case explicitActivityPreference(
    activity: WorkoutSummary.Activity, affinity: Double, evidenceID: String)
  case explicitExpressionPreference(style: MoriExpressionStyle, evidenceID: String)
  case explicitInterest(interest: OwnerInterest, affinity: Double, evidenceID: String)
  case interactionRhythm(
    rhythm: CompanionshipRhythm, sampleCount: Int, evidenceID: String)
  case verifiedWorkout(
    activity: WorkoutSummary.Activity, durationMinutes: Int, evidenceID: String)
  /// A typed aggregate produced after individual sleep timestamps have been reduced in memory.
  /// Fewer than `minimumSleepRoutineSampleCount` observations are ignored.
  case sleepRoutine(
    band: SleepRoutineBand,
    regularity: SleepRoutineRegularity,
    sampleCount: Int,
    evidenceID: String
  )
}

public struct OwnerAffinityProfile: Codable, Equatable, Sendable {
  public var activityAffinities: [WorkoutSummary.Activity: Double]
  public var interestAffinities: [OwnerInterest: Double]
  public var preferredExpression: MoriExpressionStyle
  public var companionshipRhythm: CompanionshipRhythm
  public var sleepRoutine: SleepRoutineProjection?

  public init(
    activityAffinities: [WorkoutSummary.Activity: Double] = [:],
    interestAffinities: [OwnerInterest: Double] = [:],
    preferredExpression: MoriExpressionStyle = .gentle,
    companionshipRhythm: CompanionshipRhythm = .balanced,
    sleepRoutine: SleepRoutineProjection? = nil
  ) {
    self.activityAffinities = activityAffinities.mapValues {
      PersonalizationMemory.clamp($0, to: -1...1)
    }
    self.interestAffinities = interestAffinities.mapValues {
      PersonalizationMemory.clamp($0, to: -1...1)
    }
    self.preferredExpression = preferredExpression
    self.companionshipRhythm = companionshipRhythm
    self.sleepRoutine = sleepRoutine
  }

  private enum CodingKeys: String, CodingKey {
    case activityAffinities
    case interestAffinities
    case preferredExpression
    case companionshipRhythm
    case sleepRoutine
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawActivities =
      try container.decodeIfPresent([String: Double].self, forKey: .activityAffinities) ?? [:]
    let rawInterests =
      try container.decodeIfPresent([String: Double].self, forKey: .interestAffinities) ?? [:]
    var activities: [WorkoutSummary.Activity: Double] = [:]
    var interests: [OwnerInterest: Double] = [:]

    for (rawValue, affinity) in rawActivities {
      guard let activity = WorkoutSummary.Activity(rawValue: rawValue) else {
        throw DecodingError.dataCorruptedError(
          forKey: .activityAffinities,
          in: container,
          debugDescription: "Unknown activity affinity: \(rawValue)"
        )
      }
      activities[activity] = affinity
    }
    for (rawValue, affinity) in rawInterests {
      guard let interest = OwnerInterest(rawValue: rawValue) else {
        throw DecodingError.dataCorruptedError(
          forKey: .interestAffinities,
          in: container,
          debugDescription: "Unknown interest affinity: \(rawValue)"
        )
      }
      interests[interest] = affinity
    }

    self.init(
      activityAffinities: activities,
      interestAffinities: interests,
      preferredExpression: try container.decode(
        MoriExpressionStyle.self,
        forKey: .preferredExpression
      ),
      companionshipRhythm: try container.decode(
        CompanionshipRhythm.self,
        forKey: .companionshipRhythm
      ),
      sleepRoutine: try container.decodeIfPresent(
        SleepRoutineProjection.self,
        forKey: .sleepRoutine
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(
      Dictionary(uniqueKeysWithValues: activityAffinities.map { ($0.key.rawValue, $0.value) }),
      forKey: .activityAffinities
    )
    try container.encode(
      Dictionary(uniqueKeysWithValues: interestAffinities.map { ($0.key.rawValue, $0.value) }),
      forKey: .interestAffinities
    )
    try container.encode(preferredExpression, forKey: .preferredExpression)
    try container.encode(companionshipRhythm, forKey: .companionshipRhythm)
    try container.encodeIfPresent(sleepRoutine, forKey: .sleepRoutine)
  }
}

public struct MoriPersonalityProjection: Codable, Equatable, Sendable {
  public var core: MoriCorePersonality
  /// Stable-core values are explicit so the compact projection can be sent to the text service
  /// without exposing the underlying memory ledger.
  public var warmth: Double
  public var curiosity: Double
  public var nonJudgment: Double
  public var expressionStyle: MoriExpressionStyle
  public var companionshipRhythm: CompanionshipRhythm
  public var energy: Double
  public var playfulness: Double
  public var brevity: Double
  public var preferredActivities: [WorkoutSummary.Activity]
  public var interests: [OwnerInterest]
  public var sleepRoutine: SleepRoutineProjection?
  public var isPersonalized: Bool

  public init(
    core: MoriCorePersonality = .warmCuriousNonJudgmental,
    warmth: Double = 1,
    curiosity: Double = 0.85,
    nonJudgment: Double = 1,
    expressionStyle: MoriExpressionStyle,
    companionshipRhythm: CompanionshipRhythm,
    energy: Double,
    playfulness: Double,
    brevity: Double,
    preferredActivities: [WorkoutSummary.Activity],
    interests: [OwnerInterest],
    sleepRoutine: SleepRoutineProjection? = nil,
    isPersonalized: Bool
  ) {
    self.core = core
    self.warmth = PersonalizationMemory.clamp(warmth, to: 0...1)
    self.curiosity = PersonalizationMemory.clamp(curiosity, to: 0...1)
    self.nonJudgment = PersonalizationMemory.clamp(nonJudgment, to: 0...1)
    self.expressionStyle = expressionStyle
    self.companionshipRhythm = companionshipRhythm
    self.energy = PersonalizationMemory.clamp(energy, to: 0...1)
    self.playfulness = PersonalizationMemory.clamp(playfulness, to: 0...1)
    self.brevity = PersonalizationMemory.clamp(brevity, to: 0...1)
    self.preferredActivities = preferredActivities
    self.interests = interests
    self.sleepRoutine = sleepRoutine
    self.isPersonalized = isPersonalized
  }

  /// Service-facing terminology for the same bounded list of learned owner interests.
  public var preferredThemes: [OwnerInterest] {
    interests
  }
}

public struct MoriPersonalityProfile: Codable, Equatable, Sendable {
  public var core: MoriCorePersonality
  public var energy: Double
  public var playfulness: Double
  public var brevity: Double
  public var activityAffinities: [WorkoutSummary.Activity: Double]
  public var interestAffinities: [OwnerInterest: Double]

  public init(
    core: MoriCorePersonality = .warmCuriousNonJudgmental,
    energy: Double = 0.5,
    playfulness: Double = 0.5,
    brevity: Double = 0.45,
    activityAffinities: [WorkoutSummary.Activity: Double] = [:],
    interestAffinities: [OwnerInterest: Double] = [:]
  ) {
    self.core = .warmCuriousNonJudgmental
    self.energy = PersonalizationMemory.clamp(energy, to: 0...1)
    self.playfulness = PersonalizationMemory.clamp(playfulness, to: 0...1)
    self.brevity = PersonalizationMemory.clamp(brevity, to: 0...1)
    self.activityAffinities = activityAffinities.mapValues {
      PersonalizationMemory.clamp($0, to: -1...1)
    }
    self.interestAffinities = interestAffinities.mapValues {
      PersonalizationMemory.clamp($0, to: -1...1)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case core
    case energy
    case playfulness
    case brevity
    case activityAffinities
    case interestAffinities
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawActivities =
      try container.decodeIfPresent([String: Double].self, forKey: .activityAffinities) ?? [:]
    let rawInterests =
      try container.decodeIfPresent([String: Double].self, forKey: .interestAffinities) ?? [:]
    var activities: [WorkoutSummary.Activity: Double] = [:]
    var interests: [OwnerInterest: Double] = [:]

    for (rawValue, affinity) in rawActivities {
      guard let activity = WorkoutSummary.Activity(rawValue: rawValue) else {
        throw DecodingError.dataCorruptedError(
          forKey: .activityAffinities,
          in: container,
          debugDescription: "Unknown activity affinity: \(rawValue)"
        )
      }
      activities[activity] = affinity
    }
    for (rawValue, affinity) in rawInterests {
      guard let interest = OwnerInterest(rawValue: rawValue) else {
        throw DecodingError.dataCorruptedError(
          forKey: .interestAffinities,
          in: container,
          debugDescription: "Unknown interest affinity: \(rawValue)"
        )
      }
      interests[interest] = affinity
    }

    self.init(
      core: try container.decode(MoriCorePersonality.self, forKey: .core),
      energy: try container.decode(Double.self, forKey: .energy),
      playfulness: try container.decode(Double.self, forKey: .playfulness),
      brevity: try container.decode(Double.self, forKey: .brevity),
      activityAffinities: activities,
      interestAffinities: interests
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(core, forKey: .core)
    try container.encode(energy, forKey: .energy)
    try container.encode(playfulness, forKey: .playfulness)
    try container.encode(brevity, forKey: .brevity)
    try container.encode(
      Dictionary(uniqueKeysWithValues: activityAffinities.map { ($0.key.rawValue, $0.value) }),
      forKey: .activityAffinities
    )
    try container.encode(
      Dictionary(uniqueKeysWithValues: interestAffinities.map { ($0.key.rawValue, $0.value) }),
      forKey: .interestAffinities
    )
  }

  public static let original = MoriPersonalityProfile()

  public func projection(
    owner: OwnerAffinityProfile,
    isPersonalized: Bool
  ) -> MoriPersonalityProjection {
    guard isPersonalized else {
      return MoriPersonalityProjection(
        expressionStyle: .gentle,
        companionshipRhythm: .balanced,
        energy: Self.original.energy,
        playfulness: Self.original.playfulness,
        brevity: Self.original.brevity,
        preferredActivities: [],
        interests: [],
        sleepRoutine: nil,
        isPersonalized: false
      )
    }

    return MoriPersonalityProjection(
      core: core,
      expressionStyle: owner.preferredExpression,
      companionshipRhythm: owner.companionshipRhythm,
      energy: energy,
      playfulness: playfulness,
      brevity: brevity,
      preferredActivities: Self.rankedPositive(activityAffinities),
      interests: Self.rankedPositive(interestAffinities),
      sleepRoutine: owner.sleepRoutine,
      isPersonalized: true
    )
  }

  private static func rankedPositive<Key>(_ values: [Key: Double]) -> [Key]
  where Key: RawRepresentable & Hashable, Key.RawValue == String {
    values
      .filter { $0.value >= 0.15 }
      .sorted {
        if $0.value != $1.value { return $0.value > $1.value }
        return $0.key.rawValue < $1.key.rawValue
      }
      .prefix(3)
      .map(\.key)
  }
}

public struct PersonalizationState: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var isEnabled: Bool
  public var owner: OwnerAffinityProfile
  public var mori: MoriPersonalityProfile
  /// Internal evidence ledger. It is persisted for auditability and decay, not presented as UI.
  public var memories: [PersonalizationMemory]
  /// A maintenance cursor, not user behaviour. It prevents repeated reads at the same instant from
  /// changing Mori while allowing stale adaptive traits to converge as time advances.
  public var lastMoriAdaptedAt: Date?

  public init(
    schemaVersion: Int = PersonalizationState.currentSchemaVersion,
    isEnabled: Bool = true,
    owner: OwnerAffinityProfile = OwnerAffinityProfile(),
    mori: MoriPersonalityProfile = .original,
    memories: [PersonalizationMemory] = [],
    lastMoriAdaptedAt: Date? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.isEnabled = isEnabled
    self.owner = owner
    self.mori = mori
    self.memories = memories
    self.lastMoriAdaptedAt = lastMoriAdaptedAt
  }

  public var compactProjection: MoriPersonalityProjection {
    mori.projection(owner: owner, isPersonalized: isEnabled)
  }
}

/// Deterministic policy that turns allowed evidence into owner affinity and slowly adapts Mori.
public struct PersonalizationEngine: Sendable {
  public var maximumMoriAdaptationPerUpdate: Double

  public init(maximumMoriAdaptationPerUpdate: Double = 0.08) {
    self.maximumMoriAdaptationPerUpdate = PersonalizationMemory.clamp(
      maximumMoriAdaptationPerUpdate, to: 0...0.2)
  }

  public func recording(
    _ signal: PersonalizationSignal,
    in state: PersonalizationState,
    at date: Date
  ) -> PersonalizationState {
    guard state.isEnabled else { return state }
    guard let candidate = memory(for: signal, at: date) else { return state }
    var memories = maintained(state.memories, at: date)
    if candidate.evidence.first?.source == .explicitPreference,
      case .expression = candidate.subject
    {
      memories.removeAll {
        if case .expression = $0.subject { return true }
        return false
      }
    }
    if case .sleepRoutine = candidate.subject {
      memories.removeAll {
        guard case .sleepRoutine = $0.subject else { return false }
        return $0.subject != candidate.subject
      }
    }

    if let index = memories.firstIndex(where: { $0.subject == candidate.subject }) {
      memories[index] = reinforced(memories[index], with: candidate, at: date)
    } else {
      memories.append(candidate)
    }
    return rebuiltAfterEvidence(state, memories: memories, at: date)
  }

  public func maintaining(_ state: PersonalizationState, at date: Date) -> PersonalizationState {
    let memories = maintained(state.memories, at: date)
    let owner = ownerProfile(from: memories, at: date)
    let target = personalityTarget(owner: owner, memories: memories)
    let adaptationBudget = maintenanceAdaptationBudget(
      state: state,
      at: date,
      needsConvergence: state.mori != target
    )
    guard
      memories != state.memories
        || owner != state.owner
        || adaptationBudget > 0
    else { return state }

    let mori =
      adaptationBudget > 0
      ? adapt(state.mori, toward: target, maximumStep: adaptationBudget)
      : state.mori
    return PersonalizationState(
      schemaVersion: state.schemaVersion,
      isEnabled: state.isEnabled,
      owner: owner,
      mori: mori,
      memories: memories.sorted(by: Self.memoryOrder),
      lastMoriAdaptedAt: mori != state.mori ? date : state.lastMoriAdaptedAt
    )
  }

  private func maintained(
    _ memories: [PersonalizationMemory],
    at date: Date
  ) -> [PersonalizationMemory] {
    memories.compactMap { $0.maintained(at: date) }
  }

  private func reinforced(
    _ existing: PersonalizationMemory,
    with candidate: PersonalizationMemory,
    at date: Date
  ) -> PersonalizationMemory {
    let existingWeight = existing.decayedWeight(at: date)
    let isExplicit = candidate.evidence.first?.source == .explicitPreference
    let combinedWeight =
      isExplicit
      ? max(existingWeight, candidate.weight)
      : min(1, existingWeight + candidate.weight * (1 - existingWeight))
    let affinity =
      isExplicit
      ? candidate.affinity
      : weightedMean(
        existing.affinity,
        weight: existingWeight,
        candidate.affinity,
        weight: candidate.weight
      )
    let mergedEvidence = Dictionary(
      (existing.evidence + candidate.evidence).map { ($0.id, $0) },
      uniquingKeysWith: { first, second in
        first.observedAt >= second.observedAt ? first : second
      }
    ).values

    return PersonalizationMemory(
      subject: existing.subject,
      affinity: affinity,
      weight: combinedWeight,
      decayPerDay: min(existing.decayPerDay, candidate.decayPerDay),
      firstObservedAt: min(existing.firstObservedAt, candidate.firstObservedAt),
      lastReinforcedAt: date,
      expiresAt: max(existing.expiresAt, candidate.expiresAt),
      reinforcementCount: existing.reinforcementCount + 1,
      evidence: Array(mergedEvidence)
    )
  }

  private func weightedMean(
    _ first: Double,
    weight firstWeight: Double,
    _ second: Double,
    weight secondWeight: Double
  ) -> Double {
    let total = firstWeight + secondWeight
    guard total > 0 else { return 0 }
    return ((first * firstWeight) + (second * secondWeight)) / total
  }

  private func rebuiltAfterEvidence(
    _ state: PersonalizationState,
    memories: [PersonalizationMemory],
    at date: Date
  ) -> PersonalizationState {
    let owner = ownerProfile(from: memories, at: date)
    let mori =
      ownerChangesMoriTraits(from: state.owner, to: owner)
      ? adapt(
        state.mori,
        toward: personalityTarget(owner: owner, memories: memories),
        maximumStep: maximumMoriAdaptationPerUpdate
      )
      : state.mori
    return PersonalizationState(
      schemaVersion: state.schemaVersion,
      isEnabled: state.isEnabled,
      owner: owner,
      mori: mori,
      memories: memories.sorted(by: Self.memoryOrder),
      lastMoriAdaptedAt: mori != state.mori ? date : state.lastMoriAdaptedAt
    )
  }

  private func maintenanceAdaptationBudget(
    state: PersonalizationState,
    at date: Date,
    needsConvergence: Bool
  ) -> Double {
    guard needsConvergence else { return 0 }
    guard let previous = state.lastMoriAdaptedAt else {
      return maximumMoriAdaptationPerUpdate
    }
    guard date > previous else { return 0 }
    let completeDays = floor(date.timeIntervalSince(previous) / 86_400)
    return completeDays * maximumMoriAdaptationPerUpdate
  }

  private func ownerChangesMoriTraits(
    from previous: OwnerAffinityProfile,
    to updated: OwnerAffinityProfile
  ) -> Bool {
    previous.activityAffinities != updated.activityAffinities
      || previous.interestAffinities != updated.interestAffinities
      || previous.preferredExpression != updated.preferredExpression
      || previous.companionshipRhythm != updated.companionshipRhythm
  }

  private func ownerProfile(
    from memories: [PersonalizationMemory],
    at date: Date
  ) -> OwnerAffinityProfile {
    var activities: [WorkoutSummary.Activity: Double] = [:]
    var interests: [OwnerInterest: Double] = [:]
    var expressions: [MoriExpressionStyle: Double] = [:]
    var rhythms: [CompanionshipRhythm: Double] = [:]
    var sleepRoutines: [(projection: SleepRoutineProjection, score: Double)] = []

    for memory in memories where memory.isActive(at: date) {
      let score = memory.affinity * memory.decayedWeight(at: date)
      switch memory.subject {
      case .activity(let activity):
        activities[activity] = score
      case .interest(let interest):
        interests[interest] = score
      case .expression(let style):
        expressions[style] = max(0, score)
      case .rhythm(let rhythm):
        rhythms[rhythm] = max(0, score)
      case .sleepRoutine(let band, let regularity):
        sleepRoutines.append(
          (
            SleepRoutineProjection(
              band: band,
              regularity: regularity,
              confidence: memory.decayedWeight(at: date)
            ),
            score
          )
        )
      }
    }

    return OwnerAffinityProfile(
      activityAffinities: activities,
      interestAffinities: interests,
      preferredExpression: strongest(expressions, fallback: .gentle),
      companionshipRhythm: strongest(rhythms, fallback: .balanced),
      sleepRoutine: sleepRoutines.max {
        if $0.score != $1.score { return $0.score < $1.score }
        if $0.projection.band != $1.projection.band {
          return $0.projection.band.rawValue > $1.projection.band.rawValue
        }
        return $0.projection.regularity.rawValue > $1.projection.regularity.rawValue
      }?.projection
    )
  }

  private func strongest<Key>(
    _ scores: [Key: Double],
    fallback: Key
  ) -> Key where Key: RawRepresentable & Hashable, Key.RawValue == String {
    scores.max {
      if $0.value != $1.value { return $0.value < $1.value }
      return $0.key.rawValue > $1.key.rawValue
    }?.key ?? fallback
  }

  private func personalityTarget(
    owner: OwnerAffinityProfile,
    memories: [PersonalizationMemory]
  ) -> MoriPersonalityProfile {
    let hasRhythm = memories.contains {
      if case .rhythm = $0.subject { return true }
      return false
    }
    let hasExpression = memories.contains {
      if case .expression = $0.subject { return true }
      return false
    }

    let energyTarget: Double
    if hasRhythm {
      switch owner.companionshipRhythm {
      case .quiet: energyTarget = 0.3
      case .balanced: energyTarget = 0.5
      case .lively: energyTarget = 0.75
      }
    } else {
      energyTarget = MoriPersonalityProfile.original.energy
    }

    let playfulnessTarget: Double
    let brevityTarget: Double
    if hasExpression {
      switch owner.preferredExpression {
      case .gentle:
        playfulnessTarget = 0.45
        brevityTarget = 0.4
      case .concise:
        playfulnessTarget = 0.35
        brevityTarget = 0.8
      case .playful:
        playfulnessTarget = 0.8
        brevityTarget = 0.45
      }
    } else {
      playfulnessTarget = MoriPersonalityProfile.original.playfulness
      brevityTarget = MoriPersonalityProfile.original.brevity
    }

    return MoriPersonalityProfile(
      energy: energyTarget,
      playfulness: playfulnessTarget,
      brevity: brevityTarget,
      activityAffinities: owner.activityAffinities,
      interestAffinities: owner.interestAffinities
    )
  }

  private func adapt(
    _ mori: MoriPersonalityProfile,
    toward target: MoriPersonalityProfile,
    maximumStep: Double
  ) -> MoriPersonalityProfile {
    return MoriPersonalityProfile(
      energy: stepped(mori.energy, toward: target.energy, maximumStep: maximumStep),
      playfulness: stepped(
        mori.playfulness,
        toward: target.playfulness,
        maximumStep: maximumStep
      ),
      brevity: stepped(mori.brevity, toward: target.brevity, maximumStep: maximumStep),
      activityAffinities: stepped(
        mori.activityAffinities,
        toward: target.activityAffinities,
        maximumStep: maximumStep
      ),
      interestAffinities: stepped(
        mori.interestAffinities,
        toward: target.interestAffinities,
        maximumStep: maximumStep
      )
    )
  }

  private func stepped(
    _ value: Double,
    toward target: Double,
    maximumStep: Double
  ) -> Double {
    let difference = target - value
    if abs(difference) <= maximumStep + 0.000_000_001 { return target }
    let delta = PersonalizationMemory.clamp(
      difference,
      to: -maximumStep...maximumStep
    )
    return value + delta
  }

  private func stepped<Key>(
    _ values: [Key: Double],
    toward targets: [Key: Double],
    maximumStep: Double
  ) -> [Key: Double] where Key: Hashable {
    var output = values
    for key in Set(values.keys).union(targets.keys) {
      let updated = stepped(
        values[key] ?? 0,
        toward: targets[key] ?? 0,
        maximumStep: maximumStep
      )
      if abs(updated) < 0.001 {
        output.removeValue(forKey: key)
      } else {
        output[key] = updated
      }
    }
    return output
  }

  private func memory(
    for signal: PersonalizationSignal,
    at date: Date
  ) -> PersonalizationMemory? {
    let subject: PersonalizationMemorySubject
    let affinity: Double
    let weight: Double
    let decayPerDay: Double
    let lifetimeDays: Double
    let evidenceID: String
    let source: PersonalizationEvidenceSource

    switch signal {
    case .explicitActivityPreference(let activity, let value, let id):
      subject = .activity(activity)
      affinity = value
      weight = 0.9
      decayPerDay = 0.001
      lifetimeDays = 365
      evidenceID = id
      source = .explicitPreference
    case .explicitExpressionPreference(let style, let id):
      subject = .expression(style)
      affinity = 1
      weight = 1
      decayPerDay = 0.001
      lifetimeDays = 365
      evidenceID = id
      source = .explicitPreference
    case .explicitInterest(let interest, let value, let id):
      subject = .interest(interest)
      affinity = value
      weight = 0.9
      decayPerDay = 0.001
      lifetimeDays = 365
      evidenceID = id
      source = .explicitPreference
    case .interactionRhythm(let rhythm, let sampleCount, let id):
      subject = .rhythm(rhythm)
      affinity = 1
      weight = min(0.7, 0.15 + (Double(max(1, sampleCount)) * 0.04))
      decayPerDay = 0.006
      lifetimeDays = 90
      evidenceID = id
      source = .observedInteraction
    case .verifiedWorkout(let activity, let minutes, let id):
      subject = .activity(activity)
      affinity = 1
      weight = min(0.65, 0.12 + (Double(max(0, minutes)) / 300))
      decayPerDay = 0.004
      lifetimeDays = 180
      evidenceID = id
      source = .verifiedWorkout
    case .sleepRoutine(let band, let regularity, let sampleCount, let id):
      guard sampleCount >= PersonalizationSignal.minimumSleepRoutineSampleCount else {
        return nil
      }
      subject = .sleepRoutine(band: band, regularity: regularity)
      affinity = 1
      let regularityFactor = regularity == .steady ? 1.0 : 0.8
      weight = min(0.75, (0.18 + (Double(sampleCount) * 0.035)) * regularityFactor)
      decayPerDay = 0.008
      lifetimeDays = 60
      evidenceID = id
      source = .aggregateRoutine
    }

    return PersonalizationMemory(
      subject: subject,
      affinity: affinity,
      weight: weight,
      decayPerDay: decayPerDay,
      firstObservedAt: date,
      lastReinforcedAt: date,
      expiresAt: date.addingTimeInterval(lifetimeDays * 86_400),
      evidence: [
        PersonalizationEvidence(id: evidenceID, source: source, observedAt: date)
      ]
    )
  }

  private static func memoryOrder(
    _ lhs: PersonalizationMemory,
    _ rhs: PersonalizationMemory
  ) -> Bool {
    memoryKey(lhs.subject) < memoryKey(rhs.subject)
  }

  private static func memoryKey(_ subject: PersonalizationMemorySubject) -> String {
    switch subject {
    case .activity(let value): "activity.\(value.rawValue)"
    case .expression(let value): "expression.\(value.rawValue)"
    case .interest(let value): "interest.\(value.rawValue)"
    case .rhythm(let value): "rhythm.\(value.rawValue)"
    case .sleepRoutine(let band, let regularity):
      "sleepRoutine.\(band.rawValue).\(regularity.rawValue)"
    }
  }
}
