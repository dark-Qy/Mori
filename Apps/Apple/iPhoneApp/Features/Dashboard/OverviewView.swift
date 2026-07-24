import SwiftUI

struct MoriHomeView: View {
  @ObservedObject var store: PhoneAppStore
  @State private var draft = ""
  @FocusState private var isComposerFocused: Bool

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          MoriSceneHero(
            sceneID: store.selectedSceneID,
            model: store.model
          )

          conversation
            .padding(.horizontal, CompanionSpacing.page)
            .padding(.top, CompanionSpacing.large)
            .padding(.bottom, CompanionSpacing.medium)
        }
      }
      .background(CompanionPalette.background.ignoresSafeArea())
      .safeAreaInset(edge: .bottom) {
        composer
      }
      .onChange(of: store.mockExperience.conversation.count) {
        guard let lastID = store.mockExperience.conversation.last?.id else {
          return
        }
        withAnimation(.easeOut(duration: 0.25)) {
          proxy.scrollTo(lastID, anchor: .bottom)
        }
      }
    }
    .navigationTitle("Mori")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder
  private var conversation: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
      HStack(alignment: .firstTextBaseline) {
        Text("和 Mori 说说话")
          .font(.title3.bold())
        Spacer()
        if store.model.isLive {
          Text("待接入")
            .font(.caption.weight(.semibold))
            .foregroundStyle(CompanionPalette.secondaryText)
        } else {
          Label("本机预览", systemImage: "iphone")
            .font(.caption.weight(.semibold))
            .foregroundStyle(CompanionPalette.mint)
        }
      }

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
        ForEach(store.mockExperience.conversation) { message in
          MoriMessageRow(message: message)
            .id(message.id)
        }
        Text("本机回复不会完成任务、发放金币或声称知道没有感知到的事实。")
          .font(.caption)
          .foregroundStyle(CompanionPalette.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("phone.mori.local-disclosure")
      }
    }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: CompanionSpacing.small) {
      TextField("给 Mori 留句话", text: $draft, axis: .vertical)
        .lineLimit(1...4)
        .textFieldStyle(.plain)
        .focused($isComposerFocused)
        .submitLabel(.send)
        .onSubmit(send)
        .accessibilityIdentifier("phone.mori.composer")

      Button(action: send) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.title2)
      }
      .disabled(
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || store.companionExperienceAvailable == false
          || store.isSavingMockExperience
      )
      .accessibilityLabel("发送")
      .accessibilityIdentifier("phone.mori.send")
    }
    .padding(.horizontal, CompanionSpacing.page)
    .padding(.vertical, 11)
    .background(.regularMaterial)
  }

  private func send() {
    let value = draft
    guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      return
    }
    draft = ""
    Task {
      await store.sendConversationMessage(value)
    }
  }
}

struct MoriSceneHero: View {
  let sceneID: String
  let model: PhonePresentationModel

  var body: some View {
    ZStack(alignment: .bottom) {
      Image("scene_\(sceneID)_large")
        .resizable()
        .interpolation(.none)
        .scaledToFill()

      LinearGradient(
        colors: [.clear, .black.opacity(0.18)],
        startPoint: .center,
        endPoint: .bottom
      )

      Image("character_penguin_idle_neutral_00")
        .resizable()
        .interpolation(.none)
        .scaledToFit()
        .frame(width: 210, height: 228)
        .padding(.bottom, 18)

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
    }
    .frame(maxWidth: .infinity)
    .aspectRatio(1.18, contentMode: .fit)
    .clipped()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Mori 的当前场景")
    .accessibilityValue(model.mockScenario?.displayName ?? "真实模式")
    .accessibilityIdentifier("phone.mori.scene")
  }
}

private struct MoriMessageRow: View {
  let message: PhoneConversationMessage

  var body: some View {
    HStack {
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
          in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityLabel(
          "\(message.role == .user ? "你" : "Mori")：\(message.text)"
        )
        .accessibilityIdentifier(
          "phone.mori.message.\(message.id.uuidString)"
        )
      if message.role == .mori {
        Spacer(minLength: 54)
      }
    }
    .frame(maxWidth: .infinity)
  }
}
