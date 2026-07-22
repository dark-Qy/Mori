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

  let dataMode: WatchDataMode
  private let runtime: AppleCompanionRuntime
  private let notificationRouteObserver: RuntimeNotificationRouteObserver?
  private let launchNotificationRoute: RuntimeNotificationRoute?
  private var hasStarted = false
  private var latestHealth: HealthSnapshot?
  private var latestPeerValues: [String: String]?
  private var peerUpdateTask: Task<Void, Never>?
  private var notificationRouteTask: Task<Void, Never>?

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    dataMode = WatchDataMode.from(arguments: arguments)
    model = WatchPresentationModel.initial(arguments: arguments)
    runtime = AppleCompanionRuntime(
      source: .watch,
      storageDirectory: Self.applicationSupportDirectory()
    )
    notificationRouteObserver = dataMode == .live ? RuntimeNotificationRouteObserver() : nil
    launchNotificationRoute = Self.notificationRoute(from: arguments)
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    observeNotificationRoutes()
    if let launchNotificationRoute {
      handleNotificationRoute(launchNotificationRoute)
    }
    guard dataMode == .live else { return }
    do {
      let peerUpdates = await runtime.peerValueUpdates()
      peerUpdateTask = Task { [weak self] in
        for await values in peerUpdates {
          guard let self else { return }
          self.latestPeerValues = values
          try? await self.runtime.applyPeerPreferences(values)
          await self.rebuildModel()
        }
      }
      latestPeerValues = await runtime.latestPeerValues()
      if let latestPeerValues {
        try? await runtime.applyPeerPreferences(latestPeerValues)
      }
      let state = try await runtime.currentState()
      let trend = try await runtime.personalHealthTrend()
      model = .live(
        companion: state,
        health: latestHealth,
        trend: trend,
        peerValues: latestPeerValues
      )
      await refreshHealth(requestAccessIfNeeded: false)
    } catch {
      statusMessage = "载入失败，请稍后重试"
    }
  }

  func connectHealth() async {
    await refreshHealth(requestAccessIfNeeded: true)
  }

  func refreshHealth(requestAccessIfNeeded: Bool = false) async {
    guard dataMode == .live, !isRefreshingHealth else { return }
    isRefreshingHealth = true
    defer { isRefreshingHealth = false }
    do {
      let refresh = try await runtime.refreshHealth(
        requestAccessIfNeeded: requestAccessIfNeeded
      )
      latestHealth = refresh.health
      latestPeerValues = await runtime.latestPeerValues() ?? latestPeerValues
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

  func interact() async {
    do {
      let state = try await runtime.recordPetInteraction(kind: "pet")
      let trend = try await runtime.personalHealthTrend()
      model = .live(
        companion: state,
        health: latestHealth,
        trend: trend,
        peerValues: latestPeerValues
      )
    } catch {
      statusMessage = "互动暂时没能保存"
    }
  }

  private func rebuildModel() async {
    guard dataMode == .live else { return }
    do {
      let state = try await runtime.currentState()
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

  private static func applicationSupportDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("WatchCompanionWatch")
  }
}
