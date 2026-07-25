import Foundation
import SwiftUI

enum PhoneCharacterGenerationInputKind: Equatable {
  case bilibiliLink
  case description

  init(text: String) {
    if Self.containsBilibiliLink(in: text) {
      self = .bilibiliLink
    } else {
      self = .description
    }
  }

  private static func containsBilibiliLink(in text: String) -> Bool {
    guard
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
      )
    else {
      return false
    }

    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    return detector.matches(in: text, range: fullRange).contains { match in
      guard
        let range = Range(match.range, in: text),
        text[range].lowercased().hasPrefix("http://")
          || text[range].lowercased().hasPrefix("https://"),
        let host = match.url?.host?.lowercased()
      else {
        return false
      }

      return host == "bilibili.com"
        || host.hasSuffix(".bilibili.com")
        || host == "b23.tv"
        || host.hasSuffix(".b23.tv")
    }
  }

  var loadingMessage: String {
    switch self {
    case .bilibiliLink:
      "正在读取视频里的角色灵感…"
    case .description:
      "正在把描述变成像素伙伴…"
    }
  }

  var resultSource: String {
    switch self {
    case .bilibiliLink:
      "已根据 B 站链接完成演示生成"
    case .description:
      "已根据你的描述完成演示生成"
    }
  }
}

struct PhoneCharacterGeneratorView: View {
  private enum Phase: Hashable {
    case editing
    case generating
    case result
  }

  @State private var input = ""
  @State private var phase = Phase.editing
  @State private var submittedInputKind = PhoneCharacterGenerationInputKind.description
  @FocusState private var inputIsFocused: Bool

  private var trimmedInput: String {
    input.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.large) {
        header
          .padding(.top, CompanionSpacing.small)

        if phase == .result {
          result
        } else {
          inputForm
          generateButton

          if phase == .generating {
            loadingState
          }
        }
      }
    }
    .navigationTitle("生成角色")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("phone.character-generator")
    .task(id: phase) {
      guard phase == .generating else {
        return
      }

      do {
        try await Task.sleep(nanoseconds: 1_500_000_000)
      } catch {
        return
      }

      guard !Task.isCancelled else {
        return
      }
      withAnimation {
        phase = .result
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("完成") {
          inputIsFocused = false
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.small) {
      Text("做一个自己的像素伙伴")
        .font(.title2.bold())
        .foregroundStyle(CompanionPalette.ink)

      Text("粘贴 B 站视频链接，或用一句话描述它。这个页面只演示生成流程。")
        .font(.subheadline)
        .foregroundStyle(CompanionPalette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var inputForm: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.small) {
      Text("B 站链接或角色描述")
        .font(.headline)
        .foregroundStyle(CompanionPalette.ink)

      ZStack(alignment: .topLeading) {
        if input.isEmpty {
          Text("例如：https://b23.tv/… 或「咕咕嘎嘎」")
            .font(.body)
            .foregroundStyle(CompanionPalette.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
        }

        TextEditor(text: $input)
          .focused($inputIsFocused)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 112)
          .accessibilityLabel("B 站链接或角色描述")
          .accessibilityIdentifier("phone.character-generator.input")
      }
      .padding(CompanionSpacing.small)
      .background(
        CompanionPalette.surface,
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }

      Text("支持 bilibili.com 和 b23.tv 链接；Demo 不会上传或解析视频。")
        .font(.footnote)
        .foregroundStyle(CompanionPalette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var generateButton: some View {
    Button {
      submittedInputKind = PhoneCharacterGenerationInputKind(text: trimmedInput)
      inputIsFocused = false
      withAnimation {
        phase = .generating
      }
    } label: {
      HStack(spacing: CompanionSpacing.small) {
        if phase == .generating {
          ProgressView()
            .tint(.white)
        }
        Text(phase == .generating ? "正在生成…" : "生成角色")
          .font(.headline)
      }
      .frame(maxWidth: .infinity)
      .frame(minHeight: 44)
    }
    .buttonStyle(.borderedProminent)
    .tint(CompanionPalette.mint)
    .disabled(trimmedInput.isEmpty || phase == .generating)
    .accessibilityIdentifier("phone.character-generator.generate")
  }

  private var loadingState: some View {
    VStack(spacing: CompanionSpacing.medium) {
      ProgressView()
        .controlSize(.large)
        .tint(CompanionPalette.mint)

      VStack(spacing: 4) {
        Text(submittedInputKind.loadingMessage)
          .font(.headline)
          .foregroundStyle(CompanionPalette.ink)
        Text("演示大约需要 1–2 秒")
          .font(.subheadline)
          .foregroundStyle(CompanionPalette.secondaryText)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, CompanionSpacing.large)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("phone.character-generator.loading")
  }

  private var result: some View {
    VStack(spacing: CompanionSpacing.large) {
      VStack(spacing: CompanionSpacing.medium) {
        Image("character_penguin_idle_lively_00")
          .resizable()
          .interpolation(.none)
          .scaledToFit()
          .frame(width: 220, height: 240)
          .accessibilityLabel("生成的黑企鹅像素伙伴")
          .accessibilityIdentifier("phone.character-generator.result-image")

        VStack(spacing: 4) {
          Text("黑企鹅伙伴")
            .font(.title2.bold())
            .foregroundStyle(CompanionPalette.ink)
          Text(submittedInputKind.resultSource)
            .font(.subheadline)
            .foregroundStyle(CompanionPalette.secondaryText)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, CompanionSpacing.large)
      .background(
        CompanionPalette.surface,
        in: RoundedRectangle(cornerRadius: CompanionRadius.hero, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: CompanionRadius.hero, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }

      Text("这是固定返回黑企鹅的 Demo，结果不会加入伙伴列表。")
        .font(.footnote)
        .foregroundStyle(CompanionPalette.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      Button("换个描述") {
        withAnimation {
          phase = .editing
        }
        inputIsFocused = true
      }
      .buttonStyle(.bordered)
      .tint(CompanionPalette.blue)
      .controlSize(.large)
      .accessibilityIdentifier("phone.character-generator.reset")
    }
  }
}
