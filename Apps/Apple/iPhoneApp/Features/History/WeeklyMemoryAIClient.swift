import CryptoKit
import Domain
import Foundation
import Security

struct WeeklyMemoryAIPersonalityProjection: Equatable {
  static let cacheSchemaVersion = 2

  var voice: String
  var pace: String
  var themes: [String]
  var isPersonalized: Bool

  init(
    voice: String,
    pace: String,
    themes: [String],
    isPersonalized: Bool = false
  ) {
    self.voice = voice
    self.pace = pace
    self.themes = themes
    self.isPersonalized = isPersonalized
  }

  static let moriCore = WeeklyMemoryAIPersonalityProjection(
    voice: "warm",
    pace: "gentle",
    themes: ["exploration"],
    isPersonalized: false
  )

  init(projection: MoriPersonalityProjection) {
    if !projection.isPersonalized {
      self = .moriCore
      return
    }
    isPersonalized = true
    switch projection.expressionStyle {
    case .gentle: voice = "warm"
    case .concise: voice = "calm"
    case .playful: voice = "playful"
    }
    let basePace: String
    switch projection.companionshipRhythm {
    case .quiet: basePace = "gentle"
    case .balanced: basePace = "balanced"
    case .lively: basePace = "brisk"
    }
    if let sleepRoutine = projection.sleepRoutine,
      sleepRoutine.band == .afterMidnight || sleepRoutine.regularity == .varied
    {
      // Sleep routine is used only to soften Mori's companionship pace. It is not a
      // personality or health label and no exact sleep time reaches the service.
      pace = "gentle"
    } else {
      pace = basePace
    }

    var resolvedThemes: [String] = []
    for activity in projection.preferredActivities {
      switch activity {
      case .walking, .running, .cycling:
        resolvedThemes.append(contentsOf: ["outdoor", "exploration"])
      case .soccer:
        resolvedThemes.append(contentsOf: ["ball_sports", "outdoor"])
      case .tennis, .badminton:
        resolvedThemes.append("racket_sports")
      case .swimming:
        resolvedThemes.append("water_sports")
      case .other:
        break
      }
    }
    for interest in projection.interests {
      switch interest {
      case .exploration:
        resolvedThemes.append("exploration")
      case .movement, .outdoors:
        resolvedThemes.append("outdoor")
      case .quietMoments:
        resolvedThemes.append("mindful")
      case .racketSports:
        resolvedThemes.append("racket_sports")
      case .teamSports:
        resolvedThemes.append("ball_sports")
      case .waterSports:
        resolvedThemes.append("water_sports")
      }
    }
    let uniqueThemes = resolvedThemes.reduce(into: [String]()) { result, theme in
      guard !result.contains(theme) else { return }
      result.append(theme)
    }
    themes = Array(uniqueThemes.prefix(3))
    if themes.isEmpty { themes = ["exploration"] }
  }

  var cacheContextHash: String {
    let value = [
      "v\(Self.cacheSchemaVersion)",
      voice,
      pace,
      themes.joined(separator: ","),
      isPersonalized ? "personalized" : "mori-core",
    ].joined(separator: "|")
    return SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

protocol WeeklyMemoryPolishing {
  func polish(
    _ records: [ArchivedWeeklyMemory],
    personality: WeeklyMemoryAIPersonalityProjection
  ) async -> [ArchivedWeeklyMemory]
}

struct LocalOnlyWeeklyMemoryPolisher: WeeklyMemoryPolishing {
  func polish(
    _ records: [ArchivedWeeklyMemory],
    personality _: WeeklyMemoryAIPersonalityProjection
  ) async -> [ArchivedWeeklyMemory] {
    records
  }
}

protocol WeeklyMemoryAICredentialProviding {
  func bearerToken() -> String?
}

struct KeychainWeeklyMemoryAICredentialProvider: WeeklyMemoryAICredentialProviding {
  static let service = "org.watchcompanion.weekly-memory-ai"
  static let account = "gateway-bearer-token"

  func bearerToken() -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: Self.service,
      kSecAttrAccount: Self.account,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }
}

struct RuntimeWeeklyMemoryAICredentialProvider: WeeklyMemoryAICredentialProviding {
  let processInfo: ProcessInfo

