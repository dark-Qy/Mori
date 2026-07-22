import AppRuntime
import Combine
import Domain
import Foundation
import SwiftUI

@MainActor
final class WatchAppStore: ObservableObject {
  @Published private(set) var model: WatchPresentationModel
  @Published private(set) var isRefreshingHealth = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var isCompletingAction = false
  @Published private(set) var actionCompleted = false
  @Published private(set) var isAdvancingStory = false

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

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    dataMode = WatchDataMode.from(arguments: arguments)
    model = WatchPresentationModel.initial(arguments: arguments)
    runtime =
      dataMode == .live
      ? AppleCompanionRuntime(
        source: .watch,
        storageDirectory: Self.applicationSupportDirectory(arguments: arguments)
      )
      : nil
    notificationRouteObserver = dataMode == .live ? RuntimeNotificationRouteObserver() : nil
    launchNotificationRoute = Self.notificationRoute(from: arguments)
    usesE2EOfflineRuntime =
      arguments.contains("-UITesting") && arguments.contains("--e2e-offline-runtime")
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
      statusMessage =
        usesE2EOfflineRuntime
        ? "本地进度已载入；离线测试不会读取健康数据"
        : "本地进度已载入，健康数据正在更新"
      guard !usesE2EOfflineRuntime else { return }
      beginPeerUpdates(runtime: runtime)
      await refreshHealth(requestAccessIfNeeded: false)
    } catch {
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

  func connectHealth() async {
    await refreshHealth(requestAccessIfNeeded: true)
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
    switch value.route {
    case "pet/recovery":
      statusMessage = "Mori：今天可以慢一点，由你决定是否回应"
    case "pet/activity":
      statusMessage = "Mori：要不要一起走两分钟？不完成也不会失去什么"
    default:
      break
    }
  }

  private static func notificationRoute(from arguments: [String]) -> RuntimeNotificationRoute? {
    guard
      let value = arguments.first(where: { $0.hasPrefix("--notification-route=") })?
        .replacingOccurrences(of: "--notification-route=", with: ""),
      !value.isEmpty
    else { return nil }
    return RuntimeNotificationRoute(route: value)
  }

  private static func applicationSupportDirectory(arguments: [String]) -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("WatchCompanionWatch")
    guard
      arguments.contains("-UITesting"),
      let identifier = arguments.first(where: { $0.hasPrefix("--e2e-storage-id=") })?
        .replacingOccurrences(of: "--e2e-storage-id=", with: ""),
      !identifier.isEmpty,
      identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
      )
    else { return base }

    let directory =
      base
      .appendingPathComponent("UITests", isDirectory: true)
      .appendingPathComponent(identifier, isDirectory: true)
    if arguments.contains("--reset-e2e-storage") {
      try? FileManager.default.removeItem(at: directory)
    }
    return directory
  }
}
