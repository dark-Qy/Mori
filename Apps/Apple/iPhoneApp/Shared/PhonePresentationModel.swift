import AppRuntime
import Domain
import Foundation

#if DEBUG
  import DebugScenarioSupport
#endif

enum PhoneDataMode: Equatable {
  case live
  case mock(PhoneMockScenario)
  case invalidMock(String)
}

/// Product-facing iPhone state for the Mori rebuild.
///
/// Legacy levels, vitality, stories, health trends, and dashboard verdicts
/// intentionally stop at the compatibility runtime and never enter this model.
struct PhonePresentationModel {
  let dataMode: PhoneDataMode
  let initialScreen: PhoneInitialScreen
  let wardrobe: PhoneWardrobePresentation
  let metrics: [PhoneMetric]
  let sealedMemories: [PhoneMemoryPresentation]
  let dailyMomentCollection: PhoneDailyMomentCollection?

  var mockScenario: PhoneMockScenario? {
    guard case .mock(let scenario) = dataMode else { return nil }
    return scenario
  }

  var isLive: Bool { dataMode == .live }

  var allowsInteraction: Bool {
    if case .invalidMock = dataMode { return false }
    return true
  }

  var sleepMinutes: Int? {
    metrics.first(where: { $0.id == "sleep" })?.numericValue
  }

  var stepCount: Int? {
    metrics.first(where: { $0.id == "steps" })?.numericValue
  }

  static func initial(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    now: Date = Date()
  ) -> Self {
    #if DEBUG
      switch debugScenarioSelection(arguments: arguments) {
      case .none:
        return liveNoData()
      case .scenario(let seed):
        return mock(seed: seed, now: now)
      case .invalid(let requestedID):
        return invalidMock(requestedID)
      }
    #else
      return liveNoData()
    #endif
  }

  static func live(
    companion: CompanionState,
    health: HealthSnapshot?
  ) -> Self {
    PhonePresentationModel(
      dataMode: .live,
      initialScreen: .mori,
      wardrobe: PhoneWardrobePresentation(
        selectedOutfitID: companion.pet.equippedOutfitID ?? "default",
        unlockedOutfitIDs: [],
        previewOutfitID: companion.pet.equippedOutfitID ?? "default",
        peerSyncAvailable: nil
      ),
      metrics: [
        PhoneMetric(id: "sleep", numericValue: health?.sleepMinutes),
        PhoneMetric(id: "steps", numericValue: health?.steps),
      ],
      sealedMemories: [],
      dailyMomentCollection: nil
    )
  }

  static func liveNoData() -> Self {
    live(companion: CompanionState(), health: nil)
  }

  #if DEBUG
    static func demo(
      _ source: CompanionDataSource,
      now: Date = Date()
    ) -> Self {
      guard let fixtureID = source.fixtureID else { return liveNoData() }
      switch debugScenarioSelection(
        arguments: ["--mock-scenario=\(fixtureID)"],
        enabled: true
      ) {
      case .scenario(let seed):
        return mock(seed: seed, now: now)
      case .none, .invalid:
        return invalidMock(fixtureID)
      }
    }
  #endif

  private static func invalidMock(_ value: String) -> Self {
    let base = liveNoData()
    return PhonePresentationModel(
      dataMode: .invalidMock(value),
      initialScreen: .mori,
      wardrobe: .unavailable,
      metrics: base.metrics,
      sealedMemories: [],
      dailyMomentCollection: nil
    )
  }

  #if DEBUG
    private static func debugScenarioSelection(
      arguments: [String],
      enabled: Bool? = nil
    ) -> DebugScenarioSelection {
      DebugScenarioCatalog.selection(
        from: arguments,
        enabled: enabled ?? arguments.contains("-UITesting")
      ) { identifier in
        guard
          let url = Bundle.main.url(
            forResource: identifier,
            withExtension: "json",
            subdirectory: "MockScenarios"
          )
        else {
          return nil
        }
        return try? Data(contentsOf: url)
      }
    }

