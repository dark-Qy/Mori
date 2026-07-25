import AppRuntime
import MoriRuntime
import SwiftUI
import WatchKit

struct WatchRootView: View {
  @ObservedObject var store: WatchAppStore
  @StateObject private var exchange: TouchExchangeViewModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var navigationPath: [WatchProductRoute] = []
  @State private var showsMoriMenu = false
  @State private var bubbleMessage: String?
  @State private var bubbleToken = 0
  @State private var sceneReactionSequence = 0
  @State private var sceneReaction: WatchSceneReaction?

  init(store: WatchAppStore) {
    self.store = store
    _exchange = StateObject(
      wrappedValue: TouchExchangeViewModel(
        localCard: store.touchExchangeLocalCard,
        socialSharingEnabled: store.isTouchExchangeSharingEnabled,
        arguments: ProcessInfo.processInfo.arguments
      )
    )
  }

  private var model: WatchPresentationModel { store.model }
  private var showsTouchExchangeDirectly: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains("--touch-exchange-direct")
    #else
      false
    #endif
  }

  private var automaticallyRunsTouchExchange: Bool {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-UITesting") {
        return ProcessInfo.processInfo.arguments.contains("--touch-exchange-demo")
      }
    #endif
    return true
  }

  private var automaticallyConfirmsTouchExchange: Bool {
    #if DEBUG
      !ProcessInfo.processInfo.arguments.contains("--touch-exchange-manual-confirm")
    #else
      true
    #endif
  }

  private var showsAutomaticTouchExchange: Bool {
    guard navigationPath.last != .touchExchange else { return false }
    return switch exchange.phase {
    case .idle, .joining, .failed, .cancelled:
      false
    case .approaching, .preview, .awaitingPeer, .completed:
      true
    }
  }

  var body: some View {
    Group {
      switch store.phase {
      case .loading:
        ProgressView("载入中…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black)
          .accessibilityIdentifier("watch.loading")
      case .onboarding:
        WatchOnboardingView(store: store, isPetIntroduction: false)
      case .petIntroduction:
        WatchOnboardingView(store: store, isPetIntroduction: true)
      case .ready:
        if showsTouchExchangeDirectly || showsAutomaticTouchExchange {
          TouchExchangeView(
            exchange: exchange,
            socialSharingEnabled: store.isTouchExchangeSharingEnabled
          )
        } else if let destination = store.notificationDestination {
          WatchNotificationMessageView(
            destination: destination,
            onDismiss: store.dismissNotificationDestination
          )
        } else {
          experience
        }
      }
    }
    .task {
      await store.start()
      prepareReadyExperience()
      startAutomaticTouchExchangeIfAllowed()
    }
    .onChange(of: store.phase) { _, phase in
      guard phase == .ready else { return }
      prepareReadyExperience()
    }
    .onChange(of: store.activeGlance) { _, glance in
      guard let glance else { return }
      present(glance)
    }
    .task(id: exchange.phase) {
      guard exchange.phase == .completed else { return }
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled, exchange.phase == .completed else { return }
      exchange.finishCompletedPresentation()
    }
    .onChange(of: store.phase) { _, phase in
      guard phase == .ready else { return }
      startAutomaticTouchExchangeIfAllowed()
    }
    .onChange(of: store.isTouchExchangeSharingEnabled) { _, enabled in
      exchange.updateSocialSharingEnabled(enabled)
      guard enabled else { return }
      startAutomaticTouchExchangeIfAllowed()
    }
    .onChange(of: exchange.canConfirm) { _, canConfirm in
      guard
        canConfirm,
        automaticallyConfirmsTouchExchange,
        store.isTouchExchangeSharingEnabled,
        exchange.socialSharingEnabled
      else { return }
      exchange.confirm()
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        if store.phase == .ready {
          activateExperience()
        }
        startAutomaticTouchExchangeIfAllowed()
      case .inactive, .background:
        exchange.cancelIfNeeded()
      @unknown default:
        exchange.cancelIfNeeded()
      }
    }
  }

  private func startAutomaticTouchExchangeIfAllowed() {
    guard
      automaticallyRunsTouchExchange,
      store.phase == .ready,
      store.isTouchExchangeSharingEnabled,
      scenePhase == .active
    else { return }
    exchange.updateLocalCard(store.touchExchangeLocalCard)
    exchange.updateSocialSharingEnabled(true)
    exchange.start()
  }

  private var experience: some View {
    NavigationStack(path: $navigationPath) {
      home
        .navigationDestination(for: WatchProductRoute.self) { route in
          destination(for: route)
        }
    }
    .onChange(of: navigationPath) { oldPath, newPath in
      guard oldPath.last == .touchExchange,
        newPath.last != .touchExchange
      else { return }
      exchange.cancelIfNeeded()
    }
    .tint(AdventurePalette.mint)
  }

  private var home: some View {
    GeometryReader { geometry in
      ZStack {
        CompanionSceneView(
          scene: store.scenePresentation,
          reaction: sceneReaction,
          movementMotion: store.movementSceneAnimation,
          usesStaticArtwork: store.movementSceneAnimation == nil,
          cornerRadius: 0,
          showsTouchHint: false,
          sceneAccessibilityIdentifier: "watch.pet-home",
          onLongPress: { showsMoriMenu = true },
          onInteraction: respondToMori
        )
        .frame(width: geometry.size.width, height: geometry.size.height)
        .ignoresSafeArea()

        LinearGradient(
          colors: [
            .black.opacity(0.35),
            .clear,
            .clear,
            .black.opacity(0.42),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .allowsHitTesting(false)
        .ignoresSafeArea()

        homeOverlay
          .padding(.horizontal, 10)
          .padding(.top, 12)
          .padding(.bottom, 6)

        if let movementScene = store.movementScene {
          VStack {
            HStack {
              movementSceneBadge(movementScene)
              Spacer(minLength: 0)
            }
            .padding(.top, 62)
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
          }
          .allowsHitTesting(false)
        }

        if let bubbleMessage {
          MoriSpeechBubble(message: bubbleMessage)
            .frame(maxWidth: max(80, min(geometry.size.width - 34, 176)))
            .offset(y: -geometry.size.height * 0.17)
            .transition(.opacity)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .ignoresSafeArea()
    .toolbar(.hidden, for: .navigationBar)
    .background(Color.black)
    .confirmationDialog("和 Mori 去哪里？", isPresented: $showsMoriMenu) {
      Button("今天") { navigate(to: .today) }
      Button("Mori 来信") { navigate(to: .letters) }
      Button("碰一碰") { navigate(to: .touchExchange) }
      Button("设置") { navigate(to: .settings) }
      Button("取消", role: .cancel) {}
    }
  }

  private var homeOverlay: some View {
    VStack(spacing: 0) {
      Label(model.homeSleepText, systemImage: "moon.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
        .accessibilityLabel(model.homeSleepText)
        .accessibilityRespondsToUserInteraction(false)
        .accessibilityIdentifier("watch.home.sleep")

      Spacer(minLength: 0)

      Label(model.homeStepsText, systemImage: "shoeprints.fill")
        .font(.caption.weight(.bold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
        .padding(.bottom, 7)
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
        .accessibilityLabel(model.homeStepsText)
        .accessibilityRespondsToUserInteraction(false)
        .accessibilityIdentifier("watch.home.steps")

      Button {
        navigate(to: .companionSettings)
      } label: {
        Label(
          companionStatusTitle,
          systemImage: companionStatusSymbol
        )
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(.black.opacity(0.46), in: Capsule())
        .overlay {
          Capsule().stroke(.white.opacity(0.5), lineWidth: 0.75)
        }
      }
      .buttonStyle(.plain)
      .accessibilityHint("调整随行感知、提醒方式和安静时段")
      .accessibilityIdentifier("watch.open-companion-settings")
    }
  }

  private var companionStatusTitle: String {
    guard store.companionExperienceAvailable else {
      return "Mori 随行待连接"
    }
    return store.companionSensingEnabled ? "Mori 随行中" : "Mori 随行已关闭"
  }

  private var companionStatusSymbol: String {
    guard store.companionExperienceAvailable else {
      return "location.slash"
    }
    return store.companionSensingEnabled
      ? "location.fill"
      : "location.slash.fill"
  }

  private func movementSceneBadge(
    _ movementScene: MovementScenePresentation
  ) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Label(movementScene.title, systemImage: movementScene.systemImage)
        .font(.caption2.weight(.bold))
      Text("模拟 \(movementScene.detail)")
        .font(.system(size: 9, weight: .medium, design: .monospaced))
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.black.opacity(0.58), in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(movementScene.title)，模拟 \(movementScene.detail)"
    )
    .accessibilityIdentifier("watch.movement-scene")
  }

  @ViewBuilder
  private func destination(for route: WatchProductRoute) -> some View {
    switch route {
    case .today:
      WatchTodayView(store: store)
    case .letters:
      MessageInboxView(messages: model.messages)
    case .touchExchange:
      TouchExchangeView(
        exchange: exchange,
        socialSharingEnabled: store.isTouchExchangeSharingEnabled,
        dismissesAfterCancellation: true
      )
    case .settings:
      WatchSettingsView(store: store)
    case .companionSettings:
      WatchCompanionSettingsView(store: store)
    case .dailyMemory:
      WatchDailyMemoryView(model: model)
    }
  }

  private func prepareReadyExperience() {
    guard store.phase == .ready else { return }
    activateExperience()
    if let route = store.consumeLaunchProductRoute() {
      navigate(to: route)
    }
  }

  private func activateExperience() {
    Task {
      await store.handleForegroundActivation()
      if let glance = store.activeGlance {
        present(glance)
      }
    }
  }

  private func present(_ glance: WatchGlancePresentation) {
    guard bubbleMessage != glance.message else { return }
    showBubble(glance.message, duration: .seconds(8))
    triggerSceneReaction(glance.reaction)
    if glance.shouldPlayHaptic {
      WKInterfaceDevice.current().play(.click)
    }
  }

  private func navigate(to route: WatchProductRoute) {
    guard navigationPath.last != route else { return }
    navigationPath.append(route)
  }

  private func respondToMori(_ animation: WatchCharacterAnimation) {
    guard model.allowsInteraction else {
      showBubble("Mock 场景无效，当前不会读取真实数据。", duration: .seconds(4))
      return
    }
    let response =
      animation == .touchHead
      ? "我在这里。"
      : "再待一会儿也可以。"
    showBubble(response, duration: .seconds(3))
    Task { await store.interact(with: animation) }
  }

  private func triggerSceneReaction(_ animation: WatchCharacterAnimation) {
    sceneReactionSequence += 1
    sceneReaction = WatchSceneReaction(
      sequence: sceneReactionSequence,
      animation: animation
    )
  }

  private func showBubble(_ message: String, duration: Duration) {
    bubbleToken += 1
    let token = bubbleToken
    withAnimation(.easeOut(duration: 0.18)) {
      bubbleMessage = message
    }
    Task { @MainActor in
      try? await Task.sleep(for: duration)
      guard token == bubbleToken else { return }
      withAnimation(.easeIn(duration: 0.15)) {
        bubbleMessage = nil
      }
      store.dismissActiveGlance()
    }
  }
}

private struct MoriSpeechBubble: View {
  let message: String

  var body: some View {
    Text(message)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.black)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Mori 说，\(message)")
      .accessibilityIdentifier("watch.event-bubble")
  }
}

#if DEBUG
  #Preview {
    WatchRootView(
      store: WatchAppStore(arguments: ["-UITesting", "--mock-scenario=mock1"])
    )
  }
#endif
