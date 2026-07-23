import AppRuntime
import Combine
import Domain
import Foundation
import SwiftUI

enum WatchAppPhase: Equatable {
  case loading
  case onboarding
  case petIntroduction
  case ready
}

@MainActor
final class WatchAppStore: ObservableObject {
  @Published private(set) var model: WatchPresentationModel
  @Published private(set) var preferences = AppPreferences()
  @Published private(set) var phase: WatchAppPhase
  @Published private(set) var isRefreshingHealth = false
  @Published private(set) var isSavingPreferences = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var isCompletingAction = false
  @Published private(set) var actionCompleted = false
  @Published private(set) var isAdvancingStory = false
  @Published private(set) var selectedDataSource: CompanionDataSource
  @Published private(set) var notificationDestination: RuntimeNotificationDestination? = nil

  var dataMode: WatchDataMode { model.dataMode }
  var dataSourceSelectionAvailable: Bool { !hasLaunchScenarioOverride }
  private let runtime: AppleCompanionRuntime?
  private let notificationRouteObserver: RuntimeNotificationRouteObserver?
  private let launchNotificationRoute: RuntimeNotificationRoute?
  private let usesE2EOfflineRuntime: Bool
  private let hasLaunchScenarioOverride: Bool
  private var hasStarted = false
  private var latestHealth: HealthSnapshot?
  private var latestPeerValues: [String: String]?
  private var peerUpdateTask: Task<Void, Never>?
  private var notificationRouteTask: Task<Void, Never>?
  private var peerSyncRetryTask: Task<Void, Never>?
  private var mockCareTask: Task<Void, Never>?