    private static func mock(
      seed: DebugScenarioSeed,
      now: Date
    ) -> Self {
      let initialScreen: PhoneInitialScreen =
        switch seed.primaryState {
        case .onboarding:
          .onboarding
        case .wardrobe:
          .collection
        case .petIntroduction, .petHome:
          .mori
        }
      return PhonePresentationModel(
        dataMode: .mock(
          PhoneMockScenario(
            id: seed.id,
            displayName: seed.displayName,
            evaluatedAt: seed.now,
            timeZoneIdentifier: seed.timeZoneIdentifier,
            characterID: seed.characterID,
            healthSnapshots: seed.healthSnapshots,
            reactiveSceneTimeline: seed.reactiveSceneTimeline
          )
        ),
        initialScreen: initialScreen,
        wardrobe: PhoneWardrobePresentation(
          selectedOutfitID: seed.selectedOutfitID ?? "default",
          unlockedOutfitIDs: seed.unlockedOutfitIDs,
          previewOutfitID: seed.previewOutfitID
            ?? seed.selectedOutfitID
            ?? "default",
          peerSyncAvailable: seed.syncAvailable
        ),
        metrics: [
          PhoneMetric(
            id: "sleep",
            numericValue: seed.healthSnapshot.sleepMinutes
          ),
          PhoneMetric(
            id: "steps",
            numericValue: seed.healthSnapshot.steps
          ),
        ],
        sealedMemories: [],
        dailyMomentCollection: seed.dailyMomentCollection.map {
          PhoneDailyMomentCollection(
            dayID: localDayID(
              for: now,
              timeZoneIdentifier: seed.timeZoneIdentifier
            ),
            characterID: seed.characterID,
            isSealed: false,
            moments: $0.moments.map {
              PhoneDailyMomentPresentation(
                id: $0.id,
                timeLabel: $0.timeLabel,
                title: $0.title,
                body: $0.body,
                sceneID: $0.sceneID,
                animationID: $0.animationID
              )
            }
          )
        }
      )
    }

    private static func localDayID(
      for date: Date,
      timeZoneIdentifier: String
    ) -> String {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone =
        TimeZone(identifier: timeZoneIdentifier) ?? .current
      let components = calendar.dateComponents(
        [.year, .month, .day],
        from: date
      )
      return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0
      )
    }
  #endif

  func replacingSealedMemories(
    _ memories: [PhoneMemoryPresentation],
    dailyMomentCollection replacement: PhoneDailyMomentCollection? = nil
  ) -> Self {
    PhonePresentationModel(
      dataMode: dataMode,
      initialScreen: initialScreen,
      wardrobe: wardrobe,
      metrics: metrics,
      sealedMemories: memories,
      dailyMomentCollection: replacement ?? dailyMomentCollection
    )
  }
}

struct PhoneMockScenario: Equatable {
  let id: String
  let displayName: String
  let evaluatedAt: Date
  let timeZoneIdentifier: String
  let characterID: String
  let healthSnapshots: [HealthSnapshot]

  var now: Date { evaluatedAt }
  #if DEBUG
    let reactiveSceneTimeline: DebugReactiveSceneTimeline?
  #endif
}

struct PhoneDailyMomentCollection: Equatable, Identifiable {
  var id: String { dayID }
  let dayID: String
  let characterID: String
  let isSealed: Bool
  let moments: [PhoneDailyMomentPresentation]
}

struct PhoneDailyMomentPresentation: Equatable, Identifiable {
  let id: String
  let timeLabel: String
  let title: String
  let body: String
  let sceneID: String
  let animationID: String
}

enum PhoneInitialScreen: Equatable {
  case onboarding
  case mori
  case collection
}

struct PhoneWardrobePresentation: Equatable {
  let selectedOutfitID: String
  let unlockedOutfitIDs: Set<String>
  let previewOutfitID: String
  let peerSyncAvailable: Bool?

  static let phaseOneDefault = PhoneWardrobePresentation(
    selectedOutfitID: "default",
    unlockedOutfitIDs: [
      "default", "scarf", "leaf", "star", "drop", "soccer_scarf",
    ],
    previewOutfitID: "default",
    peerSyncAvailable: nil
  )

  static let unavailable = PhoneWardrobePresentation(
    selectedOutfitID: "default",
    unlockedOutfitIDs: [],
    previewOutfitID: "default",
    peerSyncAvailable: false
  )
}

struct PhoneMetric: Identifiable {
  let id: String
  let numericValue: Int?
}
