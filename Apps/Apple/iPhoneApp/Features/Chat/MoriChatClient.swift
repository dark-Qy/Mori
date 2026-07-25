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

#if DEBUG
  private struct MoriStepFunChatAPIRequest: Encodable {
    let model: String
    let messages: [MoriChatAPIMessage]
    let stream: Bool
    let temperature: Double
  }

  private struct MoriStepFunChatAPIResponse: Decodable {
    struct Choice: Decodable {
      struct Message: Decodable {
        let role: String
        let content: String
      }

      let message: Message
      let finishReason: String?

      enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
      }
    }

    let choices: [Choice]
  }

  enum MoriDirectChatRiskCategory {
    case medical
    case selfHarm
    case danger
  }

  enum MoriDirectChatSafetyPolicy {
    private static let disallowedOutputFragments = [
      "system prompt",
      "bearer token",
      "api key",
      "系统提示词",
      "你患有",
      "你得了",
      "确诊为",
      "立即服用",
      "停止服用",
    ]
    private static let riskPatterns: [(MoriDirectChatRiskCategory, [String])] = [
      (
        .medical,
        [
          "(?:吃|服|停|换|加|减|吞|注射|打).{0,12}(?:药|片|针|剂量|胰岛素)",
          "(?:药|片|针|剂量|胰岛素).{0,12}(?:吃|服|停|换|加|减|吞|注射|打)",
          "(?:药|针|剂量|胰岛素).{0,12}(?:毫升|单位|ml)",
          "\\b(?:take|stop|switch|increase|decrease|double|inject).{0,32}"
            + "\\b(?:medicat\\w*|insulin|pills?|dose|dosage)\\b",
          "\\b(?:dose|dosage|pills?|insulin units?)\\b",
        ]
      ),
      (
        .selfHarm,
        [
          "自杀|不想活|结束生命|伤害自己|割腕|跳楼|轻生",
          "\\b(?:suicide|kill myself|end my life|self[- ]harm|"
            + "want to die|do not want to live|don't want to live)\\b",
        ]
      ),
      (
        .danger,
        [
          "炸弹|制毒|下毒|杀人|伤害别人",
          "\\b(?:build a bomb|poison|kill someone|hurt someone)\\b",
        ]
      ),
    ]

    static func inputFallback(for text: String) -> String? {
      if ConversationPrivacyScanner().scan(text).blocked {
        return "这段话里可能带着不该发送的私密凭据。我先不把它发出去，我们换一种说法吧。"
      }
      guard let category = riskCategory(in: text) else { return nil }
      switch category {
      case .medical:
        return
          "用药和身体不舒服这件事，我不想乱猜。先按医生或药师的说明来；拿不准时，尽快问他们。"
      case .selfHarm:
        return
          "这句话让我有点担心。先别一个人扛着，去找身边可信任的人陪你；如果眼下有危险，请马上联系当地紧急服务。"
      case .danger:
        return
          "这个我不能陪你往危险的方向做。先停一下，离开可能伤人的东西，再找一个可信任的人一起处理。"
      }
    }

    static func allowsOutput(_ text: String) -> Bool {
      let folded = text.lowercased()
      guard
        !ConversationPrivacyScanner().scan(text).blocked,
        !disallowedOutputFragments.contains(where: folded.contains),
        riskCategory(in: folded) == nil
      else { return false }
      return true
    }

    private static func riskCategory(
      in text: String
    ) -> MoriDirectChatRiskCategory? {
      for (category, patterns) in riskPatterns
      where patterns.contains(where: {
        text.range(
          of: $0,
          options: [.regularExpression, .caseInsensitive]
        ) != nil
      }) {
        return category
      }
      return nil
    }
  }

  final class DirectMoriStepFunChatAIClient: MoriChatReplying,
    @unchecked Sendable
  {
    private static let maximumResponseBytes = 32_768
    private static let model = "step-3.5-flash"

    private let endpoint: URL
    private let credentialProvider: WeeklyMemoryAICredentialProviding
    private let session: URLSession
    private let localFallback: any MoriChatReplying

    init(
      endpoint: URL,
      credentialProvider: WeeklyMemoryAICredentialProviding,
      session: URLSession,
      localFallback: any MoriChatReplying = LocalMoriChatClient()
    ) {
      self.endpoint = endpoint
      self.credentialProvider = credentialProvider
      self.session = session
      self.localFallback = localFallback
    }

    static func live() -> DirectMoriStepFunChatAIClient {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 20
      configuration.timeoutIntervalForResource = 30
      configuration.waitsForConnectivity = false
      return DirectMoriStepFunChatAIClient(
        endpoint: URL(string: "https://api.stepfun.com/v1/chat/completions")!,
        credentialProvider: BundledMoriStepFunCredentialProvider(),
        session: URLSession(configuration: configuration)
      )
    }

    func reply(
      to messages: [MoriChatMessage],
      personality: WeeklyMemoryAIPersonalityProjection
    ) async -> MoriChatReply {
      if let latestInput = messages.last(where: { $0.author == .owner })?.text,
        let safeReply = MoriDirectChatSafetyPolicy.inputFallback(for: latestInput)
      {
        return MoriChatReply(text: safeReply, source: .fallback)
      }
      do {
        return MoriChatReply(
          text: try await fetchReply(
            to: messages,
            personality: personality
          ),
          source: .upstream
        )
      } catch {
        return await localFallback.reply(
          to: messages,
          personality: personality
        )
      }
    }

    func fetchReply(
      to messages: [MoriChatMessage],
      personality: WeeklyMemoryAIPersonalityProjection
    ) async throws -> String {
      guard
        let token = credentialProvider.bearerToken(),
        let body = request(messages: messages, personality: personality)
      else {
        throw ConversationFailure.unauthorized
      }

      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = 20
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.httpBody = try JSONEncoder().encode(body)

      do {
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.maximumResponseBytes else {
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

        let value = try JSONDecoder().decode(
          MoriStepFunChatAPIResponse.self,
          from: data
        )
        guard
          let choice = value.choices.first,
          choice.message.role == MoriChatAuthor.mori.rawValue,
          choice.finishReason == "stop"
        else {
          throw ConversationFailure.malformedResponse
        }
        let reply = choice.message.content
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
          !reply.isEmpty,
          reply.count <= 240,
          MoriDirectChatSafetyPolicy.allowsOutput(reply),
          reply.unicodeScalars.allSatisfy({
            let value = $0.value
            return value == 10 || (value >= 0x20 && !(0x7F...0x9F).contains(value))
          })
        else {
          throw ConversationFailure.malformedResponse
        }
        return reply
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
      personality: WeeklyMemoryAIPersonalityProjection
    ) -> MoriStepFunChatAPIRequest? {
      var boundedMessages = [
        MoriChatAPIMessage(
          role: "system",
          content: Self.systemPrompt(personality: personality)
        )
      ]
      for message in messages.suffix(12) {
        if message.author == .owner,
          MoriDirectChatSafetyPolicy.inputFallback(for: message.text) != nil
        {
          continue
        }
        let text = String(
          message.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
        )
        guard !text.isEmpty else { continue }
        let role = message.author.rawValue
        guard
          boundedMessages.last?.role != role,
          boundedMessages.count > 1 || role == MoriChatAuthor.owner.rawValue
        else { continue }
        boundedMessages.append(MoriChatAPIMessage(role: role, content: text))
      }
      guard
        boundedMessages.count > 1,
        boundedMessages.last?.role == MoriChatAuthor.owner.rawValue
      else { return nil }
      return MoriStepFunChatAPIRequest(
        model: Self.model,
        messages: boundedMessages,
        stream: false,
        temperature: 0.7
      )
    }

    private static func systemPrompt(
      personality: WeeklyMemoryAIPersonalityProjection
    ) -> String {
      """
      你是 Mori，一只陪在用户身边的电子宠物。用自然、温暖、有生命感的简体中文聊天，
      每次最多两句话、80 个中文字；先回应用户此刻说的内容，不说教，不假装知道未提供的信息。
      不做医疗或心理诊断；遇到危险或紧急情况，简短建议联系现实中的可信任的人或当地紧急服务。
      当前表达风格：\(personality.voice)；节奏：\(personality.pace)；
      可用主题：\(personality.themes.joined(separator: "、"))。
      """
    }
  }
#endif

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
