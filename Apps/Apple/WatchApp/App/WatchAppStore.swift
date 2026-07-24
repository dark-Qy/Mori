import AppRuntime
import Combine
import Domain
import Foundation
import MoriRuntime
import SwiftUI

enum WatchAppPhase: Equatable {
  case loading
  case onboarding
  case petIntroduction
  case ready
}

@MainActor
final class WatchAppStore: ObservableObject {
  private struct MockGlanceCandidate {
    let presentation: WatchGlancePresentation
    let age: TimeInterval
    let supersededIDs: [String]
  }

  @Published private(set) var model: WatchPresentationModel
  @Published private(set) var preferences = AppPreferences()
  @Published private(set) var phase: WatchAppPhase
  @Published private(set) var isRefreshingHealth = false
  @Published private(set) var isSavingPreferences = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var isCompletingAction = false
  @Published private(set) var actionCompleted = false
  @Published private(set) var selectedDataSource: CompanionDataSource
  @Published private(set) var notificationDestination: RuntimeNotificationDestination? = nil
  @Published private(set) var companionSensingEnabled = true
  @Published private(set) var reminderMode: CompanionReminderMode = .wristRaise
  @Published private(set) var quietHours = CompanionQuietHours(
    startMinute: 22 * 60,
    endMinute: 7 * 60
  )
  @Published private(set) var isSavingCompanionPreferences = false
  @Published private(set) var activeGlance: WatchGlancePresentation?
  @Published private(set) var launchProductRoute: WatchProductRoute?

  var dataMode: WatchDataMode { model.dataMode }
  var dataSourceSelectionAvailable: Bool { !hasLaunchScenarioOverride }
  var companionExperienceAvailable: Bool {
    #if DEBUG
      selectedDataSource.isMock && model.allowsInteraction
    #else
      false
    #endif
  }
  var isQuietHoursActive: Bool {
    let calendar = Calendar.current
    let minute =
      calendar.component(.hour, from: Date()) * 60
      + calendar.component(.minute, from: Date())
    return quietHours.contains(minuteOfDay: minute)
  }