  init(processInfo: ProcessInfo = .processInfo) {
    self.processInfo = processInfo
  }

  func bearerToken() -> String? {
    #if DEBUG
      let value = processInfo.environment["MORI_WEEKLY_AI_GATEWAY_TOKEN"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return value?.isEmpty == false ? value : nil
    #else
      return nil
    #endif
  }
}

struct BundledWeeklyMemoryAICredentialProvider: WeeklyMemoryAICredentialProviding {
  private static let resourceName = "MoriGatewayToken"
  private static let resourceExtension = "private"

  private let resourceURL: URL?

  init(bundle: Bundle = .main) {
    resourceURL = bundle.url(
      forResource: Self.resourceName,
      withExtension: Self.resourceExtension
    )
  }

  init(resourceURL: URL?) {
    self.resourceURL = resourceURL
  }

  func bearerToken() -> String? {
    guard
      let resourceURL,
      let value = try? String(contentsOf: resourceURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    return value
  }
}

struct ChainedWeeklyMemoryAICredentialProvider: WeeklyMemoryAICredentialProviding {
  let providers: [any WeeklyMemoryAICredentialProviding]

  func bearerToken() -> String? {
    providers.lazy.compactMap { $0.bearerToken() }.first
  }
}

struct WeeklyMemoryAIRuntimeConfiguration {
  let baseURL: URL

  var polishEndpoint: URL {
    baseURL
      .appending(path: "ai")
      .appending(path: "v1")
      .appending(path: "weekly-memories")
      .appending(path: "polish")
  }

  static func live(
    bundle: Bundle = .main,
    processInfo: ProcessInfo = .processInfo
  ) -> WeeklyMemoryAIRuntimeConfiguration? {
    let configuredValue: String?
    #if DEBUG
      configuredValue =
        processInfo.environment["MORI_WEEKLY_AI_BASE_URL"]
        ?? bundle.object(forInfoDictionaryKey: "MoriWeeklyAIBaseURL") as? String
    #else
      configuredValue = bundle.object(forInfoDictionaryKey: "MoriWeeklyAIBaseURL") as? String
    #endif
    let rawValue = configuredValue ?? "https://social.bsti.online"
    guard
      let url = URL(string: rawValue),
      url.scheme?.lowercased() == "https",
      url.host != nil,
      url.user == nil,
      url.password == nil
    else { return nil }
    return WeeklyMemoryAIRuntimeConfiguration(baseURL: url)
  }
}

private struct WeeklyMemoryAIActivity: Codable, Equatable {
  let kind: String
  let durationMinutes: Int

