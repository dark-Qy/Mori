import AppRuntime
import Combine
import Domain
import Foundation
import SwiftUI

@MainActor
final class PhoneAppStore: ObservableObject {
  @Published private(set) var model: PhonePresentationModel
  @Published private(set) var preferences = AppPreferences()
  @Published private(set) var isRefreshingHealth = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var notificationStatus = "尚未请求"
  @Published var selectedTab: PhoneTab = .overview

  let dataMode: PhoneDataMode
  private let runtime: AppleCompanionRuntime?
  private let notificationRouteObserver: RuntimeNotificationRouteObserver?
  private let launchNotificationRoute: RuntimeNotificationRoute?
  private var hasStarted = false
  private var latestHealth: HealthSnapshot?
  private var preferenceSaveTask: Task<Void, Never>?
  private var preferenceRevision: UInt64 = 0
  private var notificationRouteTask: Task<Void, Never>?

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    dataMode = PhoneDataMode.from(arguments: arguments)
    model = PhonePresentationModel.initial(arguments: arguments)
    runtime =
      dataMode == .live
      ? AppleCompanionRuntime(
        source: .phone,
        storageDirectory: Self.applicationSupportDirectory()
      )
      : nil
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
    guard let runtime else { return }
    do {
      preferences = try await runtime.loadPreferences()
      notificationStatus = await notificationStatusText()
      let state = try await runtime.currentState()
      let trend = try await runtime.personalHealthTrend()
      model = .live(
        companion: state,
        health: latestHealth,
        trend: trend,
        syncStatus: "已载入本机记录"
      )
      await refreshHealth(requestAccessIfNeeded: false)
    } catch {
      statusMessage = "载入失败：\(Self.safeError(error))"
    }
  }

  func connectHealth() async {
    await refreshHealth(requestAccessIfNeeded: true)
  }

  func refreshHealth(requestAccessIfNeeded: Bool = false) async {
    guard dataMode == .live, let runtime, !isRefreshingHealth else { return }
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
        syncStatus: Self.syncText(refresh.syncStatus)
      )
      statusMessage = refresh.health.hasAnyMetric ? "健康数据已更新" : "没有可用数据；不会因此扣除成长值"
    } catch {
      statusMessage = "健康数据暂时不可用：\(Self.safeError(error))"
    }
  }

  func setProactiveMessages(_ enabled: Bool) {
    preferences.proactiveMessagesEnabled = enabled
    preferences.proactiveNotificationConsentVersion =
      enabled
      ? AppPreferences.currentNotificationConsentVersion : 0
    persistPreferences()
    Task {
      guard let runtime else { return }
      if enabled {
        notificationStatus = Self.notificationText(
          await runtime.requestNotificationPermissionStatus())
      } else {
        await runtime.cancelProactiveNotifications()
      }
    }
  }

  func setSocialSharing(_ enabled: Bool) {
    preferences.socialSharingEnabled = enabled
    persistPreferences()
  }

  func setHealthSharingScope(_ scope: HealthSharingScope) {
    preferences.healthSharingScope = scope
    persistPreferences()
  }

  func selectOutfit(_ id: String) {
    preferences.selectedOutfitID = id
    persistPreferences()
  }

  private func persistPreferences() {
    guard let runtime else { return }
    let value = preferences
    preferenceRevision &+= 1
    let revision = preferenceRevision
    let previousTask = preferenceSaveTask
    preferenceSaveTask = Task { [weak self] in
      await previousTask?.value
      do {
        try await runtime.savePreferences(value)
      } catch {
        guard let self, revision == self.preferenceRevision else { return }
        self.statusMessage = "设置未能保存：\(Self.safeError(error))"
      }
    }
  }

  private func notificationStatusText() async -> String {
    guard let runtime else { return "Mock 不请求权限" }
    return Self.notificationText(await runtime.notificationPermissionStatus())
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
    guard value.route == "pet/recovery" || value.route == "pet/activity" else { return }
    selectedTab = .overview
    statusMessage =
      value.route == "pet/recovery"
      ? "已打开 Mori 的恢复来信；不会自动完成任务或领取奖励"
      : "已打开 Mori 的活动来信；由你决定是否回应"
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
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("WatchCompanion")
  }

  private static func syncText(_ status: RuntimeSyncStatus) -> String {
    switch status {
    case .synced: "已同步到 Apple Watch"
    case .queued: "已保存；手表同步在后台继续"
    case .waitingForPeer: "已保存，等待 Apple Watch"
    case .unavailable: "已保存；此设备不支持手表同步"
    case .failed: "已保存；手表同步稍后重试"
    }
  }

  private static func notificationText(_ status: RuntimeNotificationPermissionStatus) -> String {
    switch status {
    case .notRequested: "尚未请求"
    case .allowed: "已允许"
    case .denied: "已在系统中关闭"
    case .unavailable: "此设备不可用"
    }
  }

  private static func safeError(_ error: Error) -> String {
    let text = String(describing: error)
    return text.count > 120 ? "请稍后重试" : text
  }
}
