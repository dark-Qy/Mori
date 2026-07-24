import AppRuntime
import AppleAdapters
import Combine
import Foundation

struct TouchExchangeLocalCard: Equatable, Sendable {
  let displayName: String
  let petAssetID: String
  let outfitAssetID: String?
  let backgroundAssetID: String?
  let socialState: PublicPetSocialStateV1

  var socialStatusText: String {
    switch socialState {
    case .greeting: "想打个招呼"
    case .walk: "想一起散步"
    case .quietCompany: "想安静陪伴"
    }
  }
}

struct TouchExchangePeerCard: Equatable, Sendable {
  let displayName: String
  let petAssetID: String
  let outfitAssetID: String?
  let backgroundAssetID: String?
  let socialState: PublicPetSocialStateV1

  var socialStatusText: String {
    switch socialState {
    case .greeting: "想打个招呼"
    case .walk: "想一起散步"
    case .quietCompany: "想安静陪伴"
    }
  }
}

enum TouchExchangeViewPhase: Equatable, Sendable {
  case idle
  case joining
  case approaching
  case preview
  case awaitingPeer
  case cancelling
  case completed
  case failed
  case cancellationUnconfirmed
  case cancelled
}

@MainActor
final class TouchExchangeViewModel: ObservableObject {
  @Published private(set) var phase: TouchExchangeViewPhase = .idle
  @Published private(set) var statusText = "双方都需要主动进入触碰交换"
  @Published private(set) var peerCard: TouchExchangePeerCard?
  @Published private(set) var canConfirm = false
  @Published private(set) var encounterWasSaved = false
  @Published private(set) var socialSharingEnabled: Bool
  @Published private(set) var transferPresentation: TouchExchangeTransferPresentation?

  var localSocialStatusText: String { localCard.socialStatusText }

  private let localCard: TouchExchangeLocalCard
  private let isDeterministicDemo: Bool
  private let isPeerFirstDemo: Bool
  private let isCancelConfirmRaceDemo: Bool
  private let demoTransferRole: PetTransferAnimationRole
  private let demoTransferEventID: String
  private let isLateTransferDemo: Bool
  private let shouldAutoCompleteDemo: Bool
  private let encounterRepository: TouchExchangeEncounterRepository
  private let defaults: UserDefaults
  private var operationTask: Task<Void, Never>?
  private var operationGeneration: UInt = 0
  private var coordinator: TouchExchangeCoordinator?
  private var rangingClient: AppleNearbyRangingClient?
  private var didRevealCard = false
  private var didSubmitConfirmation = false
  private var shouldFailNextDemoCancellation = false
  private var demoCancellationPending = false
  private var currentJoinRequestID: String?
  private var presentedTransferEventIDs: Set<String> = []

  init(
    localCard: TouchExchangeLocalCard,
    socialSharingEnabled: Bool,
    arguments: [String],
    defaults: UserDefaults = .standard,
    encounterRepository: TouchExchangeEncounterRepository? = nil
  ) {
    self.localCard = localCard
    self.defaults = defaults
    self.encounterRepository =
      encounterRepository ?? TouchExchangeEncounterRepository(defaults: defaults)
    #if DEBUG
      isDeterministicDemo =
        arguments.contains("-UITesting")
        && arguments.contains("--touch-exchange-demo")
      isPeerFirstDemo =
        isDeterministicDemo
        && arguments.contains("--touch-exchange-peer-first")
      isCancelConfirmRaceDemo =
        isDeterministicDemo
        && arguments.contains("--touch-exchange-cancel-confirm-race")
      demoTransferRole =
        arguments.contains("--touch-exchange-transfer-role=destination")
        ? .destination
        : .source
      let transferEventArgument = arguments.first {
        $0.hasPrefix("--touch-exchange-transfer-event-id=")
      }
      let requestedTransferEventID = transferEventArgument.map {
        String($0.dropFirst("--touch-exchange-transfer-event-id=".count))
      }
      demoTransferEventID =
        requestedTransferEventID?.count == 32
        ? requestedTransferEventID!
        : "0123456789abcdef0123456789abcdef"
      isLateTransferDemo =
        isDeterministicDemo
        && arguments.contains("--touch-exchange-transfer-late")
      shouldAutoCompleteDemo =
        isDeterministicDemo
        && arguments.contains("--touch-exchange-auto-complete")
      shouldFailNextDemoCancellation =
        isDeterministicDemo
        && arguments.contains("--touch-exchange-cancel-failure")
      self.socialSharingEnabled =
        socialSharingEnabled || isDeterministicDemo
    #else
      isDeterministicDemo = false
      isPeerFirstDemo = false
      isCancelConfirmRaceDemo = false
      demoTransferRole = .source
      demoTransferEventID = "0123456789abcdef0123456789abcdef"
      isLateTransferDemo = false
      shouldAutoCompleteDemo = false
      self.socialSharingEnabled = socialSharingEnabled
    #endif
    #if DEBUG
      if isDeterministicDemo,
        arguments.contains("--touch-exchange-transfer-ledger-reset")
      {
        self.encounterRepository.resetConsumedTransferEventsForTesting()
      }
    #endif
    if !self.socialSharingEnabled {
      statusText = "好友分享已关闭，可稍后在 iPhone 隐私设置中重新开启"
    }
  }