  enum CodingKeys: String, CodingKey {
    case kind
    case durationMinutes = "duration_minutes"
  }
}

private struct WeeklyMemoryAIPersonality: Codable, Equatable {
  let voice: String
  let pace: String
  let themes: [String]
}

private struct WeeklyMemoryAIRequest: Encodable {
  let requestID: String
  let sourceHash: String
  let locale: String
  let activities: [WeeklyMemoryAIActivity]
  let totalSteps: Int?
  let activeMinutes: Int?
  let averageSleepMinutes: Int?
  let personality: WeeklyMemoryAIPersonality

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case sourceHash = "source_hash"
    case locale
    case activities
    case totalSteps = "total_steps"
    case activeMinutes = "active_minutes"
    case averageSleepMinutes = "average_sleep_minutes"
    case personality
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(sourceHash, forKey: .sourceHash)
    try container.encode(locale, forKey: .locale)
    try container.encode(activities, forKey: .activities)
    if let totalSteps {
      try container.encode(totalSteps, forKey: .totalSteps)
    } else {
      try container.encodeNil(forKey: .totalSteps)
    }
    if let activeMinutes {
      try container.encode(activeMinutes, forKey: .activeMinutes)
    } else {
      try container.encodeNil(forKey: .activeMinutes)
    }
    if let averageSleepMinutes {
      try container.encode(averageSleepMinutes, forKey: .averageSleepMinutes)
    } else {
      try container.encodeNil(forKey: .averageSleepMinutes)
    }
    try container.encode(personality, forKey: .personality)
  }
}

private struct WeeklyMemoryAIResponse: Codable, Equatable {
  let requestID: String
  let sourceHash: String
  let title: String
  let body: String
  let source: String
  let fallbackReason: String?
  let safe: Bool

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case sourceHash = "source_hash"
    case title
    case body
    case source
    case fallbackReason = "fallback_reason"
    case safe
  }
}

struct CachedWeeklyMemoryPolish: Codable {
  let sourceHash: String
  let contextHash: String
  let title: String
  let body: String
}

actor WeeklyMemoryAICache {
  private let fileURL: URL?
  private var cached: [String: CachedWeeklyMemoryPolish]?

  init(storageDirectory: URL?) {
    fileURL = storageDirectory?.appendingPathComponent("weekly-memory-ai-cache-v1.json")
  }

  func value(
    for sourceHash: String,
    contextHash: String
  ) -> CachedWeeklyMemoryPolish? {
    load()[Self.key(sourceHash: sourceHash, contextHash: contextHash)]
  }

  func save(_ value: CachedWeeklyMemoryPolish) {
    var values = load()
    values[
      Self.key(sourceHash: value.sourceHash, contextHash: value.contextHash)
    ] = value
    cached = values
    guard let fileURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let data = try JSONEncoder().encode(values)
      try data.write(to: fileURL, options: [.atomic])
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path
      )
    } catch {
      // The deterministic report remains available when caching is unavailable.
    }
  }

  private func load() -> [String: CachedWeeklyMemoryPolish] {
    if let cached { return cached }
    guard
      let fileURL,
      let data = try? Data(contentsOf: fileURL),
      let values = try? JSONDecoder().decode(
        [String: CachedWeeklyMemoryPolish].self,
        from: data
      )
    else {
      cached = [:]
      return [:]
    }
    cached = values
    return values
  }

  private static func key(sourceHash: String, contextHash: String) -> String {
    "\(sourceHash):\(contextHash)"
  }
}

final class WeeklyMemoryAIClient: WeeklyMemoryPolishing {
  private let configuration: WeeklyMemoryAIRuntimeConfiguration?
  private let credentialProvider: WeeklyMemoryAICredentialProviding
  private let session: URLSession
  private let cache: WeeklyMemoryAICache

  init(
    configuration: WeeklyMemoryAIRuntimeConfiguration?,
    credentialProvider: WeeklyMemoryAICredentialProviding,
    session: URLSession,
    cache: WeeklyMemoryAICache
  ) {
    self.configuration = configuration
    self.credentialProvider = credentialProvider
    self.session = session
    self.cache = cache
  }

  static func live(storageDirectory: URL?) -> WeeklyMemoryPolishing {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.timeoutIntervalForRequest = 4
    sessionConfiguration.timeoutIntervalForResource = 6
    sessionConfiguration.waitsForConnectivity = false
    return WeeklyMemoryAIClient(
      configuration: .live(),
      credentialProvider: ChainedWeeklyMemoryAICredentialProvider(
        providers: [
          KeychainWeeklyMemoryAICredentialProvider(),
          RuntimeWeeklyMemoryAICredentialProvider(),
          BundledWeeklyMemoryAICredentialProvider(),
        ]
      ),
      session: URLSession(configuration: sessionConfiguration),
      cache: WeeklyMemoryAICache(storageDirectory: storageDirectory)
    )
  }

