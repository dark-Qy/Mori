import Foundation
import MoriDomain

#if DEBUG
  public enum DeterministicMockChatBehavior:
    String, CaseIterable, Hashable, Sendable
  {
    case normal
    case offline
    case timedOut
    case rateLimited
    case providerFailure
    case malformedResponse
    case oversizedResponse
    case slowStream
  }

  public struct DeterministicMockChatTransport: ChatTransport, Sendable {
    public let isolation: RuntimeServiceIsolation = .localOnly
    public let behavior: DeterministicMockChatBehavior
    public let configuration: ConversationRuntimeConfiguration

    public init(
      behavior: DeterministicMockChatBehavior = .normal,
      configuration: ConversationRuntimeConfiguration = .standard
    ) {
      self.behavior = behavior
      self.configuration = configuration
    }

    public func stream(
      request: ChatRequestEnvelopeV1,
      lease: ChatAuthorityLease
    ) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
      AsyncThrowingStream { continuation in
        let task = Task {
          do {
            switch behavior {
            case .offline:
              throw ConversationFailure.offline
            case .rateLimited:
              throw ConversationFailure.rateLimited
            case .providerFailure:
              throw ConversationFailure.providerFailure
            case .timedOut:
              try await Task.sleep(
                for: .seconds(configuration.requestTimeout * 2)
              )
            case .normal, .malformedResponse, .oversizedResponse, .slowStream:
              break
            }

            let baseReply = responseText(for: request)
            let reply =
              behavior == .slowStream
              ? baseReply
                + String(
                  repeating: " 我会把这段测试回复慢慢说完。",
                  count: 8
                )
              : baseReply
            let chunkDelay =
              behavior == .slowStream
              ? max(0.2, configuration.streamChunkDelay)
              : configuration.streamChunkDelay
            for chunk in Self.chunks(reply) {
              try Task.checkCancellation()
              if chunkDelay > 0 {
                try await Task.sleep(for: .seconds(chunkDelay))
              }
              continuation.yield(.chunk(chunk))
            }

            let response: ChatResponseEnvelopeV1
            switch behavior {
            case .malformedResponse:
              response = ChatResponseEnvelopeV1(
                schemaVersion: 999,
                lease: lease,
                replyText: reply
              )
            case .oversizedResponse:
              response = ChatResponseEnvelopeV1(
                lease: lease,
                replyText: String(
                  repeating: "太",
                  count: configuration.maximumReplyScalars + 1
                )
              )
            default:
              response = ChatResponseEnvelopeV1(
                lease: lease,
                replyText: reply
              )
            }
            continuation.yield(.completed(response))
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in
          task.cancel()
        }
      }
    }

    private func responseText(
      for request: ChatRequestEnvelopeV1
    ) -> String {
      if let memory = request.appContext.selectedMemoryExcerpt {
        return "我记得那段共同回忆：\(memory.text) 你愿意再和我说说吗？"
      }
      if request.explicitMessage.contains("难过")
        || request.explicitMessage.contains("累")
      {
        return "听起来今天有点不容易。你不用马上变好，我可以先陪你待一会儿。"
      }
      if request.explicitMessage.contains("散步")
        || request.explicitMessage.contains("出去")
      {
        return "好呀。你想出门时我会在这里，但我不会假装知道你还没有告诉我的路。"
      }
      return "我听见了。你想继续说，我就在这里。"
    }

    private static func chunks(
      _ value: String
    ) -> [String] {
      var chunks: [String] = []
      var current = ""
      for scalar in value.unicodeScalars {
        current.unicodeScalars.append(scalar)
        if current.unicodeScalars.count >= 8 {
          chunks.append(current)
          current = ""
        }
      }
      if current.isEmpty == false {
        chunks.append(current)
      }
      return chunks
    }
  }
#endif

public struct UnavailableRemoteChatTransport: ChatTransport, Sendable {
  public let isolation: RuntimeServiceIsolation = .production

  public init() {}

  public func stream(
    request _: ChatRequestEnvelopeV1,
    lease _: ChatAuthorityLease
  ) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      continuation.finish(throwing: ConversationFailure.unavailable)
    }
  }
}

public enum ConversationLocalFallback {
  public static func response(
    for failure: ConversationFailure
  ) -> String? {
    switch failure {
    case .offline:
      "现在没有连上服务，但我还在这里。等网络恢复后，你可以重试刚才那句话。"
    case .timedOut:
      "刚才等得有点久，我们先停在这里。你想继续时可以再试一次。"
    case .rateLimited:
      "我们先慢一点。过一会儿重试，刚才的话不会重复保存。"
    case .providerFailure:
      "这次没有收到完整回复。你的话留在本机，之后可以再试。"
    default:
      nil
    }
  }
}

public enum ConversationAuditOutcome: String, Hashable, Codable, Sendable {
  case completed
  case blockedCredential
  case warningAwaitingConfirmation
  case cancelled
  case offline
  case timedOut
  case rateLimited
  case providerFailure
  case malformedResponse
  case oversizedResponse
  case staleAuthority
  case persistenceFailure
}

public struct ConversationAuditEvent: Hashable, Codable, Sendable {
  public let requestID: String
  public let outcome: ConversationAuditOutcome

  public init(
    requestID: String,
    outcome: ConversationAuditOutcome
  ) {
    self.requestID = requestID
    self.outcome = outcome
  }
}

public protocol ConversationAuditRecording: Sendable {
  func record(_ event: ConversationAuditEvent) async
}

public actor NoopConversationAuditRecorder: ConversationAuditRecording {
  public init() {}

  public func record(_: ConversationAuditEvent) {}
}

public actor InMemoryConversationAuditRecorder:
  ConversationAuditRecording
{
  public private(set) var events: [ConversationAuditEvent] = []

  public init() {}

  public func record(_ event: ConversationAuditEvent) {
    events.append(event)
  }
}