  func start() {
    guard socialSharingEnabled else {
      statusText = "好友分享已关闭，可稍后在 iPhone 隐私设置中重新开启"
      return
    }
    guard phase == .idle || phase == .failed || phase == .cancelled else { return }
    beginAttempt()
  }

  func runVisualDemoIfRequested() async {
    #if DEBUG
      guard shouldAutoCompleteDemo, phase == .idle else { return }
      start()
      try? await Task.sleep(for: .milliseconds(650))
      guard canConfirm else { return }
      confirm()
    #endif
  }

  func updateSocialSharingEnabled(_ enabled: Bool) {
    #if DEBUG
      let effectiveEnabled = enabled || isDeterministicDemo
    #else
      let effectiveEnabled = enabled
    #endif
    guard socialSharingEnabled != effectiveEnabled else { return }
    socialSharingEnabled = effectiveEnabled
    if !effectiveEnabled {
      if [.joining, .approaching, .preview, .awaitingPeer].contains(phase) {
        cancel()
      } else if phase == .idle {
        statusText = "好友分享已关闭，可稍后在 iPhone 隐私设置中重新开启"
      }
    } else if phase == .idle {
      statusText = "双方都需要主动进入触碰交换"
    }
  }

  func confirm() {
    guard canConfirm else { return }
    let generation = replaceOperation()
    didSubmitConfirmation = true
    canConfirm = false
    phase = .awaitingPeer
    statusText = "正在提交你的确认"

    #if DEBUG
      if isDeterministicDemo {
        let shouldDelayForCancelRace = isCancelConfirmRaceDemo
        operationTask = Task { [weak self] in
          let delay: Duration =
            shouldDelayForCancelRace ? .seconds(2) : .milliseconds(180)
          try? await Task.sleep(for: delay)
          guard let self, isCurrent(generation) else { return }
          completeDemoEncounter()
        }
        return
      }
    #endif

    guard let coordinator, let rangingClient else {
      phase = .failed
      statusText = "交换会话已经失效"
      return
    }
    operationTask = Task { [weak self] in
      do {
        let state = try await coordinator.confirm()
        guard let self, isCurrent(generation) else { return }
        await continueSession(
          from: state,
          coordinator: coordinator,
          rangingClient: rangingClient,
          generation: generation
        )
      } catch is CancellationError {
        return
      } catch {
        guard let self else { return }
        await fail(
          with: Self.userFacingError(error),
          coordinator: coordinator,
          rangingClient: rangingClient,
          generation: generation
        )
      }
    }
  }

