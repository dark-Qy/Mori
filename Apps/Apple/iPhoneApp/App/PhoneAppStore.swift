import AppRuntime
import Combine
import Domain
import Foundation
import SwiftUI

enum PhoneAppPhase: Equatable {
  case loading
  case onboarding
  case ready
}

@MainActor
final class PhoneAppStore: ObservableObject {
  @Published private(set) var model: PhonePresentationModel
  @Published private(set) var preferences = AppPreferences()
  @Published private(set) var phase: PhoneAppPhase
  @Published private(set) var previewOutfitID: String
  @Published private(set) var unlockedOutfitIDs: Set<String>
  @Published private(set) var isRefreshingHealth = false
  @Published private(set) var isSavingPreferences = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var notificationStatus = "尚未请求"
  @Published private(set) var selectedDataSource: CompanionDataSource
  @Published var selectedTab: PhoneTab = .overview
  @Published var notificationDestination: RuntimeNotificationDestination? = nil

  var dataMode: PhoneDataMode { model.dataMode }
  var dataSourceSelectionAvailable: Bool { !hasLaunchScenarioOverride }
  private let runtime: AppleCompanionRuntime?
  private let wardrobeService = WardrobeService()
  private let notificationRouteObserver: RuntimeNotificationRouteObserver?
  private let launchNotificationRoute: RuntimeNotificationRoute?
  private let usesE2EOfflineRuntime: Bool
  private let hasLaunchScenarioOverride: Bool
  private var hasStarted = false
  private var latestHealth: HealthSnapshot?
  private var preferenceSaveTask: Task<Void, Never>?
  private var preferenceRevision: UInt64 = 0
  private var notificationRouteTask: Task<Void, Never>?
  private var peerSyncRetryTask: Task<Void, Never>?
  private var peerUpdateTask: Task<Void, Never>?
  private var peerUpdateGeneration: UInt64 = 0
  private var mockCareTask: Task<Void, Never>?

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    let initialModel = PhonePresentationModel.initial(arguments: arguments)
    model = initialModel
    #if DEBUG
      selectedDataSource =
        initialModel.mockScenario.flatMap { CompanionDataSource(rawValue: $0.id) }
        ?? .defaultSelection
    #else
      selectedDataSource = .defaultSelection
    #endif
    preferences = AppPreferences(
      hasCompletedOnboarding: initialModel.initialScreen != .onboarding,
      selectedOutfitID: initialModel.wardrobe.selectedOutfitID
    )
    previewOutfitID = initialModel.wardrobe.previewOutfitID
    unlockedOutfitIDs = initialModel.wardrobe.unlockedOutfitIDs
    hasLaunchScenarioOverride = initialModel.dataMode != .live
    phase =
      hasLaunchScenarioOverride
      ? (initialModel.initialScreen == .onboarding ? .onboarding : .ready)
      : .loading
    selectedTab = initialModel.initialScreen == .wardrobe ? .wardrobe : .overview
    #if DEBUG
      let runtimeConfiguration = Self.runtimeConfiguration(arguments: arguments)
    #else
      let runtimeConfiguration = Self.productionRuntimeConfiguration()
    #endif
    runtime = AppleCompanionRuntime(
      source: .phone,
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
      previewOutfitID = preferences.selectedOutfitID
      unlockedOutfitIDs = PhoneWardrobePresentation.phaseOneDefault.unlockedOutfitIDs
      notificationStatus = await notificationStatusText()
      guard preferences.hasCompletedOnboarding else {
        #if DEBUG
          if selectedDataSource.isMock {
            model = PhonePresentationModel.demo(selectedDataSource)
          }
        #endif
        phase = .onboarding
        statusMessage = "先认识 Mori；健康数据始终由你决定是否连接"
        return
      }
      phase = .ready
      beginPeerUpdates(runtime: runtime)
      await applySelectedDataSource(requestAccessIfNeeded: false)
      guard !usesE2EOfflineRuntime else {
        statusMessage =
          selectedDataSource.isMock
          ? "\(selectedDataSource.displayName) 已载入"
          : "本地设置已载入；离线测试不会读取健康数据"
        return
      }
      retryPeerSyncInBackground(runtime: runtime)
    } catch {
      phase = .ready
      statusMessage = "载入失败：\(Self.safeError(error))"
    }
  }

  func connectHealth() async {
    await selectDataSource(.healthKit)
  }

  func selectDataSource(_ source: CompanionDataSource) async {
    guard !hasLaunchScenarioOverride else { return }
    mockCareTask?.cancel()
    stopPeerUpdates()
    selectedDataSource = source
    if let runtime {
      _ = await runtime.saveDataSourceSelection(source)
      if source == .healthKit {
        beginPeerUpdates(runtime: runtime)
      }
    }
    await applySelectedDataSource(requestAccessIfNeeded: source == .healthKit)
  }

  func completeOnboarding() async {
    guard phase == .onboarding, !isSavingPreferences else { return }
    if hasLaunchScenarioOverride {
      preferences.hasCompletedOnboarding = true
      phase = .ready
      selectedTab = .overview
      statusMessage = "Mori 已准备好；Mock 不会请求系统权限"
      return
    }
    guard let runtime else {
      preferences.hasCompletedOnboarding = true
      phase = .ready
      selectedTab = .overview
      statusMessage = "Mori 已准备好；Mock 不会请求系统权限"
      return
    }

    isSavingPreferences = true
    preferences.hasCompletedOnboarding = true
    do {
      _ = try await runtime.savePreferences(preferences)
      phase = .ready
      selectedTab = .overview
      beginPeerUpdates(runtime: runtime)
      await applySelectedDataSource(requestAccessIfNeeded: false)
      statusMessage =
        selectedDataSource.isMock
        ? "Mori 已准备好；\(selectedDataSource.displayName) 已载入"
        : "Mori 已准备好；健康数据可以稍后再连接"
      isSavingPreferences = false
      guard !usesE2EOfflineRuntime else { return }
    } catch {
      preferences.hasCompletedOnboarding = false
      isSavingPreferences = false
      statusMessage = "暂时没能保存，请再试一次"
    }
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
        syncStatus: Self.syncText(refresh.syncStatus)
      )
      statusMessage = refresh.health.hasAnyMetric ? "健康数据已更新" : "没有可用数据；不会因此扣除成长值"
    } catch {
      guard selectedDataSource == .healthKit else { return }
      statusMessage = "健康数据暂时不可用：\(Self.safeError(error))"
    }
  }

  func companionInteraction() async {
    if selectedDataSource.isMock || hasLaunchScenarioOverride {
      #if DEBUG
        if model.mockScenario?.id == CompanionDataSource.mock2.fixtureID {
          model = model.resolvingMockRelationship()
        }
      #endif
      statusMessage = "Mori 靠近了一点，安静地陪着你"
      return
    }
    guard let runtime else { return }
    do {
      let state = try await runtime.recordPetInteraction(kind: "phone_companion")
      let trend = try await runtime.personalHealthTrend()
      model = .live(
        companion: state,
        health: latestHealth,
        trend: trend,
        syncStatus: "互动已保存"
      )
      statusMessage = "Mori 靠近了一点，安静地陪着你"
    } catch {
      statusMessage = "这次互动没能保存，但 Mori 已经看见你了"
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
        guard selectedDataSource == .healthKit else {
          notificationStatus = "Mock 不请求权限"
          return
        }
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

  func setPublicPetSocialState(_ state: PublicPetSocialStateV1) {
    guard preferences.publicPetSocialState != state else { return }
    preferences.publicPetSocialState = state
    persistPreferences(successPrefix: "公开宠物状态已更新")
  }

  func setHealthSharingScope(_ scope: HealthSharingScope) {
    preferences.healthSharingScope = scope
    persistPreferences()
  }

  func selectCharacter(_ id: String) {
    guard CompanionVisualCatalog.characterIDs.contains(id) else {
      statusMessage = "无法选择未知角色"
      return
    }
    guard preferences.selectedCharacterIDs != [id] else {
      statusMessage = "这个角色正在陪伴你"
      return
    }
    preferences.selectedCharacterIDs = [id]
    persistPreferences(successPrefix: "角色已更新")
  }

  func selectBackground(_ id: String) {
    guard CompanionVisualCatalog.backgroundIDs.contains(id) else {
      statusMessage = "无法选择未知背景"
      return
    }
    guard preferences.selectedBackgroundID != id else {
      statusMessage = "这个背景正在使用"
      return
    }
    preferences.selectedBackgroundID = id
    persistPreferences(successPrefix: "背景已更新")
  }

  func previewOutfit(_ id: String) {
    if case .invalidMock = dataMode { return }
    do {
      let state = try wardrobeService.preview(id, in: wardrobeSessionState)
      applyWardrobeSession(state)
    } catch {
      statusMessage = "无法预览未知装扮"
      return
    }
    if unlockedOutfitIDs.contains(id) {
      statusMessage =
        id == preferences.selectedOutfitID
        ? "这件装扮正在使用" : "预览不会改变手表；点“装备”后才会保存"
    } else {
      statusMessage = "这件装扮还未解锁；预览不会影响成长或属性"
    }
  }

  func equipPreviewedOutfit() {
    guard !isSavingPreferences else { return }
    let mutation: WardrobeMutation
    do {
      mutation = try wardrobeService.equipPreview(in: wardrobeSessionState)
    } catch WardrobeSelectionError.lockedOutfit(_) {
      statusMessage = "这件装扮还未解锁；不会消耗任何奖励"
      return
    } catch {
      statusMessage = "无法装备未知装扮"
      return
    }
    guard mutation.selectionChanged else {
      statusMessage = "这件装扮正在使用"
      return
    }
    applyWardrobeSession(mutation.state)
    persistPreferences(successPrefix: "装扮已保存在本机")
  }

  func resetOutfit() {
    guard !isSavingPreferences else { return }
    guard let mutation = try? wardrobeService.reset(wardrobeSessionState) else {
      statusMessage = "暂时无法恢复默认外观"
      return
    }
    applyWardrobeSession(mutation.state)
    guard mutation.selectionChanged else {
      statusMessage = "已经恢复为默认外观"
      return
    }
    persistPreferences(successPrefix: "已恢复默认外观")
  }

  private func persistPreferences(successPrefix: String = "设置已保存在本机") {
    guard !hasLaunchScenarioOverride else { return }
    if selectedDataSource.isMock {
      statusMessage = "\(successPrefix)；Mock 互动不会写入真实设置"
      return
    }
    guard let runtime else {
      guard case .mock = dataMode else { return }
      statusMessage =
        model.wardrobe.peerSyncAvailable == true
        ? "\(successPrefix)；Mock 模拟手表可达"
        : "\(successPrefix)；Mock 模拟等待手表"
      return
    }
    let value = preferences
    preferenceRevision &+= 1
    let revision = preferenceRevision
    let previousTask = preferenceSaveTask
    isSavingPreferences = true
    statusMessage = "正在保存…"
    preferenceSaveTask = Task { [weak self] in
      await previousTask?.value
      do {
        let syncStatus = try await runtime.savePreferences(value)
        guard let self, revision == self.preferenceRevision else { return }
        self.isSavingPreferences = false
        self.statusMessage = "\(successPrefix)；\(Self.syncText(syncStatus))"
      } catch {
        guard let self, revision == self.preferenceRevision else { return }
        self.isSavingPreferences = false
        self.statusMessage = "设置未能保存：\(Self.safeError(error))"
      }
    }
  }

  private func loadLocalExperience(syncStatus: String) async throws {
    guard let runtime else { return }
    let state = try await runtime.currentState()
    let trend = try await runtime.personalHealthTrend()
    model = .live(
      companion: state,
      health: latestHealth,
      trend: trend,
      syncStatus: syncStatus
    )
  }

  private func applySelectedDataSource(requestAccessIfNeeded: Bool) async {
    mockCareTask?.cancel()
    if selectedDataSource.isMock {
      #if DEBUG
        model = PhonePresentationModel.demo(selectedDataSource)
        previewOutfitID = model.wardrobe.previewOutfitID
        unlockedOutfitIDs = model.wardrobe.unlockedOutfitIDs
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
      previewOutfitID = preferences.selectedOutfitID
      unlockedOutfitIDs = PhoneWardrobePresentation.phaseOneDefault.unlockedOutfitIDs
      try await loadLocalExperience(syncStatus: "已载入本机记录")
    } catch {
      model = .liveNoData()
    }
    await refreshHealth(requestAccessIfNeeded: requestAccessIfNeeded)
  }

  #if DEBUG
    private func scheduleMockCareIfNeeded() {
      guard selectedDataSource == .mock2 else { return }
      mockCareTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(60))
        guard !Task.isCancelled, let self, self.selectedDataSource == .mock2 else { return }
        self.model = self.model.addingMockCareMessage()
        self.statusMessage = "Mori 给你留了一封轻轻的来信"
      }
    }
  #endif

  private func beginPeerUpdates(runtime: AppleCompanionRuntime) {
    guard
      selectedDataSource == .healthKit,
      peerUpdateTask == nil
    else { return }
    peerUpdateGeneration &+= 1
    let generation = peerUpdateGeneration
    peerUpdateTask = Task { [weak self] in
      defer {
        if let self, self.peerUpdateGeneration == generation {
          self.peerUpdateTask = nil
        }
      }
      let peerUpdates = await runtime.peerValueUpdates()
      if let self, let values = await runtime.latestPeerValues() {
        await self.applyPeerValues(values, runtime: runtime)
      }
      for await values in peerUpdates {
        guard let self else { return }
        await self.applyPeerValues(values, runtime: runtime)
      }
    }
  }

  private func stopPeerUpdates() {
    peerUpdateGeneration &+= 1
    peerUpdateTask?.cancel()
    peerUpdateTask = nil
  }

  private func applyPeerValues(
    _ values: [String: String],
    runtime: AppleCompanionRuntime
  ) async {
    let shouldReloadDataSource: Bool
    do {
      shouldReloadDataSource = try await runtime.applyPeerPreferences(values)
      preferences = try await runtime.loadPreferences()
      previewOutfitID = preferences.selectedOutfitID
    } catch {
      statusMessage = "配对设置暂时无法同步"
      return
    }
    guard
      let rawValue = values["dataSource"],
      let incoming = CompanionDataSource(rawValue: rawValue),
      shouldReloadDataSource
    else { return }
    selectedDataSource = incoming
    stopPeerUpdates()
    await applySelectedDataSource(requestAccessIfNeeded: false)
    if incoming == .healthKit {
      beginPeerUpdates(runtime: runtime)
    }
  }

  private var wardrobeSessionState: WardrobeSessionState {
    WardrobeSessionState(
      selectedOutfitID: preferences.selectedOutfitID,
      previewOutfitID: previewOutfitID,
      unlockedOutfitIDs: unlockedOutfitIDs
    )
  }

  private func applyWardrobeSession(_ state: WardrobeSessionState) {
    preferences.selectedOutfitID = state.selectedOutfitID
    previewOutfitID = state.previewOutfitID
    unlockedOutfitIDs = state.unlockedOutfitIDs
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

  /// A previous process may have reached WatchConnectivity before its durable acknowledgement
  /// was written. Retrying the exact state is idempotent at the transport boundary.
  private func retryPeerSyncInBackground(runtime: AppleCompanionRuntime) {
    guard peerSyncRetryTask == nil else { return }
    peerSyncRetryTask = Task { [weak self] in
      _ = try? await runtime.retryPeerSync()
      self?.peerSyncRetryTask = nil
    }
  }

  private func handleNotificationRoute(_ value: RuntimeNotificationRoute) {
    guard let destination = NotificationRouteCoordinator().destination(for: value) else { return }
    selectedTab = .overview
    notificationDestination = destination
    switch destination {
    case .recoveryMessage:
      statusMessage = "已打开 Mori 的恢复来信；不会自动完成任务或领取奖励"
    case .activityMessage:
      statusMessage = "已打开 Mori 的活动来信；由你决定是否回应"
    case .careMessage:
      statusMessage = "已打开 Mori 的陪伴来信；不需要解释，也不用立刻回应"
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

  private static func productionRuntimeConfiguration() -> RuntimeConfiguration {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("WatchCompanion")
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
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("WatchCompanion")
      let usesUITesting = arguments.contains("-UITesting")
      let peerSyncEnabled =
        !(usesUITesting && arguments.contains("--e2e-offline-runtime"))
      guard usesUITesting, let identifier = e2eStorageIdentifier(arguments: arguments) else {
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
      let preferencesKey = "app.preferences.v1.uitests.\(identifier)"
      let dataSourceKey = "app.data-source.v1.uitests.\(identifier)"
      if arguments.contains("--reset-e2e-storage") {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: preferencesKey)
        UserDefaults.standard.removeObject(forKey: dataSourceKey)
        UserDefaults.standard.removeObject(forKey: "\(dataSourceKey).selection-token")
      }
      if let seededSource = e2eDataSource(arguments: arguments) {
        UserDefaults.standard.set(seededSource.rawValue, forKey: dataSourceKey)
      }
      return RuntimeConfiguration(
        storageDirectory: directory,
        preferencesKey: preferencesKey,
        dataSourceKey: dataSourceKey,
        peerSyncEnabled: peerSyncEnabled
      )
    }

    private static func e2eStorageIdentifier(arguments: [String]) -> String? {
      guard
        let identifier = arguments.first(where: { $0.hasPrefix("--e2e-storage-id=") })?
          .replacingOccurrences(of: "--e2e-storage-id=", with: ""),
        !identifier.isEmpty,
        identifier.allSatisfy({
          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        })
      else { return nil }
      return identifier
    }

    private static func e2eDataSource(arguments: [String]) -> CompanionDataSource? {
      guard
        let rawValue = arguments.first(where: { $0.hasPrefix("--e2e-data-source=") })?
          .replacingOccurrences(of: "--e2e-data-source=", with: "")
      else { return nil }
      return CompanionDataSource(rawValue: rawValue)
    }
  #endif

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