  func polish(
    _ records: [ArchivedWeeklyMemory],
    personality: WeeklyMemoryAIPersonalityProjection
  ) async -> [ArchivedWeeklyMemory] {
    guard let configuration, let token = credentialProvider.bearerToken() else {
      return records
    }

    var polished: [ArchivedWeeklyMemory] = []
    let contextHash = personality.cacheContextHash
    for record in records {
      if let cached = await cache.value(
        for: record.sourceHash,
        contextHash: contextHash
      ) {
        polished.append(
          record.applyingAIPolish(
            title: cached.title,
            body: cached.body,
            contextHash: contextHash
          )
        )
        continue
      }
      guard let requestBody = request(for: record, personality: personality) else {
        polished.append(record)
        continue
      }
      do {
        var request = URLRequest(url: configuration.polishEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)
        let (data, response) = try await session.data(for: request)
        guard
          data.count <= 32_768,
          let http = response as? HTTPURLResponse,
          http.statusCode == 200
        else {
          polished.append(record)
          continue
        }
        let value = try JSONDecoder().decode(WeeklyMemoryAIResponse.self, from: data)
        guard
          value.requestID == requestBody.requestID,
          value.sourceHash == record.sourceHash,
          value.safe,
          value.source == "upstream",
          value.title.count <= 32,
          value.body.count <= 180,
          !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          polished.append(record)
          continue
        }
        let cached = CachedWeeklyMemoryPolish(
          sourceHash: record.sourceHash,
          contextHash: contextHash,
          title: value.title,
          body: value.body
        )
        await cache.save(cached)
        polished.append(
          record.applyingAIPolish(
            title: value.title,
            body: value.body,
            contextHash: contextHash
          )
        )
      } catch {
        polished.append(record)
      }
    }
    return polished
  }

  private func request(
    for record: ArchivedWeeklyMemory,
    personality: WeeklyMemoryAIPersonalityProjection
  ) -> WeeklyMemoryAIRequest? {
    guard let facts = record.facts else { return nil }
    let activities: [WeeklyMemoryAIActivity]
    if let kind = facts.activityKind, let duration = facts.activityDurationMinutes {
      activities = [WeeklyMemoryAIActivity(kind: kind, durationMinutes: duration)]
    } else {
      activities = []
    }
    guard
      !activities.isEmpty
        || facts.totalSteps != nil
        || facts.activeMinutes != nil
        || facts.averageSleepMinutes != nil
    else { return nil }
    return WeeklyMemoryAIRequest(
      requestID: "mori_\(record.sourceHash.prefix(24))",
      sourceHash: record.sourceHash,
      locale: "zh-CN",
      activities: activities,
      totalSteps: facts.totalSteps,
      activeMinutes: facts.activeMinutes,
      averageSleepMinutes: facts.averageSleepMinutes,
      personality: WeeklyMemoryAIPersonality(
        voice: personality.voice,
        pace: personality.pace,
        themes: personality.themes
      )
    )
  }
}

extension ArchivedWeeklyMemory {
  fileprivate func applyingAIPolish(
    title: String,
    body: String,
    contextHash: String
  ) -> ArchivedWeeklyMemory {
    let metricsDescription =
      metrics
      .map { "\($0.label)\($0.accessibilityValue)" }
      .joined(separator: "，")
    return ArchivedWeeklyMemory(
      weekID: weekID,
      sourceHash: sourceHash,
      weekOrdinal: weekOrdinal,
      weekLabel: weekLabel,
      dateLabel: dateLabel,
      title: title,
      body: body,
      metrics: metrics,
      highlight: highlight,
      facts: facts,
      polishContextHash: contextHash,
      bundledCoverAssetName: bundledCoverAssetName,
      source: .ai,
      isFavorite: isFavorite,
      isHidden: isHidden,
      createdAt: createdAt,
      accessibilityDescription:
        "\(title)。\(body)\(metricsDescription.isEmpty ? "" : " \(metricsDescription)。")"
    )
  }
}