  func cancel() {
    guard phase != .idle, phase != .cancelling, phase != .completed,
      phase != .cancellationUnconfirmed, phase != .cancelled
    else { return }
    let revealedCard = didRevealCard
    let oldCoordinator = coordinator
    let oldRangingClient = rangingClient
    let generation = replaceOperation()
    #if DEBUG
      let shouldSimulateRemoteCompletion =
        isCancelConfirmRaceDemo && didSubmitConfirmation && revealedCard
      let shouldSimulateCancellationFailure =
        shouldFailNextDemoCancellation && revealedCard
      if shouldSimulateCancellationFailure {
        shouldFailNextDemoCancellation = false
      }
    #endif
    canConfirm = false
    phase = .cancelling
    statusText = "正在向服务确认取消结果"

    operationTask = Task { [weak self] in
      #if DEBUG
        if shouldSimulateRemoteCompletion {
          try? await Task.sleep(for: .milliseconds(120))
          guard let self,
            let completedState = self.makeDemoCompletedState()
          else { return }
          _ = self.applyRemoteCompletionIfCurrent(
            completedState,
            generation: generation
          )
          return
        }
        if shouldSimulateCancellationFailure {
          try? await Task.sleep(for: .milliseconds(120))
          guard let self, isCurrent(generation) else { return }
          demoCancellationPending = true
          markCancellationUnconfirmed(
            coordinator: oldCoordinator,
            rangingClient: oldRangingClient,
            generation: generation
          )
          return
        }
      #endif

      do {
        let terminalState = try await Self.shutdown(
          coordinator: oldCoordinator,
          rangingClient: oldRangingClient
        )
        guard let self else { return }
        if applyRemoteCompletionIfCurrent(
          terminalState,
          generation: generation
        ) {
          return
        }
        guard isCurrent(generation) else { return }
        guard oldCoordinator == nil || terminalState?.phase == .cancelled else {
          markCancellationUnconfirmed(
            coordinator: oldCoordinator,
            rangingClient: oldRangingClient,
            generation: generation
          )
          return
        }
        coordinator = nil
        rangingClient = nil
        if let terminalState {
          apply(terminalState)
        } else {
          phase = .cancelled
          statusText =
            revealedCard
            ? "公开遇见卡预览可能已经显示，已经显示的内容无法撤回；本次交换没有完成。"
            : "已停止寻找，本次没有显示遇见卡，也没有完成交换。"
        }
        rotateJoinRequestID()
      } catch {
        guard let self else { return }
        markCancellationUnconfirmed(
          coordinator: oldCoordinator,
          rangingClient: oldRangingClient,
          generation: generation
        )
      }
    }
  }

  func cancelIfNeeded() {
    switch phase {
    case .joining, .approaching, .preview, .awaitingPeer, .failed:
      cancel()
    case .idle, .cancelling, .completed, .cancellationUnconfirmed, .cancelled:
      break
    }
  }

  func retry() {
    guard
      phase == .failed || phase == .cancellationUnconfirmed
        || phase == .cancelled
    else { return }
    beginAttempt()
  }

