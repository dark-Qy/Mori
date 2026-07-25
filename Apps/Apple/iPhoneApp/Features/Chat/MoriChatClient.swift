import Foundation

enum MoriChatAuthor: String, Codable, Equatable {
  case owner = "user"
  case mori = "assistant"
}

struct MoriChatMessage: Identifiable, Codable, Equatable {
  let id: UUID
  let author: MoriChatAuthor
  let text: String

  init(
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

private struct MoriChatAPIResponse: Codable {
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

final class MoriChatAIClient: MoriChatReplying {
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
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.timeoutIntervalForRequest = 8
    sessionConfiguration.timeoutIntervalForResource = 10
    sessionConfiguration.waitsForConnectivity = false
    return MoriChatAIClient(
      configuration: .live(),
      credentialProvider: ChainedWeeklyMemoryAICredentialProvider(
        providers: [
          KeychainWeeklyMemoryAICredentialProvider(),
          RuntimeWeeklyMemoryAICredentialProvider(),
          BundledWeeklyMemoryAICredentialProvider(),
        ]
      ),
      session: URLSession(configuration: sessionConfiguration)
    )
  }

  func reply(
    to messages: [MoriChatMessage],
    personality: WeeklyMemoryAIPersonalityProjection
  ) async -> MoriChatReply {
    guard
      let configuration,
      let token = credentialProvider.bearerToken(),
      let body = request(messages: messages, personality: personality)
    else {
      return await localFallback.reply(to: messages, personality: personality)
    }

    do {
      var request = URLRequest(url: configuration.chatReplyEndpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = 8
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.httpBody = try JSONEncoder().encode(body)
      let (data, response) = try await session.data(for: request)
      guard
        data.count <= 32_768,
        let http = response as? HTTPURLResponse,
        http.statusCode == 200
      else {
        return await localFallback.reply(to: messages, personality: personality)
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
        return await localFallback.reply(to: messages, personality: personality)
      }
      return MoriChatReply(text: reply, source: source)
    } catch {
      return await localFallback.reply(to: messages, personality: personality)
    }
  }

  private func request(
    messages: [MoriChatMessage],
    personality: WeeklyMemoryAIPersonalityProjection
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
      requestID: "chat_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))",
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
}
