import AppRuntime
import MoriRuntime
import SwiftUI

struct MoriHomeView: View {
  @ObservedObject var store: PhoneAppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isComposerFocused: Bool
  @State private var conversationIsAtBottom = true
  @State private var followsConversationBottom = true
  @State private var isUserScrollingConversation = false

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          MoriSceneHero(
            sceneID: store.sceneBackgroundID,
            characterID: store.selectedCharacterID,
            model: store.model,
            movementScene: store.movementScene
          ) { interaction in
            Task { await store.companionInteraction(interaction) }
          }

          if let chatNudge = store.chatNudge {
            MoriChatNudgeBubble(nudge: chatNudge) {
              let nudge = store.openChatNudge()
              store.presentFullChat(openingLine: nudge.openingLine)
            }
            .padding(.horizontal, CompanionSpacing.page)
            .padding(.top, CompanionSpacing.small)
          }

          conversation
            .padding(.horizontal, CompanionSpacing.page)
            .padding(.top, CompanionSpacing.large)
            .padding(.bottom, CompanionSpacing.medium)
        }
      }
      .background(CompanionPalette.background.ignoresSafeArea())
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.contentOffset.y + geometry.containerSize.height
          >= geometry.contentSize.height - 36
      } action: { _, isAtBottom in
        conversationIsAtBottom = isAtBottom
      }
      .onScrollPhaseChange { _, newPhase, _ in
        if newPhase == .interacting {
          isUserScrollingConversation = true
        } else if newPhase == .idle, isUserScrollingConversation {
          followsConversationBottom = conversationIsAtBottom
          isUserScrollingConversation = false
        }
      }
      .safeAreaInset(edge: .bottom) {
        composer
      }
      .onChange(of: store.conversation.messages.last?.id) {
        scrollToConversationBottom(proxy)
      }
      .onChange(of: streamingText) {
        scrollToConversationBottom(proxy)
      }
    }
    .navigationTitle("Mori")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("phone.overview")
    .task {
      store.scheduleChatNudge()
    }
    .navigationDestination(isPresented: $store.isShowingFullChat) {
      MoriChatView(store: store, openingLine: store.fullChatOpeningLine)
    }
    .alert(
      "发送前确认",
      isPresented: Binding(
        get: {
          store.conversation.phase
            == .warningConfirmationRequired
        },
        set: { _ in }
      )
    ) {
      Button("取消", role: .cancel) {
        store.cancelConversationWarning()
      }
      Button("仍要发送") {
        Task { await store.confirmConversationWarning() }
      }
      .accessibilityIdentifier("phone.mori.warning-confirm")
    } message: {
      Text(
        store.conversation.warningText
          ?? "这段话可能包含敏感内容，仍要发送吗？"
      )
    }
  }

  @ViewBuilder
  private var conversation: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
      Text("和 Mori 说说话")
        .font(.title3.bold())

      if store.model.isLive {
        ContentUnavailableView(
          "对话暂未开放",
          systemImage: "bubble.left.and.bubble.right",
          description: Text("正式对话运行时将在后续接入；这里不会用演示回复冒充真实服务。")
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .accessibilityIdentifier("phone.mori.chat-unavailable")
      } else if store.model.allowsInteraction == false {
        ContentUnavailableView(
          "Mock 场景无效",
          systemImage: "exclamationmark.triangle",
          description: Text("请到设置中选择有效的 Mock 数据。")
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .accessibilityIdentifier("phone.mori.invalid-mock")
      } else {
        if store.conversation.messages.isEmpty {
          MoriMessageRow(
            message: PhoneConversationDisplayMessage(
              id: "welcome",
              role: .mori,
              text: "我在这里。今天想和我说什么？"
            )
          )
        }

        ForEach(store.conversation.messages) { message in
          MoriMessageRow(message: message)
            .id(message.id)
        }

        if case .streaming(let text) = store.conversation.phase {
          MoriMessageRow(
            message: PhoneConversationDisplayMessage(
              id: "streaming",
              role: .mori,
              text: text
            ),
            isStreaming: true
          )
          .id("streaming")
        }

        conversationStatus

        Color.clear
          .frame(height: 1)
          .id("phone.mori.conversation-bottom")
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder
  private var conversationStatus: some View {
    switch store.conversation.phase {
    case .scanning:
      ConversationProgressRow(text: "正在检查这段话")
        .accessibilityIdentifier("phone.mori.chat-scanning")
    case .sending:
      ConversationProgressRow(text: "Mori 正在听")
        .accessibilityIdentifier("phone.mori.chat-sending")
    case .failed(let failure):
      VStack(alignment: .leading, spacing: CompanionSpacing.small) {
        Label(
          failure == .cancelled ? "已停止" : failure.phoneMessage,
          systemImage:
            failure == .cancelled
            ? "stop.circle"
            : "exclamationmark.circle"
        )
        .font(.footnote)
        .foregroundStyle(CompanionPalette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(failure.phoneMessage)
        .accessibilityIdentifier("phone.mori.chat-failure")

        if store.conversation.canRetry {
          Button("重试刚才的话") {
            Task { await store.retryConversation() }
          }
          .buttonStyle(.borderless)
          .font(.footnote.weight(.semibold))
          .accessibilityIdentifier("phone.mori.retry")
        }
      }
      .accessibilityElement(children: .contain)
    case .idle, .warningConfirmationRequired, .streaming:
      EmptyView()
    }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: CompanionSpacing.small) {
      TextField(
        composerPlaceholder,
        text: Binding(
          get: { store.conversation.draft },
          set: store.setConversationDraft
        ),
        axis: .vertical
      )
      .lineLimit(1...4)
      .textFieldStyle(.plain)
      .focused($isComposerFocused)
      .submitLabel(.send)
      .onSubmit(send)
      .disabled(store.companionExperienceAvailable == false)
      .accessibilityIdentifier("phone.mori.composer")

      if store.conversation.phase.isBusy {
        Button(action: store.cancelConversationResponse) {
          Image(systemName: "stop.circle.fill")
            .font(.title2)
        }
        .accessibilityLabel("停止回复")
        .accessibilityIdentifier("phone.mori.cancel")
      } else {
        Button(action: send) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title2)
        }
        .disabled(canSend == false)
        .accessibilityLabel("发送")
        .accessibilityIdentifier("phone.mori.send")
      }
    }
    .padding(.horizontal, CompanionSpacing.page)
    .padding(.vertical, 11)
    .background(.regularMaterial)
  }

  private var canSend: Bool {
    store.conversation.draft
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty == false
      && store.companionExperienceAvailable
      && store.conversation.phase.isBusy == false
  }

  private var streamingText: String? {
    if case .streaming(let text) = store.conversation.phase {
      return text
    }
    return nil
  }

  private var composerPlaceholder: String {
    store.model.isLive
      ? "正式对话尚未开放"
      : "给 Mori 留句话"
  }

  private func send() {
    let value = store.conversation.draft
    guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      return
    }
    isComposerFocused = false
    Task {
      await store.sendConversationMessage(value)
    }
  }

  private func scrollToConversationBottom(
    _ proxy: ScrollViewProxy
  ) {
    guard followsConversationBottom else { return }
    if reduceMotion {
      proxy.scrollTo("phone.mori.conversation-bottom", anchor: .bottom)
    } else {
      withAnimation(.easeOut(duration: 0.2)) {
        proxy.scrollTo("phone.mori.conversation-bottom", anchor: .bottom)
      }
    }
  }
}