  private func beginAttempt() {
    let oldCoordinator = coordinator
    let oldRangingClient = rangingClient
    #if DEBUG
      let shouldRetryDemoCancellation = demoCancellationPending
    #else
      let shouldRetryDemoCancellation = false
    #endif
    let needsCleanup =
      oldCoordinator != nil || oldRangingClient != nil
      || shouldRetryDemoCancellation
    let generation = replaceOperation()
    canConfirm = false
    if needsCleanup {
      phase = .cancelling
      statusText = "正在重新确认上次交换是否已取消"
    } else if socialSharingEnabled {
      resetForStart()
    } else {
      phase = .idle
      statusText = "好友分享已关闭，可稍后在 iPhone 隐私设置中重新开启"
      return
    }

    operationTask = Task { [weak self] in
      #if DEBUG
        if shouldRetryDemoCancellation {
          try? await Task.sleep(for: .milliseconds(180))
          guard let self, isCurrent(generation) else { return }
          demoCancellationPending = false
          coordinator = nil
          rangingClient = nil
          rotateJoinRequestID()
          guard socialSharingEnabled else {
            phase = .idle
            statusText = "好友分享已关闭，可稍后在 iPhone 隐私设置中重新开启"
            return
          }
          resetForStart()
          await runDemo(generation: generation)
          return
        }
      #endif

      if needsCleanup {
        do {
          let terminalState = try await Self.shutdown(
            coordinator: oldCoordinator,
            rangingClient: oldRangingClient
          )
          guard let self else { return }
          if applyRemoteCompletionIfCurrent(
            terminalState,
            generation: generation
          ) {
            return
          }
          guard isCurrent(generation) else { return }
          guard oldCoordinator == nil || terminalState?.phase == .cancelled else {
            markCancellationUnconfirmed(
              coordinator: oldCoordinator,
              rangingClient: oldRangingClient,
              generation: generation
            )
            return
          }
          coordinator = nil
          rangingClient = nil
          rotateJoinRequestID()
          guard socialSharingEnabled else {
            phase = .idle
            statusText = "好友分享已关闭，可稍后在 iPhone 隐私设置中重新开启"
            return
          }
          resetForStart()
        } catch {
          guard let self else { return }
          markCancellationUnconfirmed(
            coordinator: oldCoordinator,
            rangingClient: oldRangingClient,
            generation: generation
          )
          return
        }
      }

      guard let self else { return }
      guard isCurrent(generation) else { return }
      guard socialSharingEnabled else {
        phase = .idle
        statusText = "好友分享已关闭，可稍后在 iPhone 隐私设置中重新开启"
        return
      }
      #if DEBUG
        if isDeterministicDemo {
          await runDemo(generation: generation)
          return
        }
      #endif
      await runLive(generation: generation)
    }
  }

  private func resetForStart() {
    peerCard = nil
    transferPresentation = nil
    canConfirm = false
    encounterWasSaved = false
    didRevealCard = false
    didSubmitConfirmation = false
    phase = .joining
    statusText = "正在自动寻找也已进入触碰交换的手表"
  }

  #if DEBUG
    private func runDemo(generation: UInt) async {
      try? await Task.sleep(for: .milliseconds(180))
      guard isCurrent(generation) else { return }
      phase = .approaching
      statusText = "请把两块手表靠近"

      try? await Task.sleep(for: .milliseconds(220))
      guard isCurrent(generation) else { return }
      let isDestination = demoTransferRole == .destination
      peerCard = TouchExchangePeerCard(
        displayName: isDestination ? "Mori" : "Nori",
        petAssetID: isDestination ? "penguin" : "polar_bear",
        outfitAssetID: "star",
        backgroundAssetID: "sunset_coast",
        socialState: .greeting
      )
      didRevealCard = true
      canConfirm = true
      if isPeerFirstDemo {
        phase = .awaitingPeer
        statusText = "对方已经确认，仍需要你的确认"
      } else {
        phase = .preview
        statusText = "已确认两块手表足够靠近"
      }
    }

    private func completeDemoEncounter() {
      guard let completedState = makeDemoCompletedState() else { return }
      apply(completedState)
      rotateJoinRequestID()
    }

    private func makeDemoCompletedState() -> EncounterState? {
      guard let peerCard else { return nil }
      let publicCard = PublicPetCardV1(
        petName: peerCard.displayName,
        characterID: peerCard.petAssetID,
        outfitID: peerCard.outfitAssetID,
        backgroundID: peerCard.backgroundAssetID,
        socialState: peerCard.socialState
      )
      let encounter = Encounter(
        id: demoTransferEventID,
        localParticipantID: Self.installationParticipantID(defaults: defaults),
        peerCard: publicCard,
        completedAt: Date()
      )
      let transferStartsAt =
        isLateTransferDemo
        ? Date().addingTimeInterval(-2)
        : Date().addingTimeInterval(0.8)
      let transferCue = PetTransferAnimationCue(
        eventID: encounter.id,
        role: demoTransferRole,
        startsAt: transferStartsAt,
        durationMilliseconds: 900
      )
      return EncounterState(
        phase: .completed,
        sessionID: "demo-touch-exchange-session",
        encounterID: encounter.id,
        transferRole: demoTransferRole,
        peerCard: publicCard,
        proximitySatisfied: true,
        localConfirmed: true,
        peerConfirmed: true,
        encounter: encounter,
        transferAnimationCue: transferCue
      )
    }
  #endif

