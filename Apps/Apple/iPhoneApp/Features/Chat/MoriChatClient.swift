import Foundation
import MoriDomain
import MoriRuntime

enum MoriChatAuthor: String, Codable, Equatable {
  case owner = "user"
  case mori = "assistant"
}

struct MoriChatMessage: Identifiable, Codable, Equatable {
  let id: UUID
  let author: MoriChatAuthor
  let text: String

  nonisolated init(
    id: UUID = UUID(),
    author: MoriChatAuthor,
    text: String
  ) {
    self.id = id
    self.author = author
    self.text = text
  }
}

struct MoriChatReply: Equatable {
  enum Source: String, Equatable {
    case upstream
    case fallback
  }

  let text: String
  let source: Source
  let speechRequestID: String?

  init(text: String, source: Source, speechRequestID: String? = nil) {
    self.text = text
    self.source = source
    self.speechRequestID = speechRequestID
  }
}

protocol MoriChatReplying {
  func reply(
    to messages: [MoriChatMessage],
    personality: WeeklyMemoryAIPersonalityProjection
  ) async -> MoriChatReply
}

struct LocalMoriChatClient: MoriChatReplying {
  func reply(
    to messages: [MoriChatMessage],
    personality _: WeeklyMemoryAIPersonalityProjection
  ) async -> MoriChatReply {
    let latest =
      messages.last(where: { $0.author == .owner })?.text
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let text: String
    if latest.contains("累") || latest.contains("疲惫") || latest.contains("难受") {
      text = "我在。先不用把一切说清楚，慢慢来就好。"
    } else if latest.contains("开心") || latest.contains("高兴") || latest.contains("喜欢") {
      text = "听起来是件让人开心的事，我想再听一点。"
    } else if latest.contains("晚安") || latest.contains("睡觉") {
      text = "晚安。我会安静待在这里，明天再见。"
    } else {
      text = "我在听。你可以慢慢说，我会陪着你。"
    }
    return MoriChatReply(text: text, source: .fallback)
  }
}

private struct MoriChatAPIMessage: Codable {
  let role: String
  let content: String
}

private struct MoriChatAPIPersonality: Codable {
  let voice: String
  let pace: String
  let themes: [String]
  let isPersonalized: Bool

  enum CodingKeys: String, CodingKey {
    case voice
    case pace
    case themes
    case isPersonalized = "is_personalized"
  }
}

private struct MoriChatAPIRequest: Codable {
  let requestID: String
  let locale: String
  let messages: [MoriChatAPIMessage]
  let personality: MoriChatAPIPersonality

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case locale
    case messages
    case personality
  }
}

struct MoriChatAPIResponse: Codable {
  let requestID: String
  let reply: String
  let source: String
  let fallbackReason: String?
  let passedOutputChecks: Bool

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case reply
    case source
    case fallbackReason = "fallback_reason"
    case passedOutputChecks = "passed_output_checks"
  }
}

extension WeeklyMemoryAIRuntimeConfiguration {
  var chatReplyEndpoint: URL {
    baseURL
      .appending(path: "ai")
      .appending(path: "v1")
      .appending(path: "chat")
      .appending(path: "reply")
  }
}

final class MoriChatAIClient: MoriChatReplying, @unchecked Sendable {
  private let configuration: WeeklyMemoryAIRuntimeConfiguration?
  private let credentialProvider: WeeklyMemoryAICredentialProviding
  private let session: URLSession
  private let localFallback: any MoriChatReplying

  init(
    configuration: WeeklyMemoryAIRuntimeConfiguration?,
    credentialProvider: WeeklyMemoryAICredentialProviding,
    session: URLSession,
    localFallback: any MoriChatReplying = LocalMoriChatClient()
  ) {
    self.configuration = configuration
    self.credentialProvider = credentialProvider
    self.session = session
    self.localFallback = localFallback
  }

  static func live() -> any MoriChatReplying {
    liveClient()
  }

  static func liveClient() -> MoriChatAIClient {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.timeoutIntervalForRequest = 8
    sessionConfiguration.timeoutIntervalForResource = 10
    sessionConfiguration.waitsForConnectivity = false
    return MoriChatAIClient(
      configuration: .live(),
      credentialProvider: LiveWeeklyMemoryAICredentialProvider.make(),
      session: URLSession(configuration: sessionConfiguration)
    )
  }

  func reply(
    to messages: [MoriChatMessage],
    personality: WeeklyMemoryAIPersonalityProjection
  ) async -> MoriChatReply {
    do {
      let response = try await fetchReply(
        to: messages,
        personality: personality
      )
      return MoriChatReply(
        text: response.reply,
        source: .upstream,
        speechRequestID: response.requestID
      )
    } catch {
      return await localFallback.reply(to: messages, personality: personality)
    }
  }

