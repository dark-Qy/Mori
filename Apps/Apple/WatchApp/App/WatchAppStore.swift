import AppRuntime
import Combine
import Domain
import Foundation
import MoriDomain
import MoriPersistence
import MoriRuntime
import SwiftUI

#if DEBUG
  import DebugScenarioSupport
#endif

enum WatchAppPhase: Equatable {
  case loading
  case onboarding
  case petIntroduction
  case ready
}

@MainActor
final class WatchAppStore: ObservableObject {
  private struct MockGlanceSeed {
    let values: [String]
    let age: TimeInterval
  }

  @Published private(set) var model: WatchPresentationModel
  @Published private(set) var preferences = AppPreferences()
  @Published private(set) var phase: WatchAppPhase
  @Published private(set) var isRefreshingHealth = false
  @Published private(set) var isSavingPreferences = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var isCompletingAction = false
  @Published private(set) var actionCompleted = false
  @Published private(set) var hasSuggestedAction = false
  @Published private(set) var suggestedActionReward = 0
  @Published private(set) var coinBalance = 0
  @Published private(set) var selectedDataSource: CompanionDataSource
  @Published private(set) var movementScene: MovementScenePresentation?
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
  private let applicationSupportURL: URL
  private var hasStarted = false
  private var latestHealth: HealthSnapshot?
  private var latestPeerValues: [String: String]?
  private var peerUpdateTask: Task<Void, Never>?
  private var peerUpdateGeneration: UInt64 = 0
  private var notificationRouteTask: Task<Void, Never>?
  private var peerSyncRetryTask: Task<Void, Never>?
  private var mockCareTask: Task<Void, Never>?
  private let mockGlanceSeed: MockGlanceSeed?
  private var hasSeededMockGlance = false
  private var companionPreferenceWritesInFlight = 0
  private var authoritativeProfileSource: MoriGlobalProfileSource?
  private var productLoopRuntime: ProductLoopAppRuntime?
  private var productLoopGeneration: UInt64 = 0
  private var suggestedTaskID: TaskID?
  private var suggestedTaskCompletionDate: Date?
  private var movementSceneTask: Task<Void, Never>?

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

  var scenePresentation: WatchScenePresentation {
    guard let movementScene else { return model.scene }
    let presentation = WatchScenePresentation.make(
      peerValues: [
        "background": movementScene.backgroundID,
        "characters": model.scene.slots.map(\.characterID).joined(separator: ","),
      ],
      mood: movementScene.petMood
    )
    guard
      movementScene.petMotion.loopsWhileStateIsActive,
      let movementSceneAnimation
    else {
      return presentation
    }
    return presentation.applying(
      idleAnimation: movementSceneAnimation,
      toCharacterID: CompanionVisualCatalog.defaultCharacterID
    )
  }

  var movementSceneAnimation: WatchCharacterAnimation? {
    guard
      let movementScene,
      model.scene.slots.contains(where: {
        $0.characterID == CompanionVisualCatalog.defaultCharacterID
      })
    else {
      return nil
    }
    return WatchCharacterAnimation(rawValue: movementScene.petMotion.rawValue)
  }

  /// Starting an encounter is explicit, per-session consent on Watch. A synchronized iPhone
  /// opt-out still wins by setting `socialSharingEnabled` to false.
  var isTouchExchangeSharingEnabled: Bool {
    preferences.socialSharingEnabled
  }

