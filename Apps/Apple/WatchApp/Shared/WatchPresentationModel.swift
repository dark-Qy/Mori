import AppRuntime
import Domain
import Foundation
import SwiftUI

#if DEBUG
  import DebugScenarioSupport
#endif

enum WatchDataMode: Equatable {
  case live
  case mock(WatchMockScenario)
  case invalidMock(String)
}

/// Presentation-only state for the rebuilt Watch surfaces.
///
/// Legacy level, vitality, story, trend, and health-judgment fields do not
/// belong to the Mori product and intentionally stop at the old runtime.
struct WatchPresentationModel {
  let dataMode: WatchDataMode
  let initialScreen: WatchInitialScreen
  let outfitID: String?
  let scene: WatchScenePresentation
  let metrics: [WatchMetric]
  let messages: [WatchMessage]

  var mockScenario: WatchMockScenario? {
    guard case .mock(let scenario) = dataMode else { return nil }
    return scenario
  }

  var invalidMockID: String? {
    guard case .invalidMock(let value) = dataMode else { return nil }
    return value
  }

  var isLive: Bool { dataMode == .live }
  var allowsInteraction: Bool {
    if case .invalidMock = dataMode { return false }
    return true
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
    health: HealthSnapshot?,
    peerValues: [String: String]? = nil
  ) -> Self {
    WatchPresentationModel(
      dataMode: .live,
      initialScreen: .petHome,
      outfitID: peerValues?["outfit"] ?? companion.pet.equippedOutfitID,
      scene: WatchScenePresentation.make(
        peerValues: peerValues,
        mood: companion.pet.mood
      ),
      metrics: [
        WatchMetric(
          id: "recovery",
          numericValue: health?.sleepMinutes
        ),
        WatchMetric(
          id: "activity",
          numericValue: health?.steps
        ),
      ],
      // Production letters must come from synchronized LetterRecord values.
      messages: []
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

    func resolvingMockRelationship() -> Self {
      guard CompanionDataSource.isPeerExchangeFixtureID(mockScenario?.id) else {
        return self
      }
      return replacing(scene: scene.applying(mood: .curious))
    }

    func addingMockCareMessage() -> Self {
      guard CompanionDataSource.isPeerExchangeFixtureID(mockScenario?.id) else {
        return self
      }
      let care = WatchMessage(
        id: "mock2-care",
        title: "要不要安静待一会儿？",
        body: "刚才是不是有点累？不用解释，我可以在这里陪你。",
        relativeTime: "刚刚",
        symbol: "heart.text.square.fill",
        tint: AdventurePalette.rose,
        isUnread: true
      )
      return replacing(
        messages: [care] + messages.filter { $0.id != care.id }
      )
    }
  #endif

  func selectingCharacter(_ id: String) -> Self {
    replacing(scene: scene.selectingCharacter(id))
  }

  private static func invalidMock(_ value: String) -> Self {
    let base = liveNoData()
    return WatchPresentationModel(
      dataMode: .invalidMock(value),
      initialScreen: .petHome,
      outfitID: nil,
      scene: base.scene,
      metrics: base.metrics,
      messages: []
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
      let base = live(
        companion: seed.companionState,
        health: seed.healthSnapshot,
        peerValues: seed.selectedOutfitID.map { ["outfit": $0] }
      )
      let scenario = WatchMockScenario(
        id: seed.id,
        displayName: seed.displayName,
        reactiveSceneTimeline: seed.reactiveSceneTimeline
      )
      let initialScreen: WatchInitialScreen =
        switch seed.primaryState {
        case .onboarding:
          .onboarding
        case .petIntroduction:
          .petIntroduction
        case .petHome, .wardrobe:
          .petHome
        }
      return WatchPresentationModel(
        dataMode: .mock(scenario),
        initialScreen: initialScreen,
        outfitID: base.outfitID,
        scene: base.scene,
        metrics: base.metrics,
        messages: WatchMessage.samples
      )
    }
  #endif

  private func replacing(
    scene: WatchScenePresentation? = nil,
    messages: [WatchMessage]? = nil
  ) -> Self {
    WatchPresentationModel(
      dataMode: dataMode,
      initialScreen: initialScreen,
      outfitID: outfitID,
      scene: scene ?? self.scene,
      metrics: metrics,
      messages: messages ?? self.messages
    )
  }
}

enum WatchInitialScreen: Equatable {
  case onboarding
  case petIntroduction
  case petHome
}

struct WatchMockScenario: Equatable {
  let id: String
  let displayName: String
  #if DEBUG
    let reactiveSceneTimeline: DebugReactiveSceneTimeline?
  #endif
}

struct WatchMetric: Identifiable {
  let id: String
  let numericValue: Int?
}

struct WatchMessage: Identifiable {
  let id: String
  let title: String
  let body: String
  let relativeTime: String
  let symbol: String
  let tint: Color
  let isUnread: Bool

  static let samples = [
    WatchMessage(
      id: "pause",
      title: "我在这里",
      body: "想停一会儿的话，我可以陪你一起看看窗外。",
      relativeTime: "刚刚",
      symbol: "cup.and.heat.waves.fill",
      tint: AdventurePalette.gold,
      isUnread: true
    ),
    WatchMessage(
      id: "rhythm",
      title: "一起看风景",
      body: "下次抬腕时，我还会在这片花溪旁等你。",
      relativeTime: "2 小时前",
      symbol: "sparkles",
      tint: AdventurePalette.mint,
      isUnread: true
    ),
    WatchMessage(
      id: "morning",
      title: "早安，同行者",
      body: "新的一天开始了，我们慢慢走也可以。",
      relativeTime: "今天 08:10",
      symbol: "sunrise.fill",
      tint: AdventurePalette.blue,
      isUnread: false
    ),
  ]
}
