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
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) -> Self {
    #if DEBUG
      switch debugScenarioSelection(arguments: arguments) {
      case .none:
        return liveNoData()
      case .scenario(let seed):
        return mock(seed: seed)
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
      sealedMemories: []
    )
  }

  static func liveNoData() -> Self {
    live(companion: CompanionState(), health: nil)
  }

  #if DEBUG
    static func demo(_ source: CompanionDataSource) -> Self {
      guard let fixtureID = source.fixtureID else { return liveNoData() }
      switch debugScenarioSelection(
        arguments: ["--mock-scenario=\(fixtureID)"],
        enabled: true
      ) {
      case .scenario(let seed):
        return mock(seed: seed)
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
      sealedMemories: []
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

    private static func mock(seed: DebugScenarioSeed) -> Self {
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
            healthSnapshots: seed.healthSnapshots
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
        sealedMemories: []
      )
    }
  #endif
}

struct PhoneMockScenario: Equatable {
  let id: String
  let displayName: String
  let evaluatedAt: Date
  let timeZoneIdentifier: String
  let healthSnapshots: [HealthSnapshot]

  var now: Date { evaluatedAt }
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