struct MoriSceneHero: View {
  let sceneID: String
  let characterID: String
  let model: PhonePresentationModel
  let movementScene: MovementScenePresentation?
  let onInteraction: (PhonePetInteraction) -> Void

  var body: some View {
    PhoneCompanionSceneView(
      characterID: characterID,
      backgroundID: sceneID,
      movementMotion: characterID == CompanionVisualCatalog.defaultCharacterID
        ? movementScene?.petMotion
        : nil,
      onInteraction: onInteraction
    )
    .overlay(alignment: .bottom) {
      HStack {
        PhoneDataBadge(model: model)
        Spacer()
        Text("Mori 在这里")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.black.opacity(0.72), in: Capsule())
      }
      .padding(CompanionSpacing.medium)
      .allowsHitTesting(false)
    }
    .overlay(alignment: .topLeading) {
      if let movementScene {
        MovementSceneBadge(presentation: movementScene)
          .padding(CompanionSpacing.medium)
          .allowsHitTesting(false)
      }
    }
    .padding(.horizontal, CompanionSpacing.page)
    .padding(.top, CompanionSpacing.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("phone.mori.scene")
  }
}

private struct MovementSceneBadge: View {
  let presentation: MovementScenePresentation

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(presentation.title)
          .font(.caption.weight(.bold))
        Text("模拟 \(presentation.detail)")
          .font(.caption2.monospacedDigit())
      }
    } icon: {
      Image(systemName: presentation.systemImage)
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.black.opacity(0.58), in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(presentation.title)，模拟 \(presentation.detail)")
    .accessibilityIdentifier("phone.movement-scene")
  }
}

private struct MoriMessageRow: View {
  let message: PhoneConversationDisplayMessage
  var isStreaming = false

  @ViewBuilder
  var body: some View {
    if message.role == .localSystem {
      Text(message.text)
        .font(.footnote)
        .foregroundStyle(CompanionPalette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(
          "phone.mori.message.\(message.id)"
        )
        .accessibilityLabel("本机提示：\(message.text)")
    } else {
      HStack(alignment: .bottom) {
        if message.role == .user {
          Spacer(minLength: 54)
        }
        Text(message.text)
          .font(.body)
          .foregroundStyle(
            message.role == .user ? Color.white : CompanionPalette.ink
          )
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(
            message.role == .user
              ? CompanionPalette.mint
              : CompanionPalette.surface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
          )
          .overlay(alignment: .bottomTrailing) {
            if isStreaming {
              ProgressView()
                .controlSize(.mini)
                .padding(6)
                .accessibilityHidden(true)
            }
          }
          .accessibilityLabel(
            "\(message.role == .user ? "你" : "Mori")：\(message.text)"
          )
          .accessibilityIdentifier(
            "phone.mori.message.\(message.id)"
          )
        if message.role == .mori {
          Spacer(minLength: 54)
        }
      }
      .frame(maxWidth: .infinity)
    }
  }
}

private struct ConversationProgressRow: View {
  let text: String

  var body: some View {
    HStack(spacing: CompanionSpacing.small) {
      ProgressView()
        .controlSize(.small)
      Text(text)
        .font(.footnote)
        .foregroundStyle(CompanionPalette.secondaryText)
    }
    .accessibilityElement(children: .combine)
  }
}