  private func runLive(generation: UInt) async {
    guard let baseURL = Self.socialGatewayBaseURL() else {
      guard isCurrent(generation) else { return }
      phase = .failed
      statusText = "触碰交换服务尚未配置 HTTPS 地址"
      return
    }

    let rendezvousClient: HTTPSocialRendezvousClient
    do {
      rendezvousClient = try HTTPSocialRendezvousClient(baseURL: baseURL)
    } catch {
      guard isCurrent(generation) else { return }
      phase = .failed
      statusText = "触碰交换服务地址无效"
      return
    }

    let rangingClient = AppleNearbyRangingClient()
    let coordinator = TouchExchangeCoordinator(
      rangingClient: rangingClient,
      rendezvousClient: rendezvousClient
    )
    guard isCurrent(generation) else {
      await rangingClient.stop()
      return
    }
    self.coordinator = coordinator
    self.rangingClient = rangingClient

    do {
      guard await rangingClient.capability() == .preciseDistance else {
        await fail(
          with: "这块手表不支持精确近距离测量",
          coordinator: coordinator,
          rangingClient: rangingClient,
          generation: generation
        )
        return
      }
      let publicCard = PublicPetCardV1(
        petName: localCard.displayName,
        characterID: localCard.petAssetID,
        outfitID: localCard.outfitAssetID,
        backgroundID: localCard.backgroundAssetID,
        socialState: localCard.socialState
      )
      let state = try await coordinator.start(
        participantID: Self.installationParticipantID(defaults: defaults),
        publicCard: publicCard,
        joinRequestID: joinRequestID()
      )
      guard isCurrent(generation) else { return }
      await continueSession(
        from: state,
        coordinator: coordinator,
        rangingClient: rangingClient,
        generation: generation
      )
    } catch is CancellationError {
      return
    } catch {
      await fail(
        with: Self.userFacingError(error),
        coordinator: coordinator,
        rangingClient: rangingClient,
        generation: generation
      )
    }
  }

  private func continueSession(
    from initialState: EncounterState,
    coordinator: TouchExchangeCoordinator,
    rangingClient: AppleNearbyRangingClient,
    generation: UInt
  ) async {
    var state = initialState
    apply(state)

    do {
      while isCurrent(generation),
        ![EncounterPhase.completed, .failed, .cancelled].contains(state.phase)
      {
        try await Task.sleep(for: .milliseconds(250))
        state = try await coordinator.refresh()
        guard isCurrent(generation) else { return }
        apply(state)
        if state.phase == .ranging {
          state = try await coordinator.processLatestMeasurement()
          guard isCurrent(generation) else { return }
          apply(state)
        }
      }
      guard isCurrent(generation) else { return }
      await finishTerminalState(
        state,
        coordinator: coordinator,
        rangingClient: rangingClient,
        generation: generation
      )
    } catch is CancellationError {
      return
    } catch {
      await fail(
        with: Self.userFacingError(error),
        coordinator: coordinator,
        rangingClient: rangingClient,
        generation: generation
      )
    }
  }

  private func finishTerminalState(
    _ state: EncounterState,
    coordinator: TouchExchangeCoordinator,
    rangingClient: AppleNearbyRangingClient,
    generation: UInt
  ) async {
    guard state.phase == .failed else {
      await rangingClient.stop()
      guard isCurrent(generation) else { return }
      self.coordinator = nil
      self.rangingClient = nil
      if state.phase == .completed || state.phase == .cancelled {
        rotateJoinRequestID()
      }
      return
    }

    do {
      let terminalState = try await Self.shutdown(
        coordinator: coordinator,
        rangingClient: rangingClient
      )
      if applyRemoteCompletionIfCurrent(
        terminalState,
        generation: generation
      ) {
        return
      }
      guard isCurrent(generation) else { return }
      guard terminalState?.phase == .cancelled else {
        markCancellationUnconfirmed(
          coordinator: coordinator,
          rangingClient: rangingClient,
          generation: generation
        )
        return
      }
      self.coordinator = nil
      self.rangingClient = nil
      rotateJoinRequestID()
    } catch {
      markCancellationUnconfirmed(
        coordinator: coordinator,
        rangingClient: rangingClient,
        generation: generation
      )
    }
  }

