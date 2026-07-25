import AppRuntime
import Combine
import CryptoKit
import Domain
import Foundation
import Persistence
import MoriDomain
import MoriRuntime
import SwiftUI

enum PhoneAppPhase: Equatable {
  case loading
  case onboarding
  case ready
}

private struct PendingConversationWarning {
  let text: String
  let requestID: String
  let clientTurnID: String
}

@MainActor
final class PhoneAppStore: ObservableObject {
  @Published private(set) var model: PhonePresentationModel
  @Published private(set) var preferences = AppPreferences()
  @Published private(set) var phase: PhoneAppPhase
  @Published private(set) var selectedDataSource: CompanionDataSource
  @Published var selectedTab: PhoneTab
  @Published var notificationDestination: RuntimeNotificationDestination?
  @Published var isShowingSettings = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var notificationStatus = "尚未请求"
  @Published private(set) var weeklyMemories: [PhoneWeeklyMemory] = []
  @Published private(set) var isPreparingWeeklyMemory = false
  @Published private(set) var weeklyMemoryStatus: String?
  @Published private(set) var isPersonalizationEnabled = true
  @Published private(set) var isClearingPersonalization = false
  @Published private(set) var personalizationStatus: String?
  @Published private(set) var chatNudge: MoriChatNudge?
  let chatRequiresExternalAIConsent: Bool
  @Published private(set) var isRefreshingHealth = false
  @Published private(set) var isSavingPreferences = false
  @Published private(set) var isSavingMockExperience = false
  @Published private(set) var mockExperience = PhoneMockExperienceProjection.empty
  @Published private(set) var companionSensingEnabled = true
  @Published private(set) var reminderMode: CompanionReminderMode = .wristRaise
  @Published private(set) var quietHours = CompanionQuietHours(
    startMinute: 22 * 60,
    endMinute: 7 * 60
  )
  @Published private(set) var isSavingCompanionPreferences = false
  @Published private(set) var isShowingDeleteAllConfirmation = false
  @Published private(set) var isDeletingAllMoriData = false
  @Published private(set) var isSwitchingDataSource = false
  @Published private(set) var isShowingClearConversationConfirmation = false
  @Published private(set) var conversation = PhoneConversationPresentation.empty

  var dataMode: PhoneDataMode { model.dataMode }
  var dataSourceSelectionAvailable: Bool { !hasLaunchScenarioOverride }
  var companionExperienceAvailable: Bool {
    #if DEBUG
      selectedDataSource.isMock
        && model.allowsInteraction
        && isSwitchingDataSource == false
    #else
      false
    #endif
  }
  var activeCoinBalance: Int {
    model.isLive ? 0 : mockExperience.coinBalance
  }
  var selectedSceneID: String {
    model.isLive
      ? preferences.selectedBackgroundID
      : mockExperience.selectedSceneID
  }
  var selectedCharacterID: String {
    CompanionVisualCatalog.defaultCharacterID
  }

