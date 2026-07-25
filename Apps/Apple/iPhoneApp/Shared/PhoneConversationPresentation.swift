import Foundation
import MoriDomain
import MoriRuntime

enum PhoneConversationDisplayRole: Equatable {
  case user
  case mori
  case localSystem
}

struct PhoneConversationDisplayMessage: Identifiable, Equatable {
  let id: String
  let role: PhoneConversationDisplayRole
  let text: String
}

enum PhoneConversationPhase: Equatable {
  case idle
  case scanning
  case warningConfirmationRequired
  case sending
  case streaming(String)
  case failed(ConversationFailure)

  var isBusy: Bool {
    switch self {
    case .scanning, .sending, .streaming:
      true
    default:
      false
    }
  }
}

struct PhoneConversationPresentation: Equatable {
  var messages: [PhoneConversationDisplayMessage]
  var draft: String
  var phase: PhoneConversationPhase
  var warningText: String?
  var canRetry: Bool
  var pendingRetryRequestID: String?
  var memoryContextIsEnabled: Bool

  static let empty = Self(
    messages: [],
    draft: "",
    phase: .idle,
    warningText: nil,
    canRetry: false,
    pendingRetryRequestID: nil,
    memoryContextIsEnabled: false
  )

  init(_ runtime: ConversationPresentationState) {
    messages = runtime.messages.map {
      PhoneConversationDisplayMessage(
        id: $0.header.recordID.rawValue,
        role: Self.role($0.role),
        text: $0.content
      )
    }
    draft = runtime.draft
    switch runtime.phase {
    case .idle:
      phase = .idle
    case .scanning:
      phase = .scanning
    case .warningConfirmationRequired:
      phase = .warningConfirmationRequired
    case .sending:
      phase = .sending
    case .streaming(_, let text):
      phase = .streaming(text)
    case .failed(_, let failure):
      phase = .failed(failure)
    }
    warningText = Self.warningText(runtime.warnings)
    canRetry = runtime.canRetry
    pendingRetryRequestID = runtime.pendingRetryRequestID
    memoryContextIsEnabled = runtime.memoryContextIsEnabled
  }

  private init(
    messages: [PhoneConversationDisplayMessage],
    draft: String,
    phase: PhoneConversationPhase,
    warningText: String?,
    canRetry: Bool,
    pendingRetryRequestID: String?,
    memoryContextIsEnabled: Bool
  ) {
    self.messages = messages
    self.draft = draft
    self.phase = phase
    self.warningText = warningText
    self.canRetry = canRetry
    self.pendingRetryRequestID = pendingRetryRequestID
    self.memoryContextIsEnabled = memoryContextIsEnabled
  }

  private static func role(
    _ value: ConversationRole
  ) -> PhoneConversationDisplayRole {
    switch value {
    case .user:
      .user
    case .mori:
      .mori
    case .localSystem:
      .localSystem
    }
  }

  private static func warningText(
    _ issues: [ConversationScanIssue]
  ) -> String? {
    guard issues.isEmpty == false else { return nil }
    let hasContact = issues.contains {
      if case .possibleContact = $0 { return true }
      return false
    }
    let hasLocation = issues.contains(.possiblePreciseLocation)
    switch (hasContact, hasLocation) {
    case (true, true):
      return "这段话可能包含联系方式和精确位置。Mori 无法保证识别所有敏感内容，仍要发送吗？"
    case (true, false):
      return "这段话可能包含联系方式。Mori 无法保证识别所有敏感内容，仍要发送吗？"
    case (false, true):
      return "这段话可能包含精确位置。Mori 无法保证识别所有敏感内容，仍要发送吗？"
    case (false, false):
      return nil
    }
  }
}

extension ConversationFailure {
  var phoneMessage: String {
    switch self {
    case .unavailable:
      "正式对话服务尚未接入。"
    case .unauthorized:
      "需要先了解并允许正式对话。"
    case .invalidProfile, .staleAuthority:
      "数据模式或权限已经改变，请重新发送。"
    case .unsafeInput:
      "这段话看起来包含密钥或凭证，因此没有发送。"
    case .offline:
      "现在没有连上服务；本机仍会保留刚才的话。"
    case .timedOut:
      "这次等待超时了，可以稍后重试。"
    case .cancelled:
      "已停止这次回复。"
    case .rateLimited:
      "我们先慢一点，过一会儿再试。"
    case .providerFailure:
      "这次没有收到完整回复。"
    case .malformedResponse:
      "回复格式不完整，因此没有保存。"
    case .oversizedResponse:
      "回复超过安全长度，因此没有保存。"
    case .persistenceFailure:
      "本机对话暂时没能保存。"
    }
  }
}