  private func fail(
    with message: String,
    coordinator: TouchExchangeCoordinator,
    rangingClient: AppleNearbyRangingClient,
    generation: UInt
  ) async {
    do {
      let terminalState = try await Self.shutdown(
        coordinator: coordinator,
        rangingClient: rangingClient
      )
      if applyRemoteCompletionIfCurrent(
        terminalState,
        generation: generation
      ) {
        return
      }
      guard isCurrent(generation) else { return }
      guard terminalState?.phase == .cancelled else {
        markCancellationUnconfirmed(
          coordinator: coordinator,
          rangingClient: rangingClient,
          generation: generation
        )
        return
      }
      self.coordinator = nil
      self.rangingClient = nil
      rotateJoinRequestID()
      canConfirm = false
      phase = .failed
      statusText = message
    } catch {
      markCancellationUnconfirmed(
        coordinator: coordinator,
        rangingClient: rangingClient,
        generation: generation
      )
    }
  }

  private static func shutdown(
    coordinator: TouchExchangeCoordinator?,
    rangingClient: AppleNearbyRangingClient?
  ) async throws -> EncounterState? {
    await rangingClient?.stop()
    guard let coordinator else { return nil }
    return try await coordinator.cancel()
  }

  private func markCancellationUnconfirmed(
    coordinator: TouchExchangeCoordinator?,
    rangingClient: AppleNearbyRangingClient?,
    generation: UInt
  ) {
    guard isCurrent(generation) else { return }
    self.coordinator = coordinator
    self.rangingClient = rangingClient
    canConfirm = false
    phase = .cancellationUnconfirmed
    statusText = "无法确认上次交换是否已取消，请重试。重试时会先处理旧会话，不会开始新的交换。"
  }

  @discardableResult
  private func applyRemoteCompletionIfCurrent(
    _ state: EncounterState?,
    generation: UInt
  ) -> Bool {
    guard isCurrent(generation), let state, state.phase == .completed else {
      return false
    }
    coordinator = nil
    rangingClient = nil
    apply(state)
    rotateJoinRequestID()
    return true
  }

  private func apply(_ state: EncounterState) {
    if let card = state.peerCard {
      peerCard = TouchExchangePeerCard(
        displayName: card.petName,
        petAssetID: card.characterID,
        outfitAssetID: card.outfitID,
        backgroundAssetID: card.backgroundID,
        socialState: card.socialState
      )
      didRevealCard = true
    }

    switch state.phase {
    case .idle:
      phase = .idle
      canConfirm = false
      statusText = "双方都需要主动进入触碰交换"
    case .rendezvous:
      phase = .joining
      canConfirm = false
      statusText = "正在自动寻找附近的触碰对象"
    case .ranging:
      phase = .approaching
      canConfirm = false
      statusText = placementInstruction(for: state.transferRole)
    case .preview:
      phase = .preview
      canConfirm = !state.localConfirmed
      statusText =
        "已确认双方同时靠近；"
        + placementInstruction(for: state.transferRole)
    case .awaitingConfirmations:
      phase = .awaitingPeer
      canConfirm = !state.localConfirmed
      statusText =
        state.localConfirmed
        ? "已确认，正在等待对方"
        : "对方已经确认，仍需要你的确认"
    case .completed:
      canConfirm = false
      if let encounter = state.encounter {
        encounterWasSaved = encounterRepository.save(encounter)
      }
      applyTransferPresentation(from: state)
      // Publish the transfer before completion so the generic completion
      // observer cannot race the transfer view's one-shot haptic.
      phase = .completed
      statusText =
        encounterWasSaved
        ? "双方已经确认，相遇记录已保存"
        : "双方已经确认，但相遇记录保存失败"
    case .failed:
      canConfirm = false
      phase = .failed
      statusText =
        state.failure.map { Self.userFacingFailure(code: $0.code) }
        ?? "这次交换没有完成"
    case .cancelled:
      canConfirm = false
      phase = .cancelled
      statusText =
        didRevealCard
        ? "公开遇见卡预览可能已经显示，已经显示的内容无法撤回；本次交换没有完成。"
        : "已停止寻找，本次没有显示遇见卡，也没有完成交换。"
    }
  }