  var touchExchangeLocalCard: TouchExchangeLocalCard {
    TouchExchangeLocalCard(
      displayName: model.isLive ? "Mori" : "Mori（演示）",
      petAssetID: preferences.selectedCharacterIDs.first
        ?? CompanionVisualCatalog.defaultCharacterID,
      outfitAssetID: preferences.selectedOutfitID,
      backgroundAssetID: preferences.selectedBackgroundID,
      socialState: preferences.publicPetSocialState
    )
  }

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    let initialModel = WatchPresentationModel.initial(arguments: arguments)
    #if DEBUG
      let touchExchangeDemoEnabled =
        arguments.contains("-UITesting")
        && arguments.contains("--touch-exchange-demo")
      let touchExchangeDemoSocialState =
        arguments.first(where: { $0.hasPrefix("--touch-exchange-social-state=") })
        .flatMap {
          PublicPetSocialStateV1(
            rawValue: $0.replacingOccurrences(
              of: "--touch-exchange-social-state=",
              with: ""
            )
          )
        } ?? .greeting
    #else
      let touchExchangeDemoEnabled = false
      let touchExchangeDemoSocialState = PublicPetSocialStateV1.greeting
    #endif
    model = initialModel
    selectedDataSource =
      initialModel.mockScenario.flatMap { CompanionDataSource(rawValue: $0.id) } ?? .mock1
    preferences = AppPreferences(
      hasCompletedOnboarding: initialModel.initialScreen != .onboarding,
      socialSharingEnabled: touchExchangeDemoEnabled,
      publicPetSocialState: touchExchangeDemoSocialState,
      selectedOutfitID: initialModel.outfitID ?? WardrobeCatalog.defaultOutfitID,
      selectedCharacterIDs: initialModel.scene.slots.map(\.characterID),
      selectedBackgroundID: initialModel.scene.backgroundID
    )
    hasLaunchScenarioOverride = initialModel.dataMode != .live
    if hasLaunchScenarioOverride {
      phase =
        switch initialModel.initialScreen {
        case .onboarding: .onboarding
        case .petIntroduction: .petIntroduction
        case .petHome: .ready
        }
    } else {
      phase = .loading
    }
    #if DEBUG
      let runtimeConfiguration = Self.runtimeConfiguration(arguments: arguments)
    #else
      let runtimeConfiguration = Self.productionRuntimeConfiguration()
    #endif
    runtime = AppleCompanionRuntime(
      source: .watch,
      storageDirectory: runtimeConfiguration.storageDirectory,
      preferencesKey: runtimeConfiguration.preferencesKey,
      dataSourceKey: runtimeConfiguration.dataSourceKey,
      peerSyncEnabled: runtimeConfiguration.peerSyncEnabled
    )
    notificationRouteObserver =
      hasLaunchScenarioOverride ? nil : RuntimeNotificationRouteObserver()
    #if DEBUG
      launchNotificationRoute =
        arguments.contains("-UITesting") ? Self.notificationRoute(from: arguments) : nil
    #else
      launchNotificationRoute = nil
    #endif
    usesE2EOfflineRuntime = !runtimeConfiguration.peerSyncEnabled
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    guard !hasLaunchScenarioOverride else { return }
    observeNotificationRoutes()
    if let launchNotificationRoute {
      handleNotificationRoute(launchNotificationRoute)
    }
    guard let runtime else { return }
    do {
      preferences = try await runtime.loadPreferences()
      selectedDataSource = await runtime.loadDataSourceSelection()
      latestPeerValues = Self.peerValues(from: preferences)
      guard preferences.hasCompletedOnboarding else {
        #if DEBUG
          if selectedDataSource.isMock {
            model = WatchPresentationModel.demo(selectedDataSource)
          }
        #endif
        phase = .onboarding
        statusMessage = "先认识 Mori；不会自动请求健康或通知权限"
        return
      }
      phase = .ready
      await applySelectedDataSource(requestAccessIfNeeded: false)
      guard !usesE2EOfflineRuntime else { return }
      beginPeerUpdates(runtime: runtime)
      retryPeerSyncInBackground(runtime: runtime)
    } catch {
      phase = .ready
      statusMessage = "载入失败，请稍后重试"
    }
  }

  private func beginPeerUpdates(runtime: AppleCompanionRuntime) {
    guard peerUpdateTask == nil else { return }
    peerUpdateTask = Task { [weak self] in
      let peerUpdates = await runtime.peerValueUpdates()
      if let self {
        if let latestPeerValues = await runtime.latestPeerValues() {
          await self.receivePeerValues(latestPeerValues, runtime: runtime)
        }
      }
      for await values in peerUpdates {
        guard let self else { return }
        await self.receivePeerValues(values, runtime: runtime)
      }
    }
  }

  /// A previous process may have reached WatchConnectivity before its durable acknowledgement
  /// was written. Retrying the exact state is idempotent at the transport boundary.
  private func retryPeerSyncInBackground(runtime: AppleCompanionRuntime) {
    guard peerSyncRetryTask == nil else { return }
    peerSyncRetryTask = Task { [weak self] in
      _ = try? await runtime.retryPeerSync()
      self?.peerSyncRetryTask = nil
    }
  }

  func connectHealth() async {
    await selectDataSource(.healthKit)
  }

  func selectDataSource(_ source: CompanionDataSource) async {
    guard !hasLaunchScenarioOverride else { return }
    mockCareTask?.cancel()
    selectedDataSource = source
    _ = await runtime?.saveDataSourceSelection(source)
    await applySelectedDataSource(requestAccessIfNeeded: source == .healthKit)
  }

  func completeOnboarding() async {
    guard phase == .onboarding, !isSavingPreferences else { return }
    if hasLaunchScenarioOverride {
      preferences.hasCompletedOnboarding = true
      phase = .ready
      statusMessage = "Mori 已准备好；Mock 不会请求系统权限"
      return
    }
    guard let runtime else {
      preferences.hasCompletedOnboarding = true
      phase = .ready
      statusMessage = "Mori 已准备好；Mock 不会请求系统权限"
      return
    }

    isSavingPreferences = true
    preferences.hasCompletedOnboarding = true
    do {
      _ = try await runtime.savePreferences(preferences)
      phase = .ready
      await applySelectedDataSource(requestAccessIfNeeded: false)
      isSavingPreferences = false
      statusMessage =
        selectedDataSource.isMock
        ? "Mori 已准备好；\(selectedDataSource.displayName) 已载入"
        : "Mori 已准备好；健康数据可以稍后再连接"
      guard !usesE2EOfflineRuntime else { return }
      beginPeerUpdates(runtime: runtime)
    } catch {
      preferences.hasCompletedOnboarding = false
      isSavingPreferences = false
      statusMessage = "暂时没能保存，请再试一次"
    }
  }

  func completePetIntroduction() {
    guard phase == .petIntroduction else { return }
    phase = .ready
    statusMessage = "Mori 记住你了；今天不需要一次做完所有事"
  }

  func refreshHealth(requestAccessIfNeeded: Bool = false) async {
    guard selectedDataSource == .healthKit, let runtime, !isRefreshingHealth else { return }
    isRefreshingHealth = true
    defer { isRefreshingHealth = false }
    do {
      let refresh = try await runtime.refreshHealth(
        requestAccessIfNeeded: requestAccessIfNeeded
      )
      guard selectedDataSource == .healthKit else { return }
      latestHealth = refresh.health
      let trend = try await runtime.personalHealthTrend()
      guard selectedDataSource == .healthKit else { return }
      model = .live(
        companion: refresh.companion,
        health: refresh.health,
        trend: trend,
        peerValues: latestPeerValues
      )
      statusMessage = refresh.health.hasAnyMetric ? "健康数据已更新" : "没有可用数据，不会扣除成长值"
    } catch {
      guard selectedDataSource == .healthKit else { return }
      statusMessage = "健康数据暂时不可用"
    }
  }

  @discardableResult
  func completeSuggestedAction() async -> Bool {
    guard selectedDataSource == .healthKit, let runtime, !isCompletingAction else {
      return false
    }
    isCompletingAction = true
    defer { isCompletingAction = false }
    do {
      let outcome = try await runtime.completeSuggestedHabit()
      let trend = try await runtime.personalHealthTrend()
      model = .live(
        companion: outcome.state,
        health: latestHealth,
        trend: trend,
        peerValues: latestPeerValues
      )
      switch outcome {
      case .completed:
        actionCompleted = true
        statusMessage = "今天的小行动已记下；奖励只结算一次"
      case .alreadyCompletedToday:
        actionCompleted = true
        statusMessage = "今天已经完成过一个小行动，继续休息也很好"
      }
      return true
    } catch {
      statusMessage = "互动暂时没能保存"
      return false
    }
  }

  func interact(with animation: WatchCharacterAnimation) async {
    if selectedDataSource.isMock || hasLaunchScenarioOverride {
      if model.mockScenario?.id == CompanionDataSource.mock2.fixtureID {
        model = model.resolvingMockRelationship()
        actionCompleted = true
      }
      statusMessage = animation == .touchHead ? "Mori 开心地眨了眨眼" : "Mori 转过身回应了你"
      return
    }
    guard let runtime else { return }
    do {
      let state = try await runtime.recordPetInteraction(kind: animation.rawValue)
      let trend = try await runtime.personalHealthTrend()
      model = .live(
        companion: state,
        health: latestHealth,
        trend: trend,
        peerValues: latestPeerValues
      )
      statusMessage = animation == .touchHead ? "Mori 开心地眨了眨眼" : "Mori 转过身回应了你"
    } catch {
      statusMessage = "这次互动没能保存，但 Mori 已经看见你了"
    }
  }

  @discardableResult
  func advanceMainStory() async -> Bool {
    guard selectedDataSource == .healthKit, let runtime, !isAdvancingStory else {
      return false
    }
    isAdvancingStory = true
    defer { isAdvancingStory = false }
    do {
      let outcome = try await runtime.completeTodayMainStory()
      let trend = try await runtime.personalHealthTrend()
      model = .live(
        companion: outcome.state,
        health: latestHealth,
        trend: trend,
        peerValues: latestPeerValues
      )
      switch outcome {
      case .completed:
        statusMessage = "今日主线已推进，获得 10 点世界经验"
      case .alreadyCompletedToday:
        statusMessage = "今天的主线已经完成，明天继续"
      case .storyComplete:
        statusMessage = "七日主线已完成，可以自由探索支线"
      }
      return true
    } catch {
      statusMessage = "主线进度暂时没能保存"
      return false
    }
  }

  private func rebuildModel() async {
    guard selectedDataSource == .healthKit else { return }
    guard let runtime else { return }
    do {
      let state = try await runtime.currentState()
      actionCompleted = state.completedHabitDays.contains(
        LocalDay.containing(Date(), in: .current)
      )
      let trend = try await runtime.personalHealthTrend()
      model = .live(
        companion: state,
        health: latestHealth,
        trend: trend,
        peerValues: latestPeerValues
      )
    } catch {
      statusMessage = "同步状态暂时无法显示"
    }
  }

  private func loadLocalExperience() async throws {
    guard let runtime else { return }
    let state = try await runtime.currentState()
    actionCompleted = state.completedHabitDays.contains(
      LocalDay.containing(Date(), in: .current)
    )
    let trend = try await runtime.personalHealthTrend()
    model = .live(
      companion: state,
      health: latestHealth,
      trend: trend,
      peerValues: latestPeerValues
    )
  }

  private func applySelectedDataSource(requestAccessIfNeeded: Bool) async {
    mockCareTask?.cancel()
    actionCompleted = false
    if selectedDataSource.isMock {
      #if DEBUG
        model = WatchPresentationModel.demo(selectedDataSource)
        phase = .ready
        statusMessage = "\(selectedDataSource.displayName) 已载入"
        scheduleMockCareIfNeeded()
      #else
        selectedDataSource = .healthKit
        await refreshHealth(requestAccessIfNeeded: requestAccessIfNeeded)
      #endif
      return
    }
    do {
      preferences = try await runtime?.loadPreferences() ?? AppPreferences()
      latestPeerValues = Self.peerValues(from: preferences)
      try await loadLocalExperience()
    } catch {
      model = .liveNoData()
    }
    await refreshHealth(requestAccessIfNeeded: requestAccessIfNeeded)
  }

  private func scheduleMockCareIfNeeded() {
    guard selectedDataSource == .mock2 else { return }
    mockCareTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(60))
      guard !Task.isCancelled, let self, self.selectedDataSource == .mock2 else { return }
      self.model = self.model.addingMockCareMessage()
      self.statusMessage = "Mori 给你留了一封轻轻的来信"
    }
  }

  private func applyPeerValues(
    _ values: [String: String],
    shouldReloadDataSource: Bool
  ) async {
    if let rawValue = values["dataSource"],
      let incoming = CompanionDataSource(rawValue: rawValue),
      shouldReloadDataSource
    {
      selectedDataSource = incoming
      await applySelectedDataSource(requestAccessIfNeeded: false)
      return
    }
    await rebuildModel()
  }

  private func receivePeerValues(
    _ values: [String: String],
    runtime: AppleCompanionRuntime
  ) async {
    do {
      let shouldReloadDataSource = try await runtime.applyPeerPreferences(values)
      preferences = try await runtime.loadPreferences()
      // Presentation consumes the validated, merged management subset. Raw or partial peer
      // payloads must never reset a valid local character or scene to a default.
      latestPeerValues = Self.peerValues(from: preferences)
      await applyPeerValues(values, shouldReloadDataSource: shouldReloadDataSource)
    } catch {
      statusMessage = "配对设置暂时无法同步"
    }
  }

  private func observeNotificationRoutes() {
    guard let notificationRouteObserver else { return }
    let routes = notificationRouteObserver.routes()
    notificationRouteTask = Task { [weak self] in
      for await route in routes {
        guard let self else { return }
        self.handleNotificationRoute(route)
      }
    }
  }

  private func handleNotificationRoute(_ value: RuntimeNotificationRoute) {
    guard let destination = NotificationRouteCoordinator().destination(for: value) else { return }
    notificationDestination = destination
    switch destination {
    case .recoveryMessage:
      statusMessage = "Mori：今天可以慢一点，由你决定是否回应"
    case .activityMessage:
      statusMessage = "Mori：要不要一起走两分钟？不完成也不会失去什么"
    case .careMessage:
      statusMessage = "Mori：不用解释，我可以陪你安静待一会儿"
    }
  }

  func dismissNotificationDestination() {
    notificationDestination = nil
  }

  private struct RuntimeConfiguration {
    let storageDirectory: URL
    let preferencesKey: String
    let dataSourceKey: String
    let peerSyncEnabled: Bool
  }

  private static func peerValues(from preferences: AppPreferences) -> [String: String] {
    [
      "outfit": preferences.selectedOutfitID,
      "characters": CompanionVisualCatalog.normalizedCharacterIDs(
        preferences.selectedCharacterIDs
      ).joined(separator: ","),
      "background": CompanionVisualCatalog.normalizedBackgroundID(
        preferences.selectedBackgroundID
      ),
    ]
  }

  private static func productionRuntimeConfiguration() -> RuntimeConfiguration {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("WatchCompanionWatch")
    return RuntimeConfiguration(
      storageDirectory: base,
      preferencesKey: "app.preferences.v1",
      dataSourceKey: "app.data-source.v1",
      peerSyncEnabled: true
    )
  }

  #if DEBUG
    private static func notificationRoute(from arguments: [String]) -> RuntimeNotificationRoute? {
      guard
        let value = arguments.first(where: { $0.hasPrefix("--notification-route=") })?
          .replacingOccurrences(of: "--notification-route=", with: ""),
        !value.isEmpty
      else { return nil }
      return RuntimeNotificationRoute(route: value)
    }

    private static func runtimeConfiguration(arguments: [String]) -> RuntimeConfiguration {
      let base =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("WatchCompanionWatch")
      let usesUITesting = arguments.contains("-UITesting")
      let peerSyncEnabled =
        !(usesUITesting && arguments.contains("--e2e-offline-runtime"))
      guard
        usesUITesting,
        let identifier = arguments.first(where: { $0.hasPrefix("--e2e-storage-id=") })?
          .replacingOccurrences(of: "--e2e-storage-id=", with: ""),
        !identifier.isEmpty,
        identifier.allSatisfy({
          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
        )
      else {
        return RuntimeConfiguration(
          storageDirectory: base,
          preferencesKey: "app.preferences.v1",
          dataSourceKey: "app.data-source.v1",
          peerSyncEnabled: peerSyncEnabled
        )
      }

      let directory =
        base
        .appendingPathComponent("UITests", isDirectory: true)
        .appendingPathComponent(identifier, isDirectory: true)
      if arguments.contains("--reset-e2e-storage") {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: "app.preferences.v1.uitests.\(identifier)")
        UserDefaults.standard.removeObject(forKey: "app.data-source.v1.uitests.\(identifier)")
        UserDefaults.standard.removeObject(
          forKey: "app.data-source.v1.uitests.\(identifier).selection-token"
        )
      }
      if let seededSource = e2eDataSource(arguments: arguments) {
        UserDefaults.standard.set(
          seededSource.rawValue,
          forKey: "app.data-source.v1.uitests.\(identifier)"
        )
      }
      return RuntimeConfiguration(
        storageDirectory: directory,
        preferencesKey: "app.preferences.v1.uitests.\(identifier)",
        dataSourceKey: "app.data-source.v1.uitests.\(identifier)",
        peerSyncEnabled: peerSyncEnabled
      )
    }

    private static func e2eDataSource(arguments: [String]) -> CompanionDataSource? {
      guard
        let rawValue = arguments.first(where: { $0.hasPrefix("--e2e-data-source=") })?
          .replacingOccurrences(of: "--e2e-data-source=", with: "")
      else { return nil }
      return CompanionDataSource(rawValue: rawValue)
    }
  #endif
}