  init(arguments: [String] = ProcessInfo.processInfo.arguments) {
    var initialModel = WatchPresentationModel.initial(arguments: arguments)
    #if DEBUG
      if arguments.contains("-UITesting"),
        let characterID = arguments.first(where: { $0.hasPrefix("--character=") })?
          .replacingOccurrences(of: "--character=", with: "")
      {
        initialModel = initialModel.selectingCharacter(characterID)
      }
    #endif
    #if DEBUG
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
      let touchExchangeSharingEnabled =
        !arguments.contains("--touch-exchange-sharing-disabled")
    #else
      let touchExchangeDemoSocialState = PublicPetSocialStateV1.greeting
      let touchExchangeSharingEnabled = true
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
        ?? initialModel.invalidMockID.map {
          MoriGlobalProfileSource.mock(scenarioID: $0)
        }
        ?? (initialDataSource.isMock
          ? .mock(scenarioID: initialDataSource.rawValue)
          : .real)
    #else
      let initialGlobalProfileSource = MoriGlobalProfileSource.real
    #endif
    movementScene = nil
    preferences = AppPreferences(
      hasCompletedOnboarding: initialModel.initialScreen != .onboarding,
      socialSharingEnabled: touchExchangeSharingEnabled,
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
      mockGlanceSeed = Self.mockGlanceSeed(from: arguments)
      launchProductRoute = Self.productRoute(from: arguments)
    #else
      let runtimeConfiguration = Self.productionRuntimeConfiguration()
      mockGlanceSeed = nil
      launchProductRoute = nil
    #endif
    applicationSupportURL = runtimeConfiguration.storageDirectory
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
    await rebuildProductLoopRuntime(activateMock: true)
    guard !hasLaunchScenarioOverride else {
      #if DEBUG
        startMovementSceneIfNeeded()
      #endif
      return
    }
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
      if !usesE2EOfflineRuntime {
        do {
          try await applyLatestPhonePreferencesIfAvailable(runtime: runtime)
        } catch {
          statusMessage = "好友分享设置暂时无法同步，将沿用当前设置"
        }
      }
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
      // Preferences could include an explicit iPhone opt-out. If the local record itself
      // cannot be read, fail closed rather than guessing that sharing was enabled.
      preferences.socialSharingEnabled = false
      phase = .ready
      statusMessage = "载入失败，请稍后重试"
    }
  }