  private let runtime: AppleCompanionRuntime?
  private let globalPreferenceRuntime: MoriGlobalPreferenceRuntime?
  private let notificationRouteObserver: RuntimeNotificationRouteObserver?
  private let launchNotificationRoute: RuntimeNotificationRoute?
  private let usesE2EOfflineRuntime: Bool
  private let hasLaunchScenarioOverride: Bool
  private let mockSystemNotificationsEnabled: Bool
  private let weeklyMemoryArchive: WeeklyMemoryArchiveStore
  private let weeklyMemoryPolisher: WeeklyMemoryPolishing
  private let chatReplying: any MoriChatReplying
  private let chatNudgePolicy: MoriChatNudgePolicy
  private let personalizationRepository: any PersonalizationRepositoryProtocol
  private let runtimeStorageDirectory: URL
  private var hasStarted = false
  private var hasLoadedPersonalization = false
  private var personalityProjection = WeeklyMemoryAIPersonalityProjection.moriCore
  private var latestHealth: HealthSnapshot?
  private var authoritativeProfileSource: MoriGlobalProfileSource?
  private var authoritativeProfileScope: MoriGlobalProfileScope?
  private var authoritativeSensingScope: MoriGlobalSensingScope?
  private var preferenceSaveTask: Task<Void, Never>?
  private var preferenceRevision: UInt64 = 0
  private var notificationRouteTask: Task<Void, Never>?
  private var peerSyncRetryTask: Task<Void, Never>?
  private var peerUpdateTask: Task<Void, Never>?
  private var mockCareTask: Task<Void, Never>?
  private var personalizationMutationTask: Task<Void, Never>?
  private var chatNudgeTask: Task<Void, Never>?
  private var deletedWeeklyMemoryIDs: Set<String> = []
  private var companionInteractionRevision: UInt64 = 0
  private var companionPreferenceWritesInFlight = 0
  private var pendingDeletionProfileScope: MoriGlobalProfileScope?
  private var pendingDeletionRequestID: String?
  private var conversationProcessor: ConversationProcessor?
  private var conversationProfileScope: MoriGlobalProfileScope?
  #if DEBUG
    private var mockChatAuthority: PhoneMockChatAuthority?
  #endif
  private var conversationSendTask:
    Task<
      ConversationPresentationState,
      Never
    >?
  private var activeConversationRequestID: String?
  private var pendingConversationWarning: PendingConversationWarning?
  private var memoryContextWriteTask: Task<Void, Never>?
  private var memoryContextWriteRevision: UInt64 = 0
  #if DEBUG
    private let mockProfileSettingsRepository:
      PhoneMockProfileSettingsRepository
    private let mockChatBehavior: DeterministicMockChatBehavior
    private var productLoopRuntime: ProductLoopAppRuntime?
    private var productLoopProfileScope: MoriGlobalProfileScope?
    private var productLoopSnapshot: ProductLoopAppSnapshot?
    private var productLoopGeneration: UInt64 = 0
    private var productCommandTask: Task<Void, Never>?
  #endif

  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    weeklyMemoryPolisher: WeeklyMemoryPolishing? = nil,
    chatReplying: (any MoriChatReplying)? = nil,
    chatNudgePolicy: MoriChatNudgePolicy? = nil,
    personalizationRepository: (any PersonalizationRepositoryProtocol)? = nil
  ) {
    let initialModel = PhonePresentationModel.initial(arguments: arguments)
    model = initialModel

    #if DEBUG
      let initialDataSource =
        initialModel.mockScenario.flatMap {
          CompanionDataSource(rawValue: $0.id)
        }
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
      selectedOutfitID: initialModel.wardrobe.selectedOutfitID,
      selectedCharacterIDs: [CompanionVisualCatalog.defaultCharacterID],
      selectedBackgroundID: CompanionVisualCatalog.defaultBackgroundID
    )
    hasLaunchScenarioOverride = initialModel.dataMode != .live
    phase =
      hasLaunchScenarioOverride
      ? (initialModel.initialScreen == .onboarding ? .onboarding : .ready)
      : .loading
    #if DEBUG
      if arguments.contains("-UITesting"),
        arguments.contains("--initial-tab=history")
      {
        selectedTab = .memories
      } else {
        selectedTab =
          initialModel.initialScreen == .collection ? .collection : .mori
      }
    #else
      selectedTab =
        initialModel.initialScreen == .collection ? .collection : .mori
    #endif
    #if DEBUG
      let runtimeConfiguration = Self.runtimeConfiguration(arguments: arguments)
    #else
      let runtimeConfiguration = Self.productionRuntimeConfiguration()
    #endif
    // Weekly memories are a Mock-only presentation in this phase. Keep their
    // management state isolated from live runtime storage.
    weeklyMemoryArchive = WeeklyMemoryArchiveStore(storageDirectory: nil)
    if arguments.contains("-UITesting")
      && !arguments.contains("--enable-weekly-ai")
    {
      self.weeklyMemoryPolisher = weeklyMemoryPolisher ?? LocalOnlyWeeklyMemoryPolisher()
    } else {
      self.weeklyMemoryPolisher =
        weeklyMemoryPolisher
        ?? WeeklyMemoryAIClient.live(
          storageDirectory: runtimeConfiguration.storageDirectory
            .appendingPathComponent("Personalization", isDirectory: true)
        )
    }
    let usesLocalChatFixture =
      arguments.contains("-UITesting")
      && !arguments.contains("--enable-chat-ai")
    chatRequiresExternalAIConsent =
      arguments.contains("--chat-consent=required") || !usesLocalChatFixture
    if usesLocalChatFixture {
      self.chatReplying = chatReplying ?? LocalMoriChatClient()
    } else {
      self.chatReplying = chatReplying ?? MoriChatAIClient.live()
    }
    self.chatNudgePolicy =
      chatNudgePolicy
      ?? MoriChatNudgePolicy(arguments: arguments)
    if let personalizationRepository {
      self.personalizationRepository = personalizationRepository
    } else if hasLaunchScenarioOverride {
      self.personalizationRepository = PersonalizationRepository(
        storage: InMemoryPersonalizationStorage()
      )
    } else {
      self.personalizationRepository = PersonalizationRepository(
        storage: FilePersonalizationStorage(
          fileURL: runtimeConfiguration.storageDirectory
            .appendingPathComponent("Personalization", isDirectory: true)
            .appendingPathComponent("mori-personalization-v1.json")
        )
      )
    }
    runtimeStorageDirectory = runtimeConfiguration.storageDirectory
    runtime = AppleCompanionRuntime(
      source: .phone,
      storageDirectory: runtimeConfiguration.storageDirectory,
      preferencesKey: runtimeConfiguration.preferencesKey,
      dataSourceKey: runtimeConfiguration.dataSourceKey,
      peerSyncEnabled: runtimeConfiguration.peerSyncEnabled
    )
    globalPreferenceRuntime = try? MoriGlobalPreferenceRuntime(
      storageURL: runtimeConfiguration.storageDirectory
        .appendingPathComponent("mori-global-authority-v1.json"),
      originDeviceID: "phone",
      initialProfileSource: initialGlobalProfileSource
    )
    #if DEBUG
      mockProfileSettingsRepository = PhoneMockProfileSettingsRepository(
        fileURL: runtimeConfiguration.storageDirectory
          .appendingPathComponent("phone-mock-profile-settings-v1.json")
      )
      mockChatBehavior = Self.mockChatBehavior(arguments: arguments)
    #endif
    notificationRouteObserver =
      hasLaunchScenarioOverride ? nil : RuntimeNotificationRouteObserver()
    #if DEBUG
      launchNotificationRoute =
        arguments.contains("-UITesting")
        ? Self.notificationRoute(from: arguments)
        : nil
    #else
      launchNotificationRoute = nil
    #endif
    usesE2EOfflineRuntime = !runtimeConfiguration.peerSyncEnabled
    #if DEBUG
      mockSystemNotificationsEnabled =
        !arguments.contains("-UITesting")
        || arguments.contains("--enable-mock-system-notification")
    #else
      mockSystemNotificationsEnabled = false
    #endif
  }

  var visibleWeeklyMemories: [PhoneWeeklyMemory] {
    weeklyMemories.filter { !$0.record.isHidden }
  }

  var hiddenWeeklyMemories: [PhoneWeeklyMemory] {
    weeklyMemories.filter(\.record.isHidden)
  }

  func scheduleChatNudge() {
    guard phase == .ready, chatNudge == nil, chatNudgeTask == nil else { return }
    let policy = chatNudgePolicy
    chatNudgeTask = Task { [weak self] in
      let delay = policy.isForcedVisible ? Duration.milliseconds(180) : .seconds(8)
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      guard let nudge = policy.nextNudge(at: Date()) else {
        self.chatNudgeTask = nil
        return
      }
      self.chatNudge = nudge
      if !policy.isForcedVisible {
        try? await Task.sleep(for: .seconds(12))
        guard !Task.isCancelled, self.chatNudge?.id == nudge.id else { return }
        self.chatNudge = nil
      }
      self.chatNudgeTask = nil
    }
  }

  func openChatNudge() -> MoriChatNudge {
    let nudge = chatNudge ?? .gentle
    chatNudge = nil
    chatNudgeTask?.cancel()
    chatNudgeTask = nil
    return nudge
  }

  func replyToMoriChat(messages: [MoriChatMessage]) async -> MoriChatReply {
    await loadPersonalization()
    let personality = isPersonalizationEnabled ? personalityProjection : .moriCore
    return await chatReplying.reply(to: messages, personality: personality)
  }

  func prepareWeeklyMemory(force: Bool = false) async {
    guard phase == .ready, !isPreparingWeeklyMemory else { return }
    isPreparingWeeklyMemory = true
    defer { isPreparingWeeklyMemory = false }
    do {
      let archivedMemories = try await weeklyMemoryArchive.load()
      guard
        let scenario = model.mockScenario,
        scenario.id.hasPrefix("mock7_")
      else {
        weeklyMemories = []
        weeklyMemoryStatus = nil
        return
      }
      let records = WeeklyMemoryPresentationFactory().makeTimeline(model: model)
      guard !records.isEmpty else {
        weeklyMemories = []
        weeklyMemoryStatus = nil
        return
      }
      weeklyMemories = Self.weeklyMemories(
        archivedMemories,
        forScenarioID: scenario.id
      )
      if force {
        for record in records {
          deletedWeeklyMemoryIDs.remove(record.weekID)
        }
      }
      let personality = await personalityForWeeklyMemories(records)
      let expectedPolishContextHash = personality.cacheContextHash

      for record in records where !deletedWeeklyMemoryIDs.contains(record.weekID) {
        let isCurrent = weeklyMemories.contains {
          $0.record.weekID == record.weekID
            && $0.record.sourceHash == record.sourceHash
            && ($0.record.source != .ai
              || $0.record.polishContextHash == expectedPolishContextHash)
        }
        guard force || !isCurrent else { continue }
        _ = try await weeklyMemoryArchive.upsert(record)
      }
      weeklyMemories = Self.weeklyMemories(
        try await weeklyMemoryArchive.load(),
        forScenarioID: scenario.id
      )

      let polishedRecords = await weeklyMemoryPolisher.polish(
        records,
        personality: personality
      )
      for record in polishedRecords
      where
        record.source == .ai
        && !deletedWeeklyMemoryIDs.contains(record.weekID)
      {
        _ = try await weeklyMemoryArchive.upsert(record)
      }
      weeklyMemories = Self.weeklyMemories(
        try await weeklyMemoryArchive.load(),
        forScenarioID: scenario.id
      )
      weeklyMemoryStatus = nil
    } catch {
      weeklyMemories = Self.weeklyMemories(
        (try? await weeklyMemoryArchive.load()) ?? weeklyMemories,
        forScenarioID: model.mockScenario?.id
      )
      weeklyMemoryStatus = "暂时没能整理 Mock 周报，请再试一次"
    }
  }

  func setWeeklyMemoryFavorite(_ memory: PhoneWeeklyMemory, value: Bool) async {
    do {
      weeklyMemories = Self.weeklyMemories(
        try await weeklyMemoryArchive.setFavorite(value, weekID: memory.record.weekID),
        forScenarioID: model.mockScenario?.id
      )
      weeklyMemoryStatus = value ? "已收藏这段回忆" : "已取消收藏"
    } catch {
      weeklyMemoryStatus = "暂时没能更新收藏状态"
    }
  }

  func setWeeklyMemoryHidden(_ memory: PhoneWeeklyMemory, value: Bool) async {
    do {
      weeklyMemories = Self.weeklyMemories(
        try await weeklyMemoryArchive.setHidden(value, weekID: memory.record.weekID),
        forScenarioID: model.mockScenario?.id
      )
      weeklyMemoryStatus = value ? "已从回忆册隐藏" : "这段回忆已回到回忆册"
    } catch {
      weeklyMemoryStatus = "暂时没能更新回忆状态"
    }
  }

  func deleteWeeklyMemory(_ memory: PhoneWeeklyMemory) async {
    do {
      weeklyMemories = Self.weeklyMemories(
        try await weeklyMemoryArchive.delete(weekID: memory.record.weekID),
        forScenarioID: model.mockScenario?.id
      )
      deletedWeeklyMemoryIDs.insert(memory.record.weekID)
      weeklyMemoryStatus = "这段回忆记录已从本次 Mock 演示删除"
    } catch {
      weeklyMemoryStatus = "暂时没能删除这段回忆"
    }
  }

  static func weeklyMemories(
    _ memories: [PhoneWeeklyMemory],
    forScenarioID scenarioID: String?
  ) -> [PhoneWeeklyMemory] {
    guard let scenarioID, scenarioID.hasPrefix("mock7_") else { return [] }
    return memories.filter { $0.record.weekID.hasPrefix("\(scenarioID)-") }
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    await loadPersonalization()
    await loadGlobalPreferences()
    if hasLaunchScenarioOverride {
      await loadMockExperience()
    }
    await configureConversation()
    if let launchNotificationRoute {
      handleNotificationRoute(launchNotificationRoute)
    }
    guard !hasLaunchScenarioOverride else { return }
    observeNotificationRoutes()
    guard let runtime else {
      phase = .ready
      return
    }
    do {
      preferences = try await runtime.loadPreferences()
      let legacyDataSource = await runtime.loadDataSourceSelection()
      selectedDataSource =
        authoritativeProfileSource.flatMap(Self.dataSource(from:))
        ?? legacyDataSource
      if selectedDataSource != legacyDataSource {
        _ = await runtime.saveDataSourceSelection(selectedDataSource)
      }
      notificationStatus = await notificationStatusText()
      guard preferences.hasCompletedOnboarding else {
        #if DEBUG
          if selectedDataSource.isMock {
            model = PhonePresentationModel.demo(selectedDataSource)
            await loadMockExperience()
          }
        #endif
        phase = .onboarding
        statusMessage = "先认识 Mori；不会自动请求健康或通知权限"
        return
      }
      phase = .ready
      await applySelectedDataSource(requestAccessIfNeeded: false)
      guard !usesE2EOfflineRuntime else { return }
      retryPeerSyncInBackground(runtime: runtime)
    } catch {
      phase = .ready
      statusMessage = "载入失败，请稍后重试"
    }
  }

  func connectHealth() async {
    await selectDataSource(.healthKit)
  }

  func completeOnboarding() async {
    guard phase == .onboarding, !isSavingPreferences else { return }
    if hasLaunchScenarioOverride {
      preferences.hasCompletedOnboarding = true
      phase = .ready
      selectedTab = .mori
      statusMessage = "Mori 已准备好；Mock 不会请求系统权限"
      return
    }
    guard let runtime else {
      preferences.hasCompletedOnboarding = true
      phase = .ready
      selectedTab = .mori
      return
    }
    isSavingPreferences = true
    preferences.hasCompletedOnboarding = true
    do {
      _ = try await runtime.savePreferences(preferences)
      phase = .ready
      selectedTab = .mori
      await applySelectedDataSource(requestAccessIfNeeded: false)
      statusMessage =
        selectedDataSource.isMock
        ? "Mori 已准备好；\(selectedDataSource.displayName) 已载入"
        : "Mori 已准备好；健康数据可以稍后再连接"
    } catch {
      preferences.hasCompletedOnboarding = false
      statusMessage = "暂时没能保存，请再试一次"
    }
    isSavingPreferences = false
  }

  func selectDataSource(_ source: CompanionDataSource) async {
    guard
      !hasLaunchScenarioOverride,
      !isSwitchingDataSource,
      source != selectedDataSource
    else {
      return
    }
    isSwitchingDataSource = true
    defer { isSwitchingDataSource = false }
    mockCareTask?.cancel()
    companionInteractionRevision &+= 1
    await runtime?.cancelMockCareNotification()
    retireProductLoop()
    await stopConversationRuntime(clearPresentation: true)
    do {
      try await selectGlobalProfile(for: source)
    } catch {
      await configureConversation()
      statusMessage = "数据模式暂时没能保存"
      return
    }
    selectedDataSource = source
    if let runtime {
      _ = await runtime.saveDataSourceSelection(source)
    }
    await applySelectedDataSource(requestAccessIfNeeded: source == .healthKit)
    await configureConversation()
  }

  func refreshHealth(requestAccessIfNeeded: Bool = false) async {
    guard
      selectedDataSource == .healthKit,
      let runtime,
      !isRefreshingHealth
    else {
      return
    }
    isRefreshingHealth = true
    defer { isRefreshingHealth = false }
    do {
      let refresh = try await runtime.refreshHealth(
        requestAccessIfNeeded: requestAccessIfNeeded
      )
      guard selectedDataSource == .healthKit else { return }
      latestHealth = refresh.health
      await reinforceLivePersonalization(
        latestSnapshot: refresh.health,
        runtime: runtime
      )
      model = .live(
        companion: refresh.companion,
        health: refresh.health
      )
      statusMessage =
        refresh.health.hasAnyMetric
        ? "健康记录已更新"
        : "当前没有可用健康记录"
    } catch {
      guard selectedDataSource == .healthKit else { return }
      statusMessage = "健康记录暂时不可用"
    }
  }

  func companionInteraction(_ interaction: PhonePetInteraction) async {
    companionInteractionRevision &+= 1
    let revision = companionInteractionRevision
    if selectedDataSource.isMock || hasLaunchScenarioOverride {
      statusMessage = interaction.statusMessage
      return
    }
    guard let runtime else { return }
    do {
      let state = try await runtime.recordPetInteraction(kind: interaction.rawValue)
      guard revision == companionInteractionRevision, selectedDataSource == .healthKit else {
        return
      }
      model = .live(
        companion: state,
        health: latestHealth
      )
      statusMessage = interaction.statusMessage
    } catch {
      guard revision == companionInteractionRevision, selectedDataSource == .healthKit else {
        return
      }
      statusMessage = "这次互动没能保存，但 Mori 已经看见你了"
    }
  }

  func completeRecommendedTask() async {
    guard !model.isLive, model.allowsInteraction else {
      statusMessage = "真实任务账本尚未接入"
      return
    }
    #if DEBUG
      guard
        let profile = activeMockProfile,
        let task = mockExperience.recommendedTask,
        let productRuntime = productLoopRuntime,
        productLoopProfileScope == profile
      else {
        statusMessage = "当前没有可确认的 Mock 任务"
        return
      }
      let generation = productLoopGeneration
      isSavingMockExperience = true
      let command = Task { [weak self] in
        guard let self else { return }
        do {
          let settlement = try await productRuntime.completeTask(
            taskID: TaskID(task.id),
            method: .userConfirmed,
            at: Date()
          )
          try Task.checkCancellation()
          guard
            self.productLoopMatches(
              profile: profile,
              generation: generation
            )
          else {
            return
          }
          try await self.refreshProductLoopSnapshot(
            productRuntime,
            profile: profile,
            generation: generation
          )
          self.statusMessage =
            settlement.didRecordReward
            ? "已经记下，获得 \(task.reward) 枚金币"
            : "这件小事已经记下，金币不会重复增加"
        } catch is CancellationError {
          return
        } catch {
          guard
            self.productLoopMatches(
              profile: profile,
              generation: generation
            )
          else {
            return
          }
          self.statusMessage = "这件小事暂时没能保存"
        }
      }
      productCommandTask = command
      await command.value
      if productLoopMatches(profile: profile, generation: generation) {
        productCommandTask = nil
        isSavingMockExperience = false
      }
    #endif
  }

  func purchase(_ item: PhoneCollectionItem) async {
    guard !model.isLive, model.allowsInteraction else {
      statusMessage = "真实收藏账本尚未接入"
      return
    }
    #if DEBUG
      guard
        let profile = activeMockProfile,
        let productRuntime = productLoopRuntime,
        productLoopProfileScope == profile
      else {
        statusMessage = "当前 Mock profile 不可用"
        return
      }
      let generation = productLoopGeneration
      let operationID = stableCollectionOperationID(
        kind: "purchase",
        profile: profile,
        itemID: item.id
      )
      isSavingMockExperience = true
      let command = Task { [weak self] in
        guard let self else { return }
        do {
          let result = try await productRuntime.purchase(
            cosmeticID: CosmeticID(item.id),
            operationID: operationID,
            at: Date()
          )
          try Task.checkCancellation()
          guard
            self.productLoopMatches(
              profile: profile,
              generation: generation
            )
          else {
            return
          }
          try await self.refreshProductLoopSnapshot(
            productRuntime,
            profile: profile,
            generation: generation
          )
          self.statusMessage =
            result.didRecordPurchase
            ? "已收藏 \(item.title)"
            : "\(item.title) 已经在收藏中"
        } catch let error as CollectionMutationRuntimeError {
          guard
            self.productLoopMatches(
              profile: profile,
              generation: generation
            )
          else {
            return
          }
          if case .insufficientBalance(let required, let available) = error {
            self.statusMessage = "还差 \(max(0, required - available)) 枚金币"
          } else {
            self.statusMessage = "购买暂时没能保存"
          }
        } catch is CancellationError {
          return
        } catch {
          guard
            self.productLoopMatches(
              profile: profile,
              generation: generation
            )
          else {
            return
          }
          self.statusMessage = "购买暂时没能保存"
        }
      }
      productCommandTask = command
      await command.value
      if productLoopMatches(profile: profile, generation: generation) {
        productCommandTask = nil
        isSavingMockExperience = false
      }
    #endif
  }

  func equip(_ item: PhoneCollectionItem) async {
    guard !model.isLive, model.allowsInteraction else {
      statusMessage = "真实收藏账本尚未接入"
      return
    }
    #if DEBUG
      guard
        let profile = activeMockProfile,
        let productRuntime = productLoopRuntime,
        let snapshot = productLoopSnapshot,
        productLoopProfileScope == profile
      else {
        statusMessage = "当前 Mock profile 不可用"
        return
      }
      let generation = productLoopGeneration
      let slot = collectionSlot(for: item)
      let priorTransitionID =
        snapshot.localState.collection.equipped[slot]?
        .transitionID.rawValue ?? "none"
      let operationID = stableCollectionOperationID(
        kind: "equip",
        profile: profile,
        itemID: "\(slot.rawValue).\(priorTransitionID).\(item.id)"
      )
      isSavingMockExperience = true
      let command = Task { [weak self] in
        guard let self else { return }
        do {
          let result = try await productRuntime.equip(
            cosmeticID: CosmeticID(item.id),
            operationID: operationID,
            at: Date()
          )
          try Task.checkCancellation()
          guard
            self.productLoopMatches(
              profile: profile,
              generation: generation
            )
          else {
            return
          }
          try await self.refreshProductLoopSnapshot(
            productRuntime,
            profile: profile,
            generation: generation
          )
          guard result.isEquipped else {
            self.statusMessage = "装备状态已经变化，请再试一次"
            return
          }
          self.statusMessage =
            item.sceneID == nil
            ? "已装备 \(item.title)"
            : "场景已切换为 \(item.title)"
        } catch is CancellationError {
          return
        } catch {
          guard
            self.productLoopMatches(
              profile: profile,
              generation: generation
            )
          else {
            return
          }
          self.statusMessage = "请先收藏这件物品"
        }
      }
      productCommandTask = command
      await command.value
      if productLoopMatches(profile: profile, generation: generation) {
        productCommandTask = nil
        isSavingMockExperience = false
      }
    #endif
  }

  func setConversationDraft(_ value: String) {
    // Chat drafts remain presentation-only. Persisting arbitrary text before
    // the credential scanner runs would retain blocked secrets across launch.
    conversation.draft = value
  }

  func sendConversationMessage(
    _ rawText: String,
    confirmedWarnings: Bool = false,
    requestID: String? = nil,
    clientTurnID: String? = nil
  ) async {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.isEmpty == false else { return }
    guard let processor = conversationProcessor else {
      statusMessage =
        model.isLive
        ? "正式对话服务尚未接入"
        : "本机对话暂时无法载入"
      return
    }
    guard
      conversation.phase.isBusy == false,
      activeConversationRequestID == nil,
      isSwitchingDataSource == false
    else {
      return
    }
    let capturedProfile = conversationProfileScope
    let actualRequestID = requestID ?? UUID().uuidString.lowercased()
    let actualClientTurnID =
      clientTurnID ?? UUID().uuidString.lowercased()
    activeConversationRequestID = actualRequestID
    let context = conversationContext()
    let task = Task {
      await processor.send(
        text,
        appContext: context,
        mode: conversationTransportMode,
        confirmedWarnings: confirmedWarnings,
        requestID: actualRequestID,
        clientTurnID: actualClientTurnID
      ) { [weak self] state in
        await self?.applyConversation(
          state,
          expectedProfile: capturedProfile,
          requestID: actualRequestID
        )
      }
    }
    conversationSendTask = task
    let result = await task.value
    guard
      conversationProfileScope == capturedProfile,
      activeConversationRequestID == actualRequestID
    else {
      return
    }
    applyConversation(result)
    conversationSendTask = nil
    activeConversationRequestID = nil
    if result.phase == .warningConfirmationRequired {
      pendingConversationWarning = PendingConversationWarning(
        text: text,
        requestID: actualRequestID,
        clientTurnID: actualClientTurnID
      )
    } else {
      pendingConversationWarning = nil
    }
  }

  func confirmConversationWarning() async {
    guard let warning = pendingConversationWarning else { return }
    await sendConversationMessage(
      warning.text,
      confirmedWarnings: true,
      requestID: warning.requestID,
      clientTurnID: warning.clientTurnID
    )
  }

  func cancelConversationWarning() {
    pendingConversationWarning = nil
    if case .warningConfirmationRequired = conversation.phase {
      conversation.phase = .idle
      conversation.warningText = nil
    }
  }

  func cancelConversationResponse() {
    guard
      let requestID = activeConversationRequestID,
      let processor = conversationProcessor
    else {
      return
    }
    Task {
      await processor.cancel(requestID: requestID)
    }
    conversationSendTask?.cancel()
  }

  func retryConversation() async {
    guard
      let requestID = conversation.pendingRetryRequestID,
      let processor = conversationProcessor,
      conversation.phase.isBusy == false,
      activeConversationRequestID == nil,
      isSwitchingDataSource == false
    else {
      return
    }
    let capturedProfile = conversationProfileScope
    activeConversationRequestID = requestID
    let task = Task {
      await processor.retry(
        requestID: requestID,
        appContext: conversationContext(),
        mode: conversationTransportMode
      ) { [weak self] state in
        await self?.applyConversation(
          state,
          expectedProfile: capturedProfile,
          requestID: requestID
        )
      }
    }
    conversationSendTask = task
    let result = await task.value
    guard
      conversationProfileScope == capturedProfile,
      activeConversationRequestID == requestID
    else {
      return
    }
    applyConversation(result)
    conversationSendTask = nil
    activeConversationRequestID = nil
  }

  func requestClearConversation() {
    guard companionExperienceAvailable else { return }
    isShowingClearConversationConfirmation = true
  }

  func cancelClearConversation() {
    isShowingClearConversationConfirmation = false
  }

  func clearConversation() async {
    guard let processor = conversationProcessor else {
      statusMessage = "对话记录暂时无法清除"
      return
    }
    isShowingClearConversationConfirmation = false
    let capturedProfile = conversationProfileScope
    if let requestID = activeConversationRequestID {
      await processor.cancel(requestID: requestID)
    }
    let sendTask = conversationSendTask
    sendTask?.cancel()
    _ = await sendTask?.value
    guard conversationProfileScope == capturedProfile else { return }
    pendingConversationWarning = nil
    let state = await processor.clear(
      requestID: "clear-\(UUID().uuidString.lowercased())"
    )
    guard conversationProfileScope == capturedProfile else { return }
    applyConversation(state)
    conversationSendTask = nil
    activeConversationRequestID = nil
    if case .failed = state.phase {
      statusMessage = "对话记录暂时没能清除"
    } else {
      statusMessage = "对话记录已清除；共同回忆仍然保留"
    }
  }

  func setMemoryContext(_ enabled: Bool) {
    let previous = conversation.memoryContextIsEnabled
    conversation.memoryContextIsEnabled = enabled
    let capturedProfile = conversationProfileScope
    memoryContextWriteRevision &+= 1
    let revision = memoryContextWriteRevision
    let previousTask = memoryContextWriteTask
    memoryContextWriteTask = Task { [weak self] in
      _ = await previousTask?.value
      guard
        let self,
        revision == memoryContextWriteRevision,
        conversationProfileScope == capturedProfile
      else {
        return
      }
      do {
        if enabled == false,
          let requestID = activeConversationRequestID,
          let processor = conversationProcessor
        {
          await processor.cancel(requestID: requestID)
          let sendTask = conversationSendTask
          sendTask?.cancel()
          _ = await sendTask?.value
          guard
            revision == memoryContextWriteRevision,
            conversationProfileScope == capturedProfile
          else {
            return
          }
          conversationSendTask = nil
          activeConversationRequestID = nil
        }
        #if DEBUG
          if selectedDataSource.isMock {
            guard
              let profile = activeMockProfile,
              profile == capturedProfile,
              let mockChatAuthority
            else {
              throw PhoneMockProfileSettingsError.invalidProfile
            }
            _ =
              try mockProfileSettingsRepository.setConversationMemoryContext(
                profile: profile,
                enabled: enabled
              )
            let authority = await mockChatAuthority.setMemoryContext(enabled)
            guard
              revision == memoryContextWriteRevision,
              conversationProfileScope == capturedProfile
            else {
              return
            }
            if enabled == false, let processor = conversationProcessor {
              applyConversation(
                await processor.clearMemoryContextIndex()
              )
            } else {
              conversation.memoryContextIsEnabled =
                authority.memoryContextIsAuthorized
            }
            return
          }
        #endif
        guard let globalPreferenceRuntime else {
          throw MoriGlobalPreferenceRuntimeError.rejectedPreference
        }
        let authority = try await globalPreferenceRuntime.setConsent(
          .memoryContext,
          enabled: enabled
        )
        guard
          revision == memoryContextWriteRevision,
          conversationProfileScope == capturedProfile
        else {
          return
        }
        if enabled == false, let processor = conversationProcessor {
          applyConversation(
            await processor.clearMemoryContextIndex()
          )
        } else {
          conversation.memoryContextIsEnabled =
            authority.memoryContextIsAuthorized
        }
      } catch {
        guard
          revision == memoryContextWriteRevision,
          conversationProfileScope == capturedProfile
        else {
          return
        }
        conversation.memoryContextIsEnabled = previous
        statusMessage = "对话记忆设置暂时没能保存"
      }
    }
  }

  func resetCurrentMockState() async {
    #if DEBUG
      guard
        selectedDataSource.isMock,
        dataSourceSelectionAvailable,
        isSwitchingDataSource == false,
        let globalPreferenceRuntime,
        let oldScope = activeMockProfile
      else {
        return
      }
      isSwitchingDataSource = true
      defer { isSwitchingDataSource = false }
      retireProductLoop()
      await stopConversationRuntime(clearPresentation: true)
      var removedOldConversationNamespace = false
      do {
        let authority = try await globalPreferenceRuntime.currentChatAuthority()
        let layout = try RuntimeStorageLayout(
          applicationSupportURL: runtimeStorageDirectory
        )
        let namespace = try layout.namespace(for: authority.profile)
        guard
          namespace.namespaceID == oldScope.storageKey,
          authority.profile.isMock
        else {
          throw RuntimeStorageError.selectionMismatch
        }
        let selection = ProfileSelectionRecord(
          profile: authority.profile,
          revision: authority.profile.epoch.revision
        )
        let selectionAuthority = try ProfileSelectionAuthority(
          initial: selection
        )
        try await SelectedMockResetService(
          layout: layout,
          selectionAuthority: selectionAuthority
        ).deleteSelectedMockNamespace(namespace: namespace)
        removedOldConversationNamespace = true
        try mockProfileSettingsRepository.remove(profile: oldScope)
        try await selectGlobalProfile(for: selectedDataSource)
      } catch {
        if removedOldConversationNamespace == false {
          await configureConversation()
        }
        statusMessage =
          removedOldConversationNamespace
          ? "旧 Mock 对话已清空；新 Mock profile 暂时没能载入，请重试"
          : "Mock profile 暂时没能重置"
        return
      }
      guard let profile = activeMockProfile else {
        statusMessage = "新的 Mock profile 不可用"
        return
      }
      model = PhonePresentationModel.demo(selectedDataSource)
      await loadMockExperience()
      guard
        activeMockProfile == profile,
        productLoopProfileScope == profile
      else {
        statusMessage = "当前 Mock 状态暂时没能重置"
        return
      }
      await configureConversation()
      statusMessage = "当前 Mock 状态已重置；真实记录未改变"
    #endif
  }

  func requestDeleteAllMoriData() {
    guard
      isDeletingAllMoriData == false,
      let profile = authoritativeProfileScope
    else {
      statusMessage = "Mori 数据状态暂时无法确认"
      return
    }
    pendingDeletionProfileScope = profile
    pendingDeletionRequestID =
      "delete-\(UUID().uuidString.lowercased())"
    isShowingDeleteAllConfirmation = true
  }

  func cancelDeleteAllMoriData() {
    guard isDeletingAllMoriData == false else { return }
    isShowingDeleteAllConfirmation = false
    pendingDeletionProfileScope = nil
    pendingDeletionRequestID = nil
  }

  func confirmDeleteAllMoriData() async {
    guard
      isDeletingAllMoriData == false,
      let expectedProfile = pendingDeletionProfileScope,
      let requestID = pendingDeletionRequestID,
      let globalPreferenceRuntime
    else {
      statusMessage = "删除请求已失效，请重新确认"
      return
    }

    isDeletingAllMoriData = true
    defer { isDeletingAllMoriData = false }
    let deletionProjection: MoriGlobalPreferenceProjection
    do {
      deletionProjection =
        try await globalPreferenceRuntime.deleteAllData(
          expectedProfileScope: expectedProfile,
          requestID: requestID
        )
    } catch {
      statusMessage = "删除围栏暂时没能建立；没有删除任何记录"
      return
    }

    pendingDeletionProfileScope = deletionProjection.profileScope
    apply(deletionProjection)
    preferenceSaveTask?.cancel()
    preferenceSaveTask = nil
    notificationRouteTask?.cancel()
    notificationRouteTask = nil
    peerSyncRetryTask?.cancel()
    peerSyncRetryTask = nil
    retireProductLoop()
    let retiringConversationProcessor = conversationProcessor
    await stopConversationRuntime(clearPresentation: false)

    var localDeletionFailed = false
    do {
      try await runtime?.deleteAllLocalData()
    } catch {
      localDeletionFailed = true
    }
    #if DEBUG
      do {
        try mockProfileSettingsRepository.deleteAll(
          fence: deletionProjection.profileScope
        )
      } catch {
        localDeletionFailed = true
      }
    #endif
    do {
      try await retiringConversationProcessor?.removeAllContent()
      try RuntimeStorageLayout(
        applicationSupportURL: runtimeStorageDirectory
      ).removeAllOwnedProfileData()
    } catch {
      localDeletionFailed = true
    }

    preferences = AppPreferences()
    mockExperience = .empty
    conversation = .empty
    conversationProcessor = nil
    conversationProfileScope = nil
    selectedDataSource = .healthKit
    model = .liveNoData()
    latestHealth = nil
    companionSensingEnabled = false
    selectedTab = .mori
    notificationDestination = nil
    isShowingSettings = false
    isShowingDeleteAllConfirmation = false
    phase = .onboarding
    pendingDeletionProfileScope = nil
    pendingDeletionRequestID = nil
    statusMessage =
      localDeletionFailed
      ? "删除围栏已建立；部分本机数据仍待重试"
      : "本机 Mori 数据已删除；Apple 健康记录和系统权限未改变，Watch 删除同步尚未接入"
  }

  func setCompanionSensingEnabled(_ enabled: Bool) {
    guard companionExperienceAvailable else { return }
    let previous = companionSensingEnabled
    let capturedProfile = authoritativeProfileScope
    companionSensingEnabled = enabled
    beginCompanionPreferenceWrite()
    Task { [weak self] in
      guard let self else { return }
      defer { endCompanionPreferenceWrite() }
      var authorityWasSaved = false
      guard let globalPreferenceRuntime else {
        companionSensingEnabled = previous
        statusMessage = "随行设置暂时没能保存"
        return
      }
      do {
        let projection =
          try await globalPreferenceRuntime.setCompanionSensing(
            enabled: enabled
          )
        authorityWasSaved = true
        guard projection.profileScope == authoritativeProfileScope else {
          return
        }
        apply(projection)
        #if DEBUG
          if
            let productRuntime = productLoopRuntime,
            productLoopProfileScope == projection.profileScope
          {
            let generation = productLoopGeneration
            _ = try await productRuntime.reconcileSensing(
              Self.sensingPreference(from: projection.sensingScope),
              effectiveAt: Date()
            )
            try await refreshProductLoopSnapshot(
              productRuntime,
              profile: projection.profileScope,
              generation: generation
            )
          } else {
            await loadMockExperience()
          }
        #endif
      } catch {
        guard authoritativeProfileScope == capturedProfile else { return }
        if authorityWasSaved {
          mockExperience = .empty
          statusMessage = "随行设置已保存；Mock 产品状态暂时无法更新"
        } else {
          companionSensingEnabled = previous
          statusMessage = "随行设置暂时没能保存"
        }
      }
    }
  }

  func setReminderMode(_ mode: CompanionReminderMode) {
    guard companionExperienceAvailable else { return }
    let previous = reminderMode
    let capturedProfile = authoritativeProfileScope
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
        let projection = try await globalPreferenceRuntime.setReminderMode(mode)
        guard projection.profileScope == authoritativeProfileScope else {
          return
        }
        apply(projection)
      } catch {
        guard authoritativeProfileScope == capturedProfile else { return }
        reminderMode = previous
        statusMessage = "提醒方式暂时没能保存"
      }
    }
  }

  func setQuietHours(startMinute: Int? = nil, endMinute: Int? = nil) {
    guard companionExperienceAvailable else { return }
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
    let capturedProfile = authoritativeProfileScope
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
        let projection = try await globalPreferenceRuntime.setQuietHours(
          candidate
        )
        guard projection.profileScope == authoritativeProfileScope else {
          return
        }
        apply(projection)
      } catch {
        guard authoritativeProfileScope == capturedProfile else { return }
        quietHours = previous
        statusMessage = "安静时段暂时没能保存"
      }
    }
  }

  func setProactiveMessages(_ enabled: Bool) {
    preferences.proactiveMessagesEnabled = enabled
    preferences.proactiveNotificationConsentVersion =
      enabled ? AppPreferences.currentNotificationConsentVersion : 0
    persistPreferences()
    let dataSource = selectedDataSource
    Task { [weak self] in
      guard let self, selectedDataSource == dataSource else { return }
      guard dataSource == .healthKit else {
        notificationStatus = "Mock 不修改系统通知"
        return
      }
      guard let runtime else { return }
      if enabled {
        let status = Self.notificationText(
          await runtime.requestNotificationPermissionStatus()
        )
        guard selectedDataSource == dataSource else { return }
        notificationStatus = status
      } else {
        await runtime.cancelProactiveNotifications()
      }
    }
  }

  func setPersonalizationEnabled(_ enabled: Bool) {
    guard isPersonalizationEnabled != enabled else { return }
    isPersonalizationEnabled = enabled
    personalizationStatus =
      enabled
      ? "Mori 会继续从明确选择、完成的活动与多日作息节奏中慢慢了解你"
      : "个性化陪伴已关闭"
    let precedingMutation = personalizationMutationTask
    let mutation = Task { [weak self] in
      await precedingMutation?.value
      guard let self else { return }
      do {
        try await self.personalizationRepository.setEnabled(enabled)
        let projection = try await self.personalizationRepository.projection()
        self.personalityProjection = WeeklyMemoryAIPersonalityProjection(
          projection: projection
        )
      } catch {
        await self.loadPersonalization(force: true)
        self.personalizationStatus = "暂时没能保存个性化设置"
      }
    }
    personalizationMutationTask = mutation
  }

  func clearPersonalization() async {
    guard !isClearingPersonalization else { return }
    isClearingPersonalization = true
    let precedingMutation = personalizationMutationTask
    let mutation = Task { [weak self] in
      await precedingMutation?.value
      guard let self else { return }
      do {
        try await self.personalizationRepository.clearLearnedData()
        let state = try await self.personalizationRepository.state()
        self.isPersonalizationEnabled = state.isEnabled
        self.personalityProjection = WeeklyMemoryAIPersonalityProjection(
          projection: state.compactProjection
        )
        self.personalizationStatus = "Mori 已忘记之前学到的偏好，并回到原来的性格"
      } catch {
        self.personalizationStatus = "暂时没能清除，请再试一次"
      }
    }
    personalizationMutationTask = mutation
    await mutation.value
    isClearingPersonalization = false
  }

  func setSocialSharing(_ enabled: Bool) {
    preferences.socialSharingEnabled = enabled
    persistPreferences()
  }

  func setPublicPetSocialState(_ state: PublicPetSocialStateV1) {
    preferences.publicPetSocialState = state
    persistPreferences()
  }

  func showSettings() {
    isShowingSettings = true
  }

  func dismissSettings() {
    isShowingSettings = false
  }

  func dismissNotificationDestination() {
    notificationDestination = nil
  }

  private func applySelectedDataSource(
    requestAccessIfNeeded: Bool
  ) async {
    if selectedDataSource.isMock {
      #if DEBUG
        model = PhonePresentationModel.demo(selectedDataSource)
        await loadMockExperience()
        phase = .ready
        statusMessage = "\(selectedDataSource.displayName) 已载入"
      #else
        selectedDataSource = .healthKit
        await refreshHealth(requestAccessIfNeeded: requestAccessIfNeeded)
      #endif
      return
    }
    retireProductLoop()
    mockExperience = .empty
    do {
      preferences = try await runtime?.loadPreferences() ?? AppPreferences()
      let state = try await runtime?.currentState() ?? CompanionState()
      model = .live(companion: state, health: latestHealth)
    } catch {
      model = .liveNoData()
    }
    await refreshHealth(requestAccessIfNeeded: requestAccessIfNeeded)
  }

  private func loadMockExperience() async {
    #if DEBUG
      retireProductLoop()
      guard selectedDataSource.isMock, model.allowsInteraction else {
        mockExperience = .empty
        return
      }
      if hasLaunchScenarioOverride {
        guard model.mockScenario?.id == selectedDataSource.rawValue else {
          mockExperience = .empty
          statusMessage = "Mock 场景无效，未创建产品数据"
          return
        }
      }
      guard
        let profile = activeMockProfile,
        let sensing = authoritativeSensingScope,
        let globalPreferenceRuntime
      else {
        mockExperience = .empty
        statusMessage = "Mock profile 或感知状态暂时无法载入"
        return
      }
      let generation = productLoopGeneration
      do {
        let authority =
          try await globalPreferenceRuntime.currentChatAuthority()
        let layout = try RuntimeStorageLayout(
          applicationSupportURL: runtimeStorageDirectory
        )
        let namespace = try layout.namespace(for: authority.profile)
        guard
          authority.profile.isMock,
          namespace.namespaceID == profile.storageKey
        else {
          throw ProductLoopAppRuntimeError.profileScopeMismatch
        }
        let productRuntime = try ProductLoopAppRuntime(
          applicationSupportURL: runtimeStorageDirectory,
          profile: authority.profile,
          sensing: Self.sensingPreference(from: sensing),
          originDeviceID: "phone"
        )
        guard productLoopMatches(profile: profile, generation: generation) else {
          return
        }
        productLoopRuntime = productRuntime
        productLoopProfileScope = profile
        _ = try await productRuntime.activate()
        _ = try await productRuntime.reconcileSensing(
          Self.sensingPreference(from: sensing),
          effectiveAt: Date()
        )
        try await refreshProductLoopSnapshot(
          productRuntime,
          profile: profile,
          generation: generation
        )
        let settings = try mockProfileSettingsRepository.settings(
          profile: profile
        )
        guard productLoopMatches(profile: profile, generation: generation) else {
          return
        }
        applyMockProfileSettings(settings)
      } catch {
        guard
          activeMockProfile == profile,
          authoritativeSensingScope == sensing,
          productLoopGeneration == generation
        else {
          return
        }
        productLoopRuntime = nil
        productLoopProfileScope = nil
        productLoopSnapshot = nil
        mockExperience = .empty
        statusMessage = "Mock 体验状态暂时无法载入"
      }
    #endif
  }

  private func persistPreferences(
    successPrefix: String = "设置已保存在本机"
  ) {
    #if DEBUG
      if selectedDataSource.isMock {
        guard let profile = activeMockProfile else {
          statusMessage = "当前 Mock profile 不可用"
          return
        }
        let value = preferences
        preferenceRevision &+= 1
        let revision = preferenceRevision
        let previousTask = preferenceSaveTask
        isSavingPreferences = true
        preferenceSaveTask = Task { [weak self] in
          await previousTask?.value
          guard let self else { return }
          guard self.activeMockProfile == profile else {
            if revision == self.preferenceRevision {
              self.isSavingPreferences = false
            }
            return
          }
          do {
            let settings =
              try self.mockProfileSettingsRepository.setAppPreferences(
                profile: profile,
                proactiveMessagesEnabled: value.proactiveMessagesEnabled,
                socialSharingEnabled: value.socialSharingEnabled,
                publicPetSocialStateRawValue:
                  value.publicPetSocialState.rawValue
              )
            guard revision == self.preferenceRevision else {
              return
            }
            guard self.activeMockProfile == profile else {
              self.isSavingPreferences = false
              return
            }
            self.applyMockProfileSettings(settings)
            self.isSavingPreferences = false
            self.statusMessage = "\(successPrefix)；Mock 与真实记录保持隔离"
          } catch {
            guard
              revision == self.preferenceRevision,
              self.activeMockProfile == profile
            else {
              return
            }
            self.isSavingPreferences = false
            self.statusMessage = "设置暂时没能保存"
          }
        }
        return
      }
    #endif
    guard !hasLaunchScenarioOverride else {
      statusMessage = "\(successPrefix)；固定 Mock 场景只保留当前会话"
      return
    }
    guard selectedDataSource == .healthKit, let runtime else {
      statusMessage = "\(successPrefix)；Mock 与真实记录保持隔离"
      return
    }
    let value = preferences
    preferenceRevision &+= 1
    let revision = preferenceRevision
    let previousTask = preferenceSaveTask
    isSavingPreferences = true
    preferenceSaveTask = Task { [weak self] in
      await previousTask?.value
      do {
        _ = try await runtime.savePreferences(value)
        guard let self, revision == self.preferenceRevision else { return }
        self.isSavingPreferences = false
        self.statusMessage = successPrefix
      } catch {
        guard let self, revision == self.preferenceRevision else { return }
        self.isSavingPreferences = false
        self.statusMessage = "设置暂时没能保存"
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

  private func stopConversationRuntime(
    clearPresentation: Bool
  ) async {
    memoryContextWriteRevision &+= 1
    let memoryTask = memoryContextWriteTask
    memoryContextWriteTask?.cancel()
    memoryContextWriteTask = nil

    let processor = conversationProcessor
    let sendTask = conversationSendTask
    if let requestID = activeConversationRequestID, let processor {
      await processor.cancel(requestID: requestID)
    }
    sendTask?.cancel()
    _ = await sendTask?.value
    _ = await memoryTask?.value

    conversationSendTask = nil
    activeConversationRequestID = nil
    pendingConversationWarning = nil
    conversationProcessor = nil
    conversationProfileScope = nil
    #if DEBUG
      mockChatAuthority = nil
    #endif
    if clearPresentation {
      conversation = .empty
    }
  }

  private func configureConversation() async {
    await stopConversationRuntime(clearPresentation: true)

    guard
      let globalPreferenceRuntime,
      let expectedScope = authoritativeProfileScope
    else {
      return
    }
    do {
      let authority = try await globalPreferenceRuntime.currentChatAuthority()
      let layout = try RuntimeStorageLayout(
        applicationSupportURL: runtimeStorageDirectory
      )
      let namespace = try layout.namespace(for: authority.profile)
      guard namespace.namespaceID == expectedScope.storageKey else {
        throw ConversationFailure.staleAuthority
      }
      try namespace.prepare()
      let repository = try ConversationRepository(
        storage: FileConversationRepositoryStorage(
          fileURL: namespace.url(for: .conversation)
        ),
        profile: authority.profile,
        originDeviceID: "phone-chat",
        configuration: conversationConfiguration
      )
      let transport: any ChatTransport
      #if DEBUG
        transport =
          authority.profile.isMock
          ? DeterministicMockChatTransport(
            behavior: mockChatBehavior,
            configuration: conversationConfiguration
          )
          : UnavailableRemoteChatTransport()
      #else
        transport = UnavailableRemoteChatTransport()
      #endif
      let chatAuthority: any ChatAuthorityProviding
      #if DEBUG
        if authority.profile.isMock {
          let settings = try mockProfileSettingsRepository.settings(
            profile: expectedScope
          )
          let localAuthority = PhoneMockChatAuthority(
            profile: authority.profile,
            memoryContextEnabled:
              settings.conversationMemoryContextEnabled
          )
          mockChatAuthority = localAuthority
          chatAuthority = localAuthority
        } else {
          mockChatAuthority = nil
          chatAuthority = globalPreferenceRuntime
        }
      #else
        chatAuthority = globalPreferenceRuntime
      #endif
      let processor = try ConversationProcessor(
        profile: authority.profile,
        repository: repository,
        authority: chatAuthority,
        transport: transport,
        configuration: conversationConfiguration
      )
      guard authoritativeProfileScope == expectedScope else { return }
      // G7 never persists arbitrary composer text. This also removes drafts
      // written by pre-G7 development builds before applying presentation.
      let draftClearState = await processor.setDraft("")
      if case .failed = draftClearState.phase {
        throw ConversationFailure.persistenceFailure
      }
      conversationProcessor = processor
      conversationProfileScope = expectedScope
      applyConversation(await processor.load())
    } catch {
      guard authoritativeProfileScope == expectedScope else { return }
      conversation = .empty
      statusMessage = "本机对话暂时无法载入"
    }
  }

  private var conversationConfiguration: ConversationRuntimeConfiguration {
    #if DEBUG
      if mockChatBehavior == .slowStream {
        ConversationRuntimeConfiguration(
          requestTimeout: 20,
          streamChunkDelay: 1
        )
      } else {
        ConversationRuntimeConfiguration(
          requestTimeout: 1,
          streamChunkDelay: 0.04
        )
      }
    #else
      .standard
    #endif
  }

  private var conversationTransportMode: ChatTransportMode {
    #if DEBUG
      if selectedDataSource.isMock {
        return .localMock
      }
    #endif
    return .remote
  }

  private func conversationContext() -> ConversationAppContextInput {
    guard
      conversation.memoryContextIsEnabled,
      let memory = model.sharedMemories.first,
      let scope = authoritativeProfileScope
    else {
      return ConversationAppContextInput(
        identity: .penguin,
        tone: .gentle
      )
    }
    let excerpt = String(
      memory.narrative.unicodeScalars.prefix(500)
    )
    return ConversationAppContextInput(
      identity: .penguin,
      tone: .gentle,
      selectedMemoryExcerpt: SelectedMemoryExcerpt(
        memoryID: MemoryID(memory.id),
        text: excerpt
      ),
      selectedMemoryRevision: LamportRevision(
        counter: scope.profileEpochCounter,
        originDeviceID: scope.profileEpochOriginDeviceID
      )
    )
  }

  private func applyConversation(
    _ state: ConversationPresentationState
  ) {
    conversation = PhoneConversationPresentation(state)
  }

  private func applyConversation(
    _ state: ConversationPresentationState,
    expectedProfile: MoriGlobalProfileScope?,
    requestID: String
  ) {
    guard
      conversationProfileScope == expectedProfile,
      activeConversationRequestID == requestID
    else {
      return
    }
    applyConversation(state)
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
    authoritativeProfileScope = projection.profileScope
    authoritativeSensingScope = projection.sensingScope
    companionSensingEnabled = projection.companionSensingEnabled
    reminderMode = projection.reminderMode
    quietHours = projection.quietHours
  }

  private func retireProductLoop() {
    #if DEBUG
      productLoopGeneration &+= 1
      productCommandTask?.cancel()
      productCommandTask = nil
      productLoopRuntime = nil
      productLoopProfileScope = nil
      productLoopSnapshot = nil
    #endif
    isSavingMockExperience = false
    mockExperience = .empty
  }

  #if DEBUG
    private var activeMockProfile: MoriGlobalProfileScope? {
      guard
        selectedDataSource.isMock,
        let profile = authoritativeProfileScope,
        profile.isMock,
        profile.mockScenarioID == selectedDataSource.rawValue
      else {
        return nil
      }
      return profile
    }

    private func productLoopMatches(
      profile: MoriGlobalProfileScope,
      generation: UInt64
    ) -> Bool {
      productLoopGeneration == generation
        && activeMockProfile == profile
    }

    private func refreshProductLoopSnapshot(
      _ runtime: ProductLoopAppRuntime,
      profile: MoriGlobalProfileScope,
      generation: UInt64
    ) async throws {
      let snapshot = try await runtime.snapshot()
      guard
        productLoopMatches(profile: profile, generation: generation),
        productLoopProfileScope == profile,
        snapshot.localState.runtimeProfile == runtime.profile
      else {
        return
      }
      productLoopSnapshot = snapshot
      mockExperience = PhoneMockExperienceProjection(
        snapshot: snapshot,
        sensingEnabled: authoritativeSensingScope?.enabled == true
      )
    }

    private func applyMockProfileSettings(
      _ settings: PhoneMockProfileSettings
    ) {
      preferences.proactiveMessagesEnabled =
        settings.proactiveMessagesEnabled
      preferences.proactiveNotificationConsentVersion =
        settings.proactiveMessagesEnabled
        ? AppPreferences.currentNotificationConsentVersion : 0
      preferences.socialSharingEnabled =
        settings.socialSharingEnabled
      preferences.publicPetSocialState =
        PublicPetSocialStateV1(
          rawValue: settings.publicPetSocialStateRawValue
        ) ?? .greeting
    }

    private func collectionSlot(
      for item: PhoneCollectionItem
    ) -> CosmeticSlot {
      switch item.category {
      case .clothing:
        .outfit
      case .accessories:
        .accessory
      case .scenes:
        .scene
      }
    }

    private func stableCollectionOperationID(
      kind: String,
      profile: MoriGlobalProfileScope,
      itemID: String
    ) -> CollectionOperationID {
      let input = "phone.\(kind).v1|\(profile.storageKey)|\(itemID)"
      let digest = SHA256.hash(data: Data(input.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
      return CollectionOperationID(
        rawValue: "phone.\(kind).\(digest)"
      )
    }

    private static func sensingPreference(
      from scope: MoriGlobalSensingScope
    ) -> CompanionSensingPreference {
      CompanionSensingPreference(
        enabled: scope.enabled,
        epoch: SensingEpoch(
          LamportRevision(
            counter: scope.epochCounter,
            originDeviceID: scope.epochOriginDeviceID
          )
        )
      )
    }
  #endif

  private func selectGlobalProfile(
    for source: CompanionDataSource
  ) async throws {
    guard let globalPreferenceRuntime else {
      throw MoriGlobalPreferenceRuntimeError.rejectedPreference
    }
    apply(
      try await globalPreferenceRuntime.selectProfile(
        source.isMock
          ? .mock(scenarioID: source.rawValue)
          : .real
      )
    )
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

  private func notificationStatusText() async -> String {
    guard let runtime else { return "Mock 不请求权限" }
    return Self.notificationText(
      await runtime.notificationPermissionStatus()
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
    guard
      let destination = NotificationRouteCoordinator().destination(for: value)
    else {
      return
    }
    selectedTab = destination == .activityMessage ? .today : .mori
    notificationDestination = destination
    statusMessage = "已处理旧版入口；没有合成内容或改变账本"
  }

  private func retryPeerSyncInBackground(runtime: AppleCompanionRuntime) {
    guard peerSyncRetryTask == nil else { return }
    peerSyncRetryTask = Task { [weak self] in
      _ = try? await runtime.retryPeerSync()
      self?.peerSyncRetryTask = nil
    }
  }

  private func loadPersonalization(force: Bool = false) async {
    guard force || !hasLoadedPersonalization else { return }
    do {
      let state = try await personalizationRepository.state()
      isPersonalizationEnabled = state.isEnabled
      personalityProjection = WeeklyMemoryAIPersonalityProjection(
        projection: state.compactProjection
      )
      hasLoadedPersonalization = true
    } catch {
      isPersonalizationEnabled = true
      personalityProjection = .moriCore
      personalizationStatus = "个性化记录暂时不可用；Mori 会保持原来的性格"
    }
  }

  private func reinforceLivePersonalization(
    latestSnapshot: HealthSnapshot,
    runtime: AppleCompanionRuntime
  ) async {
    await loadPersonalization()
    guard isPersonalizationEnabled else { return }
    do {
      let state = try await personalizationRepository.state()
      let existingEvidenceIDs = Set(
        state.memories.flatMap(\.evidence).map(\.id)
      )
      let history = try await runtime.healthSnapshotHistory()
      let signals = LivePersonalizationEvidenceFactory().make(
        latestSnapshot: latestSnapshot,
        history: history,
        excluding: existingEvidenceIDs
      )
      for value in signals {
        try await personalizationRepository.record(
          value.signal,
          at: value.observedAt
        )
      }
      let projection = try await personalizationRepository.projection()
      personalityProjection = WeeklyMemoryAIPersonalityProjection(
        projection: projection
      )
    } catch {
      // Health refresh remains usable when optional personalization persistence fails.
    }
  }

  private func personalityForWeeklyMemories(
    _ records: [ArchivedWeeklyMemory]
  ) async -> WeeklyMemoryAIPersonalityProjection {
    await loadPersonalization()
    guard isPersonalizationEnabled else { return .moriCore }
    // Selectable debug Mock sources must not reinforce the owner's durable live profile.
    guard hasLaunchScenarioOverride || !selectedDataSource.isMock else {
      return personalityProjection
    }
    do {
      let state = try await personalizationRepository.state()
      let existingEvidenceIDs = Set(
        state.memories.flatMap(\.evidence).map(\.id)
      )
      for record in records {
        guard let facts = record.facts else { continue }
        if let activityKind = facts.activityKind,
          let duration = facts.activityDurationMinutes,
          let activity = Self.personalizationActivity(activityKind)
        {
          let evidenceID = "weekly-workout-\(record.sourceHash)"
          if !existingEvidenceIDs.contains(evidenceID) {
            try await personalizationRepository.record(
              .verifiedWorkout(
                activity: activity,
                durationMinutes: duration,
                evidenceID: evidenceID
              ),
              at: record.createdAt
            )
          }
        }
        if let sleepRoutine = facts.sleepRoutine {
          let evidenceID = "weekly-sleep-routine-\(record.sourceHash)"
          if !existingEvidenceIDs.contains(evidenceID) {
            try await personalizationRepository.record(
              .sleepRoutine(
                band: sleepRoutine.band,
                regularity: sleepRoutine.regularity,
                sampleCount: sleepRoutine.sampleCount,
                evidenceID: evidenceID
              ),
              at: record.createdAt
            )
          }
        }
      }
      let projection = try await personalizationRepository.projection()
      let value = WeeklyMemoryAIPersonalityProjection(projection: projection)
      personalityProjection = value
      return value
    } catch {
      return personalityProjection
    }
  }

  private static func personalizationActivity(
    _ value: String
  ) -> WorkoutSummary.Activity? {
    switch value {
    case "walking": .walking
    case "running": .running
    case "cycling": .cycling
    case "football": .soccer
    case "tennis": .tennis
    case "badminton": .badminton
    case "swimming": .swimming
    case "other": .other
    default: nil
    }
  }

  private struct RuntimeConfiguration {
    let storageDirectory: URL
    let preferencesKey: String
    let dataSourceKey: String
    let peerSyncEnabled: Bool
  }

  private static func productionRuntimeConfiguration() -> RuntimeConfiguration {
    let base =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("WatchCompanion")
    return RuntimeConfiguration(
      storageDirectory: base,
      preferencesKey: "app.preferences.v1",
      dataSourceKey: "app.data-source.v1",
      peerSyncEnabled: true
    )
  }

  #if DEBUG
    private static func mockChatBehavior(
      arguments: [String]
    ) -> DeterministicMockChatBehavior {
      guard
        let rawValue = arguments.first(
          where: { $0.hasPrefix("--chat-behavior=") }
        )?.replacingOccurrences(
          of: "--chat-behavior=",
          with: ""
        )
      else {
        return .normal
      }
      return DeterministicMockChatBehavior(rawValue: rawValue) ?? .normal
    }

    private static func notificationRoute(
      from arguments: [String]
    ) -> RuntimeNotificationRoute? {
      guard
        let value = arguments.first(
          where: { $0.hasPrefix("--notification-route=") }
        )?.replacingOccurrences(
          of: "--notification-route=",
          with: ""
        ),
        !value.isEmpty
      else {
        return nil
      }
      return RuntimeNotificationRoute(route: value)
    }

    private static func runtimeConfiguration(
      arguments: [String]
    ) -> RuntimeConfiguration {
      let base =
        FileManager.default.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first
        ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("WatchCompanion")
      let usesUITesting = arguments.contains("-UITesting")
      let peerSyncEnabled =
        !(usesUITesting && arguments.contains("--e2e-offline-runtime"))
      guard
        usesUITesting,
        let identifier = e2eStorageIdentifier(arguments: arguments)
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
      let preferencesKey = "app.preferences.v1.uitests.\(identifier)"
      let dataSourceKey = "app.data-source.v1.uitests.\(identifier)"
      if arguments.contains("--reset-e2e-storage") {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removeObject(forKey: preferencesKey)
        UserDefaults.standard.removeObject(forKey: dataSourceKey)
        UserDefaults.standard.removeObject(forKey: "\(dataSourceKey).selection-token")
        UserDefaults.standard.removeObject(
          forKey: "\(dataSourceKey).mock-care-notification-token"
        )
      }
      if let seededSource = e2eDataSource(arguments: arguments) {
        UserDefaults.standard.set(
          seededSource.rawValue,
          forKey: dataSourceKey
        )
      }
      return RuntimeConfiguration(
        storageDirectory: directory,
        preferencesKey: preferencesKey,
        dataSourceKey: dataSourceKey,
        peerSyncEnabled: peerSyncEnabled
      )
    }

    private static func e2eStorageIdentifier(
      arguments: [String]
    ) -> String? {
      guard
        let identifier = arguments.first(
          where: { $0.hasPrefix("--e2e-storage-id=") }
        )?.replacingOccurrences(
          of: "--e2e-storage-id=",
          with: ""
        ),
        !identifier.isEmpty,
        identifier.allSatisfy({
          $0.isASCII
            && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        })
      else {
        return nil
      }
      return identifier
    }

    fileprivate static func e2eDataSource(
      arguments: [String]
    ) -> CompanionDataSource? {
      guard
        let rawValue = arguments.first(
          where: { $0.hasPrefix("--e2e-data-source=") }
        )?.replacingOccurrences(
          of: "--e2e-data-source=",
          with: ""
        )
      else {
        return nil
      }
      return CompanionDataSource(rawValue: rawValue)
    }
  #endif

  private static func notificationText(
    _ status: RuntimeNotificationPermissionStatus
  ) -> String {
    switch status {
    case .notRequested: "尚未请求"
    case .allowed: "已允许"
    case .denied: "已在系统中关闭"
    case .unavailable: "此设备不可用"
    }
  }
}