  func fetchReply(
    to messages: [MoriChatMessage],
    personality: WeeklyMemoryAIPersonalityProjection,
    requestID: String? = nil
  ) async throws -> MoriChatAPIResponse {
    guard
      let configuration,
      let token = credentialProvider.bearerToken(),
      let body = request(
        messages: messages,
        personality: personality,
        requestID: requestID
      )
    else {
      throw ConversationFailure.unauthorized
    }

    do {
      var request = URLRequest(url: configuration.chatReplyEndpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = 8
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.httpBody = try JSONEncoder().encode(body)
      let (data, response) = try await session.data(for: request)
      guard data.count <= 32_768 else {
        throw ConversationFailure.oversizedResponse
      }
      guard let http = response as? HTTPURLResponse else {
        throw ConversationFailure.providerFailure
      }
      switch http.statusCode {
      case 200:
        break
      case 401, 403:
        throw ConversationFailure.unauthorized
      case 408:
        throw ConversationFailure.timedOut
      case 429:
        throw ConversationFailure.rateLimited
      default:
        throw ConversationFailure.providerFailure
      }
      let value = try JSONDecoder().decode(MoriChatAPIResponse.self, from: data)
      let reply = value.reply.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        value.requestID == body.requestID,
        value.passedOutputChecks,
        let source = MoriChatReply.Source(rawValue: value.source),
        !reply.isEmpty,
        reply.count <= 240,
        reply.unicodeScalars.allSatisfy({
          let value = $0.value
          return value == 10 || (value >= 0x20 && !(0x7F...0x9F).contains(value))
        })
      else {
        throw ConversationFailure.malformedResponse
      }
      guard source == .upstream else {
        throw Self.failure(for: value.fallbackReason)
      }
      return value
    } catch let failure as ConversationFailure {
      throw failure
    } catch let error as URLError {
      switch error.code {
      case .timedOut:
        throw ConversationFailure.timedOut
      case .notConnectedToInternet, .networkConnectionLost,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
        throw ConversationFailure.offline
      default:
        throw ConversationFailure.providerFailure
      }
    } catch {
      throw ConversationFailure.malformedResponse
    }
  }

  private func request(
    messages: [MoriChatMessage],
    personality: WeeklyMemoryAIPersonalityProjection,
    requestID: String?
  ) -> MoriChatAPIRequest? {
    var boundedMessages: [MoriChatAPIMessage] = []
    for message in messages.suffix(12) {
      let text = String(
        message.text
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .prefix(500)
      )
      guard !text.isEmpty else { continue }
      let role = message.author.rawValue
      guard
        boundedMessages.last?.role != role,
        !boundedMessages.isEmpty || role == MoriChatAuthor.owner.rawValue
      else { continue }
      boundedMessages.append(MoriChatAPIMessage(role: role, content: text))
    }
    guard
      !boundedMessages.isEmpty,
      boundedMessages.last?.role == MoriChatAuthor.owner.rawValue
    else { return nil }
    return MoriChatAPIRequest(
      requestID:
        requestID
        ?? "chat_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))",
      locale: "zh-CN",
      messages: boundedMessages,
      personality: MoriChatAPIPersonality(
        voice: personality.voice,
        pace: personality.pace,
        themes: personality.themes,
        isPersonalized: personality.isPersonalized
      )
    )
  }

  private static func failure(
    for fallbackReason: String?
  ) -> ConversationFailure {
    switch fallbackReason {
    case "upstream_timeout": .timedOut
    case "upstream_network_error": .offline
    case "upstream_rate_limited": .rateLimited
    case "upstream_unauthorized": .unauthorized
    case "upstream_response_too_large": .oversizedResponse
    case "malformed_upstream_response", "unsafe_upstream_response":
      .malformedResponse
    default: .providerFailure
    }
  }
}

final class MoriChatPersonalityProvider: @unchecked Sendable {
  private let lock = NSLock()
  private var value: WeeklyMemoryAIPersonalityProjection

  init(
    initialValue: WeeklyMemoryAIPersonalityProjection = .moriCore
  ) {
    value = initialValue
  }

  func current() -> WeeklyMemoryAIPersonalityProjection {
    lock.withLock { value }
  }

  func update(_ value: WeeklyMemoryAIPersonalityProjection) {
    lock.withLock {
      self.value = value
    }
  }
}

struct MoriRemoteChatTransport: ChatTransport, Sendable {
  let isolation: RuntimeServiceIsolation = .production

  private let client: MoriChatAIClient
  private let personalityProvider: MoriChatPersonalityProvider

  init(
    client: MoriChatAIClient,
    personalityProvider: MoriChatPersonalityProvider
  ) {
    self.client = client
    self.personalityProvider = personalityProvider
  }

  static func live(
    personalityProvider: MoriChatPersonalityProvider
  ) -> MoriRemoteChatTransport {
    MoriRemoteChatTransport(
      client: MoriChatAIClient.liveClient(),
      personalityProvider: personalityProvider
    )
  }

  func stream(
    request: ChatRequestEnvelopeV1,
    lease: ChatAuthorityLease
  ) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var messages: [MoriChatMessage] = request.recentMessages.compactMap {
            message -> MoriChatMessage? in
            let author: MoriChatAuthor
            switch message.role {
            case .user:
              author = .owner
            case .mori:
              author = .mori
            case .localSystem:
              return nil
            }
            return MoriChatMessage(author: author, text: message.content)
          }
          if messages.last?.author == .owner {
            messages.removeLast()
          }
          messages.append(
            MoriChatMessage(author: .owner, text: request.explicitMessage)
          )
          let response = try await client.fetchReply(
            to: messages,
            personality: personalityProvider.current(),
            requestID: request.requestID
          )
          try Task.checkCancellation()
          continuation.yield(.chunk(response.reply))
          continuation.yield(
            .completed(
              ChatResponseEnvelopeV1(
                lease: lease,
                replyText: response.reply
              )
            )
          )
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
}
