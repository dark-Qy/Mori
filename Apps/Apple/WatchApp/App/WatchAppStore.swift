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
  @Published private(set) var notificationDestination: RuntimeNotificationDestination? = nil

  let dataMode: WatchDataMode
  private let runtime: AppleCompanionRuntime?
  private let notificationRouteObserver: RuntimeNotificationRouteObserver?
  private let launchNotificationRoute: RuntimeNotificationRoute?
  private let usesE2EOfflineRuntime: Bool
  private var hasStarted = false
  private var latestHealth: HealthSnapshot?
  private var latestPeerValues: [String: String]?
  private var peerUpdateTask: Task<Void, Never>?
  private var notificationRouteTask: Task<Void, Never>?
  private var peerSyncRetryTask: Task<Void, Never>?

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    let initialModel = WatchPresentationModel.initial(arguments: arguments)
    dataMode = initialModel.dataMode
    model = initialModel
    preferences = AppPreferences(
      hasCompletedOnboarding: initialModel.initialScreen != .onboarding,
      selectedOutfitID: initialModel.outfitID ?? WardrobeCatalog.defaultOutfitID
    )
    if dataMode == .live {
      phase = .loading
    } else {
      phase =
        switch initialModel.initialScreen {
        case .onboarding: .onboarding
        case .petIntroduction: .petIntroduction
        case .petHome: .ready
        }
    }
    #if DEBUG
      let runtimeConfiguration = Self.runtimeConfiguration(arguments: arguments)
    #else
      let runtimeConfiguration = Self.productionRuntimeConfiguration()
    #endif
    runtime =
      dataMode == .live
      ? AppleCompanionRuntime(
        source: .watch,
        storageDirectory: runtimeConfiguration.storageDirectory,
        preferencesKey: runtimeConfiguration.preferencesKey,
        peerSyncEnabled: runtimeConfiguration.peerSyncEnabled
      )
      : nil
    notificationRouteObserver = dataMode == .live ? RuntimeNotificationRouteObserver() : nil
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
    observeNotificationRoutes()
    if let launchNotificationRoute {
      handleNotificationRoute(launchNotificationRoute)
    }
    guard let runtime else { return }
    do {
      preferences = try await runtime.loadPreferences()
      latestPeerValues = ["outfit": preferences.selectedOutfitID]
      guard preferences.hasCompletedOnboarding else {
        phase = .onboarding
        statusMessage = "先认识 Mori；不会自动请求健康或通知权限"
        return
      }
      phase = .ready
      try await loadLocalExperience()
      statusMessage =
        usesE2EOfflineRuntime
        ? "本地进度已载入；离线测试不会读取健康数据"
        : "本地进度已载入，健康数据正在更新"
      guard !usesE2EOfflineRuntime else { return }
      beginPeerUpdates(runtime: runtime)
      retryPeerSyncInBackground(runtime: runtime)
      await refreshHealth(requestAccessIfNeeded: false)
    } catch {
      phase = .ready
      statusMessage = "载入失败，请稍后重试"
    }
  }

  private func beginPeerUpdates(runtime: AppleCompanionRuntime) {
    peerUpdateTask = Task { [weak self] in
      let peerUpdates = await runtime.peerValueUpdates()
      if let self {
        self.latestPeerValues = await runtime.latestPeerValues()
        if let latestPeerValues = self.latestPeerValues {
          try? await runtime.applyPeerPreferences(latestPeerValues)
          await self.rebuildModel()
        }
      }
      for await values in peerUpdates {
        guard let self else { return }
        self.latestPeerValues = values
        try? await runtime.applyPeerPreferences(values)
        await self.rebuildModel()
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
    await refreshHealth(requestAccessIfNeeded: true)
  }

  func completeOnboarding() async {
    guard phase == .onboarding, !isSavingPreferences else { return }
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
      try await loadLocalExperience()
      isSavingPreferences = false
      statusMessage = "Mori 已准备好；健康数据可以稍后再连接"
      guard !usesE2EOfflineRuntime else { return }
      beginPeerUpdates(runtime: runtime)
      await refreshHealth(requestAccessIfNeeded: false)
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
    guard let runtime, !isRefreshingHealth else { return }
    isRefreshingHealth = true
    defer { isRefreshingHealth = false }
    do {
      let refresh = try await runtime.refreshHealth(
        requestAccessIfNeeded: requestAccessIfNeeded
      )
      latestHealth = refresh.health
      let trend = try await runtime.personalHealthTrend()
      model = .live(
        companion: refresh.companion,
        health: refresh.health,
        trend: trend,
        peerValues: latestPeerValues
      )
      statusMessage = refresh.health.hasAnyMetric ? "健康数据已更新" : "没有可用数据，不会扣除成长值"
    } catch {
      statusMessage = "健康数据暂时不可用"
    }
  }

  func completeSuggestedAction() async {
    guard let runtime, !isCompletingAction else { return }
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
    } catch {
      statusMessage = "互动暂时没能保存"
    }
  }

  func advanceMainStory() async {
    guard let runtime, !isAdvancingStory else { return }
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
    } catch {
      statusMessage = "主线进度暂时没能保存"
    }
  }

  private func rebuildModel() async {
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
    }
  }

  func dismissNotificationDestination() {
    notificationDestination = nil
  }

  private struct RuntimeConfiguration {
    let storageDirectory: URL
    let preferencesKey: String
    let peerSyncEnabled: Bool
  }

  private static func productionRuntimeConfiguration() -> RuntimeConfiguration {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("WatchCompanionWatch")
    return RuntimeConfiguration(
      storageDirectory: base,
      preferencesKey: "app.preferences.v1",
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
      }
      return RuntimeConfiguration(
        storageDirectory: directory,
        preferencesKey: "app.preferences.v1.uitests.\(identifier)",
        peerSyncEnabled: peerSyncEnabled
      )
    }
  #endif
}