  private let runtime: AppleCompanionRuntime?
  private let globalPreferenceRuntime: MoriGlobalPreferenceRuntime?
  private let notificationRouteObserver: RuntimeNotificationRouteObserver?
  private let launchNotificationRoute: RuntimeNotificationRoute?
  private let usesE2EOfflineRuntime: Bool
  private let hasLaunchScenarioOverride: Bool
  private var hasStarted = false
  private var latestHealth: HealthSnapshot?
  private var latestPeerValues: [String: String]?
  private var peerUpdateTask: Task<Void, Never>?
  private var peerUpdateGeneration: UInt64 = 0
  private var notificationRouteTask: Task<Void, Never>?
  private var peerSyncRetryTask: Task<Void, Never>?
  private var mockCareTask: Task<Void, Never>?
  private let mockGlanceCandidate: MockGlanceCandidate?
  private var hasConsumedMockGlance = false
  private var companionPreferenceWritesInFlight = 0
  private var authoritativeProfileSource: MoriGlobalProfileSource?
  #if DEBUG
    private let mockExperienceRepository: WatchMockExperienceRepository
  #endif

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
    #if DEBUG
      let initialDataSource =
        initialModel.mockScenario.flatMap { CompanionDataSource(rawValue: $0.id) }
        ?? Self.e2eDataSource(arguments: arguments)
        ?? .defaultSelection
    #else
      let initialDataSource = CompanionDataSource.defaultSelection
    #endif
    selectedDataSource = initialDataSource
    #if DEBUG
      let initialGlobalProfileSource =
        initialModel.mockScenario.map {
          MoriGlobalProfileSource.mock(scenarioID: $0.id)
        }
        ?? (initialDataSource.isMock
          ? .mock(scenarioID: initialDataSource.rawValue)
          : .real)
    #else
      let initialGlobalProfileSource = MoriGlobalProfileSource.real
    #endif
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
      mockGlanceCandidate = Self.mockGlanceCandidate(from: arguments)
      launchProductRoute = Self.productRoute(from: arguments)
    #else
      let runtimeConfiguration = Self.productionRuntimeConfiguration()
      mockGlanceCandidate = nil
      launchProductRoute = nil
    #endif
    runtime = AppleCompanionRuntime(
      source: .watch,
      storageDirectory: runtimeConfiguration.storageDirectory,
      preferencesKey: runtimeConfiguration.preferencesKey,
      dataSourceKey: runtimeConfiguration.dataSourceKey,
      peerSyncEnabled: runtimeConfiguration.peerSyncEnabled
    )
    globalPreferenceRuntime = try? MoriGlobalPreferenceRuntime(
      storageURL: runtimeConfiguration.storageDirectory
        .appendingPathComponent("mori-global-authority-v1.json"),
      originDeviceID: "watch",
      initialProfileSource: initialGlobalProfileSource
    )
    #if DEBUG
      mockExperienceRepository = WatchMockExperienceRepository(
        fileURL: runtimeConfiguration.storageDirectory
          .appendingPathComponent("mock-experience-preview-v1.json")
      )
    #endif
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
    await loadGlobalPreferences()
    await loadMockTaskReceipt()
    guard !hasLaunchScenarioOverride else { return }
    observeNotificationRoutes()
    if let launchNotificationRoute {
      handleNotificationRoute(launchNotificationRoute)
    }
    guard let runtime else { return }
    do {
      preferences = try await runtime.loadPreferences()
      let legacyDataSource = await runtime.loadDataSourceSelection()
      selectedDataSource =
        authoritativeProfileSource.flatMap(Self.dataSource(from:))
        ?? legacyDataSource
      if selectedDataSource != legacyDataSource {
        _ = await runtime.saveDataSourceSelection(selectedDataSource)
      }
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

  func handleForegroundActivation() async {
    guard
      !hasConsumedMockGlance,
      let candidate = mockGlanceCandidate
    else {
      return
    }
    #if DEBUG
      guard
        let shouldPresent = try? await mockExperienceRepository.consumeGlanceBatch(
          supersededIDs: candidate.supersededIDs.map {
            "\(mockProfileKey):glance:\($0)"
          },
          candidateID: "\(mockProfileKey):glance:\(candidate.presentation.id)",
          candidateIsEligible: companionSensingEnabled
            && model.allowsInteraction
            && candidate.age <= 2 * 60
        )
      else {
        return
      }
      hasConsumedMockGlance = true
      if shouldPresent {
        activeGlance = candidate.presentation
      }
    #else
      hasConsumedMockGlance = true
    #endif
  }

  func dismissActiveGlance() {
    activeGlance = nil
  }

  func consumeLaunchProductRoute() -> WatchProductRoute? {
    defer { launchProductRoute = nil }
    return launchProductRoute
  }

  func setCompanionSensingEnabled(_ enabled: Bool) {
    let previous = companionSensingEnabled
    companionSensingEnabled = enabled
    beginCompanionPreferenceWrite()
    if !enabled {
      activeGlance = nil
    }
    Task { [weak self] in
      guard let self else { return }
      defer { endCompanionPreferenceWrite() }
      guard let globalPreferenceRuntime else {
        companionSensingEnabled = previous
        statusMessage = "随行设置暂时没能保存"
        return
      }
      do {
        let projection = try await globalPreferenceRuntime.setCompanionSensing(
          enabled: enabled
        )
        apply(projection)
      } catch {
        companionSensingEnabled = previous
        statusMessage = "随行设置暂时没能保存"
      }
    }
  }

  func setReminderMode(_ mode: CompanionReminderMode) {
    let previous = reminderMode
    reminderMode = mode
    beginCompanionPreferenceWrite()
    Task { [weak self] in
      guard let self else { return }
      defer { endCompanionPreferenceWrite() }
      guard let globalPreferenceRuntime else {
        reminderMode = previous
        statusMessage = "提醒方式暂时没能保存"
        return
      }
      do {
        apply(try await globalPreferenceRuntime.setReminderMode(mode))
      } catch {
        reminderMode = previous
        statusMessage = "提醒方式暂时没能保存"
      }
    }
  }

  func setQuietHours(startMinute: Int? = nil, endMinute: Int? = nil) {
    let candidate = CompanionQuietHours(
      startMinute: startMinute.map { max(0, min(1_439, $0)) }
        ?? quietHours.startMinute,
      endMinute: endMinute.map { max(0, min(1_439, $0)) }
        ?? quietHours.endMinute
    )
    guard candidate.isValid else {
      statusMessage = "开始和结束时间不能相同"
      return
    }
    let previous = quietHours
    quietHours = candidate
    beginCompanionPreferenceWrite()
    Task { [weak self] in
      guard let self else { return }
      defer { endCompanionPreferenceWrite() }
      guard let globalPreferenceRuntime else {
        quietHours = previous
        statusMessage = "安静时段暂时没能保存"
        return
      }
      do {
        apply(try await globalPreferenceRuntime.setQuietHours(candidate))
      } catch {
        quietHours = previous
        statusMessage = "安静时段暂时没能保存"
      }
    }
  }

  private func beginCompanionPreferenceWrite() {
    companionPreferenceWritesInFlight += 1
    isSavingCompanionPreferences = true
  }

  private func endCompanionPreferenceWrite() {
    companionPreferenceWritesInFlight = max(
      0,
      companionPreferenceWritesInFlight - 1
    )
    isSavingCompanionPreferences = companionPreferenceWritesInFlight > 0
  }

  private func loadGlobalPreferences() async {
    guard let globalPreferenceRuntime else {
      statusMessage = "随行设置暂时无法载入"
      return
    }
    do {
      apply(try await globalPreferenceRuntime.current())
    } catch {
      statusMessage = "随行设置暂时无法载入"
    }
  }

  private func apply(_ projection: MoriGlobalPreferenceProjection) {
    authoritativeProfileSource = projection.profileSource
    companionSensingEnabled = projection.companionSensingEnabled
    reminderMode = projection.reminderMode
    quietHours = projection.quietHours
  }

  private func selectGlobalProfile(
    for source: CompanionDataSource
  ) async throws {
    guard let globalPreferenceRuntime else {
      throw MoriGlobalPreferenceRuntimeError.rejectedPreference
    }
    let projection = try await globalPreferenceRuntime.selectProfile(
      source.isMock
        ? .mock(scenarioID: source.rawValue)
        : .real
    )
    apply(projection)
  }

  private static func dataSource(
    from source: MoriGlobalProfileSource
  ) -> CompanionDataSource? {
    switch source {
    case .real:
      .healthKit
    case .mock(let scenarioID):
      #if DEBUG
        CompanionDataSource(rawValue: scenarioID)
      #else
        nil
      #endif
    }
  }

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

  private func stopPeerUpdates() {
    peerUpdateGeneration &+= 1
    peerUpdateTask?.cancel()
    peerUpdateTask = nil
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
    do {
      try await selectGlobalProfile(for: source)
    } catch {
      statusMessage = "数据模式暂时没能保存"
      return
    }
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

  func resetCurrentMockState() async {
    guard selectedDataSource.isMock, dataSourceSelectionAvailable else { return }
    do {
      try await selectGlobalProfile(for: selectedDataSource)
    } catch {
      statusMessage = "Mock 状态暂时没能重置"
      return
    }
    await resetMockExperiencePreview()
    await applySelectedDataSource(requestAccessIfNeeded: false)
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
      model = .live(
        companion: refresh.companion,
        health: refresh.health,
        peerValues: latestPeerValues
      )
      statusMessage = refresh.health.hasAnyMetric ? "健康数据已更新" : "当前没有可用健康记录"
    } catch {
      guard selectedDataSource == .healthKit else { return }
      statusMessage = "健康数据暂时不可用"
    }
  }

  @discardableResult
  func completeSuggestedAction() async -> Bool {
    guard
      !isCompletingAction,
      model.allowsInteraction,
      !model.isLive
    else {
      return false
    }
    #if DEBUG
      isCompletingAction = true
      defer { isCompletingAction = false }
      do {
        let receipt = try await mockExperienceRepository.settleTask(
          id: mockTaskID,
          reward: model.mockTaskCoinReward
        )
        actionCompleted = true
        statusMessage =
          receipt.wasAlreadySettled
          ? "这件 Mock 小事已经记下，金币不会重复增加"
          : "Mock 小事已经记下，预览余额 \(receipt.balance) 枚金币"
        return true
      } catch {
        statusMessage = "Mock 小事暂时没能保存"
        return false
      }
    #else
      return false
    #endif
  }

  private var mockTaskID: String {
    #if DEBUG
      return "\(mockProfileKey):task:today"
    #else
      return "unavailable"
    #endif
  }

  private var mockProfileKey: String {
    #if DEBUG
      model.mockScenario?.id ?? selectedDataSource.rawValue
    #else
      "unavailable"
    #endif
  }

  private func loadMockTaskReceipt() async {
    #if DEBUG
      guard !model.isLive else {
        actionCompleted = false
        return
      }
      actionCompleted =
        (try? await mockExperienceRepository.isTaskCompleted(id: mockTaskID))
        ?? false
    #endif
  }

  private func resetMockExperiencePreview() async {
    #if DEBUG
      do {
        try await mockExperienceRepository.reset(profileKey: mockProfileKey)
        actionCompleted = false
        hasConsumedMockGlance = false
      } catch {
        statusMessage = "Mock 状态暂时没能重置"
      }
    #endif
  }

  func interact(with animation: WatchCharacterAnimation) async {
    if selectedDataSource.isMock || hasLaunchScenarioOverride {
      #if DEBUG
        if model.mockScenario?.id == CompanionDataSource.mock2.fixtureID {
          model = model.resolvingMockRelationship()
          actionCompleted = true
        }
      #endif
      statusMessage = animation == .touchHead ? "Mori 开心地眨了眨眼" : "Mori 转过身回应了你"
      return
    }
    guard let runtime else { return }
    do {
      let state = try await runtime.recordPetInteraction(kind: animation.rawValue)
      model = .live(
        companion: state,
        health: latestHealth,
        peerValues: latestPeerValues
      )
      statusMessage = animation == .touchHead ? "Mori 开心地眨了眨眼" : "Mori 转过身回应了你"
    } catch {
      statusMessage = "这次互动没能保存，但 Mori 已经看见你了"
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
      model = .live(
        companion: state,
        health: latestHealth,
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
    model = .live(
      companion: state,
      health: latestHealth,
      peerValues: latestPeerValues
    )
  }

  private func applySelectedDataSource(requestAccessIfNeeded: Bool) async {
    mockCareTask?.cancel()
    actionCompleted = false
    if selectedDataSource.isMock {
      #if DEBUG
        model = WatchPresentationModel.demo(selectedDataSource)
        await loadMockTaskReceipt()
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
      if shouldReloadDataSource {
        stopPeerUpdates()
      }
      await applyPeerValues(values, shouldReloadDataSource: shouldReloadDataSource)
      if shouldReloadDataSource,
        values["dataSource"] == CompanionDataSource.healthKit.rawValue
      {
        beginPeerUpdates(runtime: runtime)
      }
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
    private static func productRoute(from arguments: [String]) -> WatchProductRoute? {
      arguments.first(where: { $0.hasPrefix("--watch-route=") })
        .map {
          $0.replacingOccurrences(of: "--watch-route=", with: "")
        }
        .flatMap(WatchProductRoute.init(rawValue:))
    }

    private static func mockGlanceCandidate(
      from arguments: [String]
    ) -> MockGlanceCandidate? {
      guard arguments.contains("-UITesting") else { return nil }
      let eventValues =
        arguments.first(where: { $0.hasPrefix("--mock-glance=") })?
        .replacingOccurrences(of: "--mock-glance=", with: "")
        .split(separator: ",")
        .map(String.init) ?? []
      guard let newest = eventValues.last else { return nil }
      let age =
        arguments.first(where: { $0.hasPrefix("--mock-glance-age=") })
        .flatMap {
          TimeInterval(
            $0.replacingOccurrences(of: "--mock-glance-age=", with: "")
          )
        } ?? 0
      let presentation = mockGlancePresentation(for: newest)
      let supersededIDs = eventValues.dropLast().map {
        mockGlancePresentation(for: $0).id
      }
      return MockGlanceCandidate(
        presentation: presentation,
        age: max(0, age),
        supersededIDs: supersededIDs
      )
    }

    private static func mockGlancePresentation(
      for value: String
    ) -> WatchGlancePresentation {
      switch value {
      case "shared-walk":
        WatchGlancePresentation(
          id: value,
          message: "我们已经一起走了 3,250 步。",
          reaction: .idleLively
        )
      case "paused":
        WatchGlancePresentation(
          id: value,
          message: "你停下来的时候，我也坐了一会儿。",
          reaction: .idleResting
        )
      default:
        WatchGlancePresentation(
          id: "fast-pace",
          message: "刚才那段路走得好快，我差点跟不上。",
          reaction: .idleCurious
        )
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
