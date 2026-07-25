import SwiftUI

struct MoriChatNudge: Identifiable, Equatable {
  let id: String
  let text: String
  let openingLine: String

  static let gentle = MoriChatNudge(
    id: "gentle",
    text: "要和我聊一会儿吗？",
    openingLine: "我在呀。今天有什么想和我说的吗？"
  )

  static let curious = MoriChatNudge(
    id: "curious",
    text: "我刚想到一件小事",
    openingLine: "刚才看到你，我有点好奇。今天有没有哪一刻让你印象很深？"
  )

  static let quiet = MoriChatNudge(
    id: "quiet",
    text: "我在这里，想说什么都可以",
    openingLine: "不用特意想好怎么说。我在这里，慢慢听你讲。"
  )
}

struct MoriChatNudgePolicy {
  private static let lastShownDayKey = "mori.chat-nudge.last-shown-day.v1"
  private static let installationSeedKey = "mori.chat-nudge.installation-seed.v1"

  let arguments: [String]
  let defaults: UserDefaults
  let calendar: Calendar

  init(
    arguments: [String],
    defaults: UserDefaults = .standard,
    calendar: Calendar = .current
  ) {
    self.arguments = arguments
    self.defaults = defaults
    self.calendar = calendar
  }

  var isForcedVisible: Bool {
    arguments.contains("--chat-nudge=visible")
  }

  func nextNudge(at date: Date) -> MoriChatNudge? {
    let isUITesting = arguments.contains("-UITesting")
    guard isForcedVisible || !isUITesting else { return nil }

    let day = dayKey(for: date)
    if !isForcedVisible,
      defaults.string(forKey: Self.lastShownDayKey) == day
    {
      return nil
    }

    let seed = installationSeed()
    let selection = stableHash("\(seed):\(day)")
    guard isForcedVisible || selection % 3 == 0 else { return nil }
    defaults.set(day, forKey: Self.lastShownDayKey)

    switch selection % 3 {
    case 1: return .curious
    case 2: return .quiet
    default: return .gentle
    }
  }

  private func dayKey(for date: Date) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
  }

  private func installationSeed() -> String {
    if let value = defaults.string(forKey: Self.installationSeedKey), !value.isEmpty {
      return value
    }
    let value = UUID().uuidString.lowercased()
    defaults.set(value, forKey: Self.installationSeedKey)
    return value
  }

  private func stableHash(_ value: String) -> UInt64 {
    value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }
}

struct MoriChatNudgeBubble: View {
  let nudge: MoriChatNudge
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(systemName: "bubble.left.fill")
          .foregroundStyle(CompanionPalette.mint)
          .accessibilityHidden(true)
        Text(nudge.text)
          .font(.caption.weight(.semibold))
          .multilineTextAlignment(.leading)
          .lineLimit(2)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.bold))
          .foregroundStyle(CompanionPalette.secondaryText)
          .accessibilityHidden(true)
      }
      .foregroundStyle(CompanionPalette.ink)
      .padding(.horizontal, 11)
      .padding(.vertical, 9)
      .frame(maxWidth: 210, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.white.opacity(0.55), lineWidth: 1)
      }
      .shadow(color: CompanionPalette.heroMint.opacity(0.22), radius: 10, y: 4)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Mori 说，\(nudge.text)")
    .accessibilityHint("打开和 Mori 的聊天")
    .accessibilityIdentifier("phone.chat-nudge")
    .transition(
      reduceMotion
        ? .opacity
        : .scale(scale: 0.94, anchor: .bottomLeading).combined(with: .opacity)
    )
  }
}

struct MoriChatView: View {
  @ObservedObject var store: PhoneAppStore
  @State private var messages: [MoriChatMessage]
  @State private var draft = ""
  @State private var isSending = false
  @State private var pendingConsentText: String?
  @State private var hasConsentedThisSession = false
  @State private var showsExternalAIConsent = false
  @State private var replyTask: Task<Void, Never>?
  @FocusState private var isComposerFocused: Bool