  private func applyTransferPresentation(from state: EncounterState) {
    guard let cue = state.transferAnimationCue,
      let peerCard,
      !presentedTransferEventIDs.contains(cue.eventID)
    else { return }

    let canPresent = encounterRepository.consumeTransferEvent(id: cue.eventID)
    guard canPresent else { return }

    let localCharacterID: String
    #if DEBUG
      localCharacterID =
        isDeterministicDemo && demoTransferRole == .destination
        ? "polar_bear"
        : localCard.petAssetID
    #else
      localCharacterID = localCard.petAssetID
    #endif

    guard
      let presentation = TouchExchangeTransferPresentation.make(
        cue: cue,
        localCharacterID: localCharacterID,
        peerCharacterID: peerCard.petAssetID,
        backgroundID:
          localCard.backgroundAssetID
          ?? peerCard.backgroundAssetID
          ?? CompanionVisualCatalog.defaultBackgroundID,
        receivedAt: Date()
      )
    else { return }

    presentedTransferEventIDs.insert(cue.eventID)
    transferPresentation = presentation
  }

  private func placementInstruction(for role: PetTransferAnimationRole?) -> String {
    switch role {
    case .source:
      "请把这块手表放在左侧，并保持两块表在约 15 厘米内"
    case .destination:
      "请把这块手表放在右侧，并保持两块表在约 15 厘米内"
    default:
      "请把两块手表保持在约 15 厘米内"
    }
  }

  @discardableResult
  private func replaceOperation() -> UInt {
    operationTask?.cancel()
    operationTask = nil
    operationGeneration &+= 1
    return operationGeneration
  }

  private func isCurrent(_ generation: UInt) -> Bool {
    generation == operationGeneration && !Task.isCancelled
  }

  private func joinRequestID() -> String {
    if let existing = currentJoinRequestID {
      return existing
    }
    let created = "join_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    currentJoinRequestID = created
    return created
  }

  private func rotateJoinRequestID() {
    currentJoinRequestID = nil
  }

  private static func installationParticipantID(
    defaults: UserDefaults = .standard
  ) -> String {
    let key = "social.mvp.participant-id.v1"
    if let existing = defaults.string(forKey: key), !existing.isEmpty {
      return existing
    }
    let created = "install_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    defaults.set(created, forKey: key)
    return created
  }

  private static func socialGatewayBaseURL(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    bundle: Bundle = .main
  ) -> URL? {
    #if DEBUG
      if let override = arguments.first(where: { $0.hasPrefix("--social-gateway-url=") }) {
        return URL(string: String(override.dropFirst("--social-gateway-url=".count)))
      }
    #endif
    guard
      let value = bundle.object(forInfoDictionaryKey: "SocialGatewayBaseURL") as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return URL(string: value)
  }

  private static func userFacingFailure(code: String) -> String {
    switch code {
    case "session_expired": "临时交换已经过期，请重新开始"
    case "start_failed": "暂时无法开始交换，请检查网络和权限"
    default: "这次交换没有完成，请重新尝试"
    }
  }

  private static func userFacingError(_ error: any Error) -> String {
    switch error {
    case SocialRendezvousError.server(let statusCode) where statusCode == 409:
      "当前候选已经离开，请重新尝试"
    case SocialRendezvousError.expiredSession:
      "临时交换已经过期，请重新开始"
    case SocialRendezvousError.insecureBaseURL:
      "触碰交换只允许使用 HTTPS 服务"
    case NearbyAdapterError.unavailable:
      "这块手表暂时无法进行近距离测量"
    default:
      "连接中断了，请重新尝试"
    }
  }
}