  func handleForegroundActivation() async {
    guard
      companionSensingEnabled,
      model.allowsInteraction,
      let productLoopRuntime,
      productLoopRuntime.profile.isMock
    else { return }
    do {
      #if DEBUG
        try await seedMockGlancesIfNeeded(
          runtime: productLoopRuntime
        )
      #endif
      let snapshot = try await productLoopRuntime.snapshot()
      let date = foregroundDate(from: snapshot.localState)
      guard
        let presentation = try await productLoopRuntime.foregroundGlance(
          at: date,
          reminderMode: reminderMode,
          quietHours: quietHours,
          timeZone: .current
        )
      else {
        await refreshProductLoopSnapshot(
          from: productLoopRuntime
        )
        return
      }
      activeGlance = Self.watchGlance(from: presentation)
      await refreshProductLoopSnapshot(from: productLoopRuntime)
    } catch {
      statusMessage = "Mori 这次保持安静"
    }
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
        try await reconcileProductLoopSensing(
          projection,
          effectiveAt: Date()
        )
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

  private static func sensingPreference(
    from projection: MoriGlobalPreferenceProjection
  ) -> CompanionSensingPreference {
    CompanionSensingPreference(
      enabled: projection.sensingScope.enabled,
      epoch: SensingEpoch(
        LamportRevision(
          counter: projection.sensingScope.epochCounter,
          originDeviceID:
            projection.sensingScope.epochOriginDeviceID
        )
      )
    )
  }

  private func reconcileProductLoopSensing(
    _ projection: MoriGlobalPreferenceProjection,
    effectiveAt date: Date
  ) async throws {
    guard let productLoopRuntime else { return }
    _ = try await productLoopRuntime.reconcileSensing(
      Self.sensingPreference(from: projection),
      effectiveAt: date
    )
    await refreshProductLoopSnapshot(from: productLoopRuntime)
  }

  private func selectGlobalProfile(
    for source: CompanionDataSource
  ) async throws -> MoriGlobalPreferenceProjection {
    guard let globalPreferenceRuntime else {
      throw MoriGlobalPreferenceRuntimeError.rejectedPreference
    }
    let projection = try await globalPreferenceRuntime.selectProfile(
      source.isMock
        ? .mock(scenarioID: source.rawValue)
        : .real
    )
    apply(projection)
    return projection
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
    let previousRuntime = productLoopRuntime
    do {
      _ = try await selectGlobalProfile(for: source)
      stopProductLoopRuntime()
      try removeRetiredMockNamespace(previousRuntime)
      await rebuildProductLoopRuntime(activateMock: source.isMock)
    } catch {
      statusMessage = "数据模式暂时没能保存"
      return
    }
    mockCareTask?.cancel()
    stopPeerUpdates()
    movementSceneTask?.cancel()
    movementScene = nil
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
    let previousRuntime = productLoopRuntime
    do {
      _ = try await selectGlobalProfile(for: selectedDataSource)
      stopProductLoopRuntime()
      try removeRetiredMockNamespace(previousRuntime)
      await rebuildProductLoopRuntime(activateMock: true)
    } catch {
      statusMessage = "Mock 状态暂时没能重置"
      return
    }
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
      if !usesE2EOfflineRuntime {
        do {
          try await applyLatestPhonePreferencesIfAvailable(runtime: runtime)
        } catch {
          statusMessage = "好友分享设置暂时无法同步，将沿用当前设置"
        }
      }
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
      !model.isLive,
      let productLoopRuntime,
      productLoopRuntime.profile.isMock,
      let suggestedTaskID,
      let suggestedTaskCompletionDate
    else {
      return false
    }
    isCompletingAction = true
    defer { isCompletingAction = false }
    do {
      let receipt = try await productLoopRuntime.completeTask(
        taskID: suggestedTaskID,
        method: .userConfirmed,
        at: suggestedTaskCompletionDate
      )
      await refreshProductLoopSnapshot(from: productLoopRuntime)
      statusMessage =
        (!receipt.didRecordCompletion && !receipt.didRecordReward)
        ? "这件 Mock 小事已经记下，金币不会重复增加"
        : "Mock 小事已经记下，当前有 \(receipt.balance) 枚金币"
      return true
    } catch {
      statusMessage = "Mock 小事暂时没能保存"
      return false
    }
  }

  func interact(with animation: WatchCharacterAnimation) async {
    if selectedDataSource.isMock || hasLaunchScenarioOverride {
      #if DEBUG
        if CompanionDataSource.isPeerExchangeFixtureID(model.mockScenario?.id) {
          model = model.resolvingMockRelationship()
        }
      #endif
      statusMessage =
        animation == .touchHead
        ? "\(interactionSubjectName) 开心地眨了眨眼"
        : "\(interactionSubjectName) 转过身回应了你"
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
      statusMessage =
        animation == .touchHead
        ? "\(interactionSubjectName) 开心地眨了眨眼"
        : "\(interactionSubjectName) 转过身回应了你"
    } catch {
      statusMessage = "这次互动没能保存，但 \(interactionSubjectName) 已经看见你了"
    }
  }

  private var interactionSubjectName: String {
    let characterID =
      preferences.selectedCharacterIDs.first ?? CompanionVisualCatalog.defaultCharacterID
    return switch characterID {
    case "bili_22", "bili_33":
      CompanionVisualCatalog.characterDisplayName(characterID)
    default:
      "Mori"
    }
  }

  private func rebuildModel() async {
    guard selectedDataSource == .healthKit else { return }
    guard let runtime else { return }
    do {
      let state = try await runtime.currentState()
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
    model = .live(
      companion: state,
      health: latestHealth,
      peerValues: latestPeerValues
    )
  }

  private func applySelectedDataSource(requestAccessIfNeeded: Bool) async {
    mockCareTask?.cancel()
    movementSceneTask?.cancel()
    movementSceneTask = nil
    movementScene = nil
    actionCompleted = false
    if selectedDataSource.isMock {
      #if DEBUG
        model = WatchPresentationModel.demo(selectedDataSource)
        if productLoopRuntime == nil {
          await rebuildProductLoopRuntime(activateMock: true)
        } else if let productLoopRuntime {
          await refreshProductLoopSnapshot(from: productLoopRuntime)
        }
        phase = .ready
        statusMessage = "\(selectedDataSource.displayName) 已载入"
        startMovementSceneIfNeeded()
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

  private func rebuildProductLoopRuntime(
    activateMock: Bool
  ) async {
    productLoopGeneration &+= 1
    let generation = productLoopGeneration
    clearProductLoopPresentation()
    guard let globalPreferenceRuntime else { return }

    do {
      let projection = try await globalPreferenceRuntime.current()
      let authority =
        try await globalPreferenceRuntime.currentChatAuthority()
      apply(projection)
      let facade = try ProductLoopAppRuntime(
        applicationSupportURL: applicationSupportURL,
        profile: authority.profile,
        sensing: Self.sensingPreference(from: projection),
        originDeviceID: "watch"
      )
      guard generation == productLoopGeneration else { return }
      productLoopRuntime = facade
      guard
        activateMock,
        authority.profile.isMock,
        model.allowsInteraction
      else {
        return
      }
      _ = try await facade.reconcileSensing(
        Self.sensingPreference(from: projection),
        effectiveAt: Date()
      )
      _ = try await facade.activate()
      guard generation == productLoopGeneration else { return }
      await refreshProductLoopSnapshot(from: facade)
    } catch {
      guard generation == productLoopGeneration else { return }
      productLoopRuntime = nil
      clearProductLoopPresentation()
      if model.invalidMockID != nil {
        statusMessage = "Mock 场景无效，Mori 不会生成任务或提醒"
      } else {
        statusMessage = "Mori 的本地记录暂时无法载入"
      }
    }
  }

  private func stopProductLoopRuntime() {
    productLoopGeneration &+= 1
    productLoopRuntime = nil
    activeGlance = nil
    hasSeededMockGlance = false
    clearProductLoopPresentation()
  }

  private func clearProductLoopPresentation() {
    suggestedTaskID = nil
    suggestedTaskCompletionDate = nil
    hasSuggestedAction = false
    suggestedActionReward = 0
    actionCompleted = false
    coinBalance = 0
  }

  private func refreshProductLoopSnapshot(
    from runtime: ProductLoopAppRuntime
  ) async {
    let generation = productLoopGeneration
    do {
      let snapshot = try await runtime.snapshot()
      guard
        generation == productLoopGeneration,
        productLoopRuntime?.profile == runtime.profile
      else { return }
      applyProductLoopSnapshot(snapshot)
    } catch {
      guard generation == productLoopGeneration else { return }
      clearProductLoopPresentation()
      statusMessage = "Mori 的本地记录暂时无法显示"
    }
  }

  private func applyProductLoopSnapshot(
    _ snapshot: ProductLoopAppSnapshot
  ) {
    let tasks = snapshot.localState.tasks.sorted {
      let lhsActive = Self.isActive($0.lifecycle)
      let rhsActive = Self.isActive($1.lifecycle)
      if lhsActive != rhsActive {
        return lhsActive && !rhsActive
      }
      if $0.recommendationPriority != $1.recommendationPriority {
        return $0.recommendationPriority > $1.recommendationPriority
      }
      if $0.issuedRevision != $1.issuedRevision {
        return $0.issuedRevision > $1.issuedRevision
      }
      return $0.header.recordID < $1.header.recordID
    }
    let task = tasks.first
    suggestedTaskID = task?.header.recordID
    suggestedTaskCompletionDate = task?.issuedAt
    suggestedActionReward = task?.rewardTier.rawValue ?? 0
    hasSuggestedAction =
      task?.completionPolicy == .userConfirmation
    actionCompleted = task?.lifecycle.isCompleted ?? false
    coinBalance = snapshot.localState.coinLedger.balance
  }

  private static func isActive(
    _ lifecycle: TaskLifecycleState
  ) -> Bool {
    if case .active = lifecycle { return true }
    return false
  }

  private func removeRetiredMockNamespace(
    _ runtime: ProductLoopAppRuntime?
  ) throws {
    guard let runtime, runtime.profile.isMock else { return }
    let layout = try RuntimeStorageLayout(
      applicationSupportURL: applicationSupportURL
    )
    let expected = try layout.namespace(for: runtime.profile)
    guard
      expected.rootURL.standardizedFileURL
        == runtime.namespaceRootURL.standardizedFileURL
    else {
      throw RuntimeStorageError.targetOutsideOwnedNamespace
    }
    let fileManager = FileManager()
    guard fileManager.fileExists(atPath: expected.rootURL.path) else {
      return
    }
    try fileManager.removeItem(at: expected.rootURL)
  }

  private func foregroundDate(
    from state: ProfileState
  ) -> Date {
    let newestObservedAt =
      state.passiveEvents
      .filter {
        if case .pending = $0.reminderState { return true }
        return false
      }
      .map(\.observedAt)
      .max()
    #if DEBUG
      if let newestObservedAt {
        return newestObservedAt.addingTimeInterval(
          mockGlanceSeed?.age ?? 0
        )
      }
    #endif
    return newestObservedAt ?? Date()
  }

  private static func watchGlance(
    from value: PendingGlancePresentation
  ) -> WatchGlancePresentation {
    let message: String
    let reaction: WatchCharacterAnimation
    switch value.eventKind {
    case .sharedWalk:
      message = "我们已经一起走了 3,250 步。"
      reaction = .idleLively
    case .fastPace:
      message = "刚才那段路走得好快，我差点跟不上。"
      reaction = .idleCurious
    case .pausedTogether:
      message = "你停下来的时候，我也坐了一会儿。"
      reaction = .idleResting
    case .arrivedAtApprovedPlace:
      message = "我们到了一个熟悉的地方。"
      reaction = .idleCurious
    case .sleepReflection:
      message = "昨晚我们一起休息了一段时间。"
      reaction = .idleResting
    case .foregroundGreeting:
      message = "我在这里，今天也可以慢慢来。"
      reaction = .idleLively
    }
    return WatchGlancePresentation(
      id: value.eventID.rawValue,
      message: message,
      reaction: reaction,
      shouldPlayHaptic: value.shouldPlayHaptic
    )
  }

  #if DEBUG
    private func seedMockGlancesIfNeeded(
      runtime: ProductLoopAppRuntime
    ) async throws {
      guard
        !hasSeededMockGlance,
        let mockGlanceSeed,
        mockGlanceSeed.values.isEmpty == false
      else { return }
      let snapshot = try await runtime.snapshot()
      let state = snapshot.localState
      guard
        let fact = state.derivedFacts.first(where: {
          $0.authorizesCompanionUse(
            in: state.currentSensingEpoch
          )
        })
      else { return }
      let base =
        state.passiveEvents.map(\.observedAt).max()
        ?? fact.observedAt
      let profile = runtime.profile
      let origin = "watch-ui-test"
      let envelopeCodec = ExperienceEnvelopeCodec()
      let envelopes = mockGlanceSeed.values.enumerated().map {
        index,
        value -> ExperienceSyncEnvelope in
        let observedAt = base.addingTimeInterval(
          TimeInterval(index + 1)
        )
        let revision = LamportRevision(
          counter: UInt64(10_000 + index),
          originDeviceID: origin
        )
        let event = PassiveCompanionEvent(
          header: ProfileScopedRecordHeader(
            recordID: EventID(
              "watch-ui-glance-\(index)-\(value)"
            ),
            profileID: profile.id,
            profileEpoch: profile.epoch,
            deletionEpoch: profile.deletionEpoch
          ),
          sensingEpoch: state.currentSensingEpoch,
          kind: Self.mockGlanceKind(value),
          observedAt: observedAt,
          confidence: .exact,
          evidence: [
            EvidenceReference(
              id: fact.header.recordID,
              kind: fact.value.kind
            )
          ],
          presentationDeadline:
            observedAt.addingTimeInterval(2 * 60),
          replacementKey: "watch-ui-latest",
          taskCooldownKey: nil,
          memoryEligibility: .ineligible,
          sceneID: nil,
          moriActionID: "watch-ui.\(value)",
          reminderRevision: revision
        )
        return ExperienceSyncEnvelope(
          eventID: ExperienceEventID(
            "watch-ui-glance-envelope-\(index)-\(value)"
          ),
          eventType: .passiveEvent,
          profileID: profile.id,
          profileEpoch: profile.epoch,
          deletionEpoch: profile.deletionEpoch,
          profileSource: profile.source,
          originDeviceID: origin,
          originSequence: UInt64(index + 1),
          revision: revision,
          observedAt: observedAt,
          authoredAt: observedAt,
          privacyClass: .approvedDerived,
          tombstone: nil,
          sourceEventID: nil,
          settlementID: nil,
          payload: .passiveEvent(event)
        )
      }
      let transfer = ExperienceSyncTransfer(
        scope: ExperienceSyncScope(profile: profile),
        envelopeBytes: try envelopes.map(envelopeCodec.encode)
      )
      _ = try await runtime.receive(
        ExperienceSyncWireCodec().encode(transfer)
      )
      hasSeededMockGlance = true
    }

    private static func mockGlanceKind(
      _ value: String
    ) -> PassiveEventKind {
      switch value {
      case "shared-walk":
        .sharedWalk
      case "paused":
        .pausedTogether
      default:
        .fastPace
      }
    }

    private func startMovementSceneIfNeeded() {
      movementSceneTask?.cancel()
      movementSceneTask = nil
      movementScene = nil
      guard
        model.mockScenario?.id == CompanionDataSource.mock4.fixtureID,
        let timeline = model.mockScenario?.reactiveSceneTimeline
      else { return }

      let startedAt = Date()
      movementSceneTask = Task { [weak self] in
        while !Task.isCancelled {
          guard let self else { return }
          let telemetry = timeline.telemetry(
            at: Date().timeIntervalSince(startedAt)
          )
          let next = MovementScenePresentation(telemetry: telemetry)
          if self.movementScene != next {
            self.movementScene = next
          }
          try? await Task.sleep(for: .milliseconds(250))
        }
      }
    }

    private func scheduleMockCareIfNeeded() {
      guard selectedDataSource.simulatesPeerExchange else { return }
      mockCareTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(60))
        guard
          !Task.isCancelled,
          let self,
          self.selectedDataSource.simulatesPeerExchange
        else { return }
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

  /// Applies the retained iPhone application context before the Watch becomes interactive.
  /// This preserves the no-setup default while ensuring a previously synchronized opt-out wins
  /// over a fresh Watch installation's local default.
  private func applyLatestPhonePreferencesIfAvailable(
    runtime: AppleCompanionRuntime
  ) async throws {
    guard let values = await runtime.latestPeerValues() else { return }
    let shouldReloadDataSource = try await runtime.applyPeerPreferences(values)
    preferences = try await runtime.loadPreferences()
    latestPeerValues = Self.peerValues(from: preferences)
    if shouldReloadDataSource,
      let rawValue = values["dataSource"],
      let incoming = CompanionDataSource(rawValue: rawValue)
    {
      selectedDataSource = incoming
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

    private static func mockGlanceSeed(
      from arguments: [String]
    ) -> MockGlanceSeed? {
      guard arguments.contains("-UITesting") else { return nil }
      let eventValues =
        arguments.first(where: { $0.hasPrefix("--mock-glance=") })?
        .replacingOccurrences(of: "--mock-glance=", with: "")
        .split(separator: ",")
        .map(String.init) ?? []
      guard eventValues.isEmpty == false else { return nil }
      let age =
        arguments.first(where: { $0.hasPrefix("--mock-glance-age=") })
        .flatMap {
          TimeInterval(
            $0.replacingOccurrences(of: "--mock-glance-age=", with: "")
          )
        } ?? 0
      return MockGlanceSeed(
        values: eventValues,
        age: max(0, age)
      )
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