  init(
    store: PhoneAppStore,
    openingLine: String
  ) {
    self.store = store
    _messages = State(
      initialValue: [
        MoriChatMessage(author: .mori, text: openingLine)
      ]
    )
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(messages) { message in
            chatBubble(message)
              .id(message.id)
          }
          if isSending {
            thinkingBubble
              .id("mori-thinking")
          }
        }
        .padding(.horizontal, CompanionSpacing.page)
        .padding(.vertical, CompanionSpacing.medium)
      }
      .accessibilityIdentifier("phone.chat.messages")
      .background(CompanionPalette.background.ignoresSafeArea())
      .onChange(of: messages.count) {
        guard let last = messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(last.id, anchor: .bottom)
        }
      }
      .onChange(of: isSending) {
        guard isSending else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo("mori-thinking", anchor: .bottom)
        }
      }
    }
    .navigationTitle("和 Mori 聊聊")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.hidden, for: .tabBar)
    .safeAreaInset(edge: .bottom) {
      composer
    }
    .alert("发送给 AI 服务？", isPresented: $showsExternalAIConsent) {
      Button("同意并发送") {
        guard let text = pendingConsentText else { return }
        pendingConsentText = nil
        hasConsentedThisSession = true
        sendMessage(text)
      }
      Button("暂不发送", role: .cancel) {
        pendingConsentText = nil
      }
    } message: {
      Text("最近几句对话和粗粒度性格提示会发送给 AI 服务生成回复；回复会用于生成并自动播放语音。不会发送原始健康数据。")
    }
    .onDisappear {
      replyTask?.cancel()
      replyTask = nil
      store.stopMoriSpeech()
    }
  }

  @ViewBuilder
  private func chatBubble(_ message: MoriChatMessage) -> some View {
    HStack(alignment: .bottom, spacing: 8) {
      if message.author == .owner {
        Spacer(minLength: 44)
      } else {
        Image(systemName: "pawprint.fill")
          .font(.caption)
          .foregroundStyle(CompanionPalette.mint)
          .frame(width: 28, height: 28)
          .background(CompanionPalette.mintSoft, in: Circle())
          .accessibilityHidden(true)
      }

      Text(message.text)
        .font(.body)
        .foregroundStyle(message.author == .owner ? Color.white : CompanionPalette.ink)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
          message.author == .owner ? CompanionPalette.mint : CompanionPalette.surface,
          in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .accessibilityLabel(
          message.author == .owner
            ? "你说，\(message.text)"
            : "Mori 说，\(message.text)"
        )
        .accessibilityIdentifier("phone.chat.message.\(message.author.rawValue)")

      if message.author == .mori {
        Spacer(minLength: 44)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var thinkingBubble: some View {
    HStack(spacing: 8) {
      Image(systemName: "pawprint.fill")
        .font(.caption)
        .foregroundStyle(CompanionPalette.mint)
        .frame(width: 28, height: 28)
        .background(CompanionPalette.mintSoft, in: Circle())
        .accessibilityHidden(true)
      ProgressView()
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
          CompanionPalette.surface,
          in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .accessibilityLabel("Mori 正在回复")
      Spacer()
    }
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .bottom, spacing: 10) {
        TextField("和 Mori 说点什么", text: $draft, axis: .vertical)
          .lineLimit(1...4)
          .focused($isComposerFocused)
          .submitLabel(.send)
          .onSubmit(send)
          .padding(.horizontal, 13)
          .padding(.vertical, 10)
          .background(
            CompanionPalette.surface,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(Color.primary.opacity(0.09), lineWidth: 1)
          }
          .accessibilityIdentifier("phone.chat.composer")

        Button(action: send) {
          Image(systemName: "arrow.up")
            .font(.body.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(CompanionPalette.mint, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(trimmedDraft.isEmpty || isSending)
        .opacity(trimmedDraft.isEmpty || isSending ? 0.45 : 1)
        .accessibilityLabel("发送")
        .accessibilityIdentifier("phone.chat.send")
      }
    }
    .padding(.horizontal, CompanionSpacing.page)
    .padding(.top, 10)
    .padding(.bottom, 8)
    .background(.bar)
  }

  private var trimmedDraft: String {
    String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
  }

  private func send() {
    let text = trimmedDraft
    guard !text.isEmpty, !isSending else { return }
    isComposerFocused = false
    if store.chatRequiresExternalAIConsent, !hasConsentedThisSession {
      pendingConsentText = text
      showsExternalAIConsent = true
      return
    }
    sendMessage(text)
  }

  private func sendMessage(_ text: String) {
    store.stopMoriSpeech()
    draft = ""
    let ownerMessage = MoriChatMessage(author: .owner, text: text)
    messages.append(ownerMessage)
    messages = Array(messages.suffix(12))
    isSending = true

    replyTask = Task {
      let reply = await store.replyToMoriChat(messages: messages)
      guard !Task.isCancelled else { return }
      messages.append(MoriChatMessage(author: .mori, text: reply.text))
      messages = Array(messages.suffix(12))
      isSending = false
      store.speakMoriChatReply(reply)
      replyTask = nil
    }
  }
}
