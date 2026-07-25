import AVFoundation
import Foundation
import UIKit

private struct MoriSpeechAPIRequest: Encodable {
  let requestID: String

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
  }
}

enum MoriSpeechFailure: Error, Equatable {
  case unavailable
  case unauthorized
  case invalidResponse
  case responseTooLarge
}

protocol MoriSpeechSynthesizing {
  func synthesize(requestID: String?, text: String?) async throws -> Data
}

extension WeeklyMemoryAIRuntimeConfiguration {
  var speechEndpoint: URL {
    baseURL
      .appending(path: "ai")
      .appending(path: "v1")
      .appending(path: "audio")
      .appending(path: "speech")
  }
}

final class MoriSpeechAIClient: MoriSpeechSynthesizing, @unchecked Sendable {
  private static let maximumAudioBytes = 2_097_152

  private let configuration: WeeklyMemoryAIRuntimeConfiguration?
  private let credentialProvider: WeeklyMemoryAICredentialProviding
  private let session: URLSession

  init(
    configuration: WeeklyMemoryAIRuntimeConfiguration?,
    credentialProvider: WeeklyMemoryAICredentialProviding,
    session: URLSession
  ) {
    self.configuration = configuration
    self.credentialProvider = credentialProvider
    self.session = session
  }

  static func live() -> MoriSpeechAIClient {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.timeoutIntervalForRequest = 10
    sessionConfiguration.timeoutIntervalForResource = 12
    sessionConfiguration.waitsForConnectivity = false
    return MoriSpeechAIClient(
      configuration: .live(),
      credentialProvider: LiveWeeklyMemoryAICredentialProvider.make(),
      session: URLSession(configuration: sessionConfiguration)
    )
  }

  func synthesize(requestID: String?, text _: String?) async throws -> Data {
    guard
      let requestID,
      !requestID.isEmpty,
      let configuration,
      let token = credentialProvider.bearerToken()
    else {
      throw MoriSpeechFailure.unauthorized
    }

    var request = URLRequest(url: configuration.speechEndpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(
      MoriSpeechAPIRequest(requestID: requestID)
    )

    let (data, response) = try await session.data(for: request)
    guard data.count <= Self.maximumAudioBytes else {
      throw MoriSpeechFailure.responseTooLarge
    }
    guard let http = response as? HTTPURLResponse else {
      throw MoriSpeechFailure.invalidResponse
    }
    switch http.statusCode {
    case 200:
      break
    case 401, 403:
      throw MoriSpeechFailure.unauthorized
    default:
      throw MoriSpeechFailure.unavailable
    }
    let contentType =
      http.value(forHTTPHeaderField: "Content-Type")?
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard
      let contentType,
      ["audio/mpeg", "audio/mp3", "audio/x-mpeg"].contains(contentType),
      !data.isEmpty
    else {
      throw MoriSpeechFailure.invalidResponse
    }
    return data
  }
}

#if DEBUG
  private struct MoriStepFunSpeechAPIRequest: Encodable {
    let model: String
    let voice: String
    let input: String
    let instruction: String
    let responseFormat: String

    enum CodingKeys: String, CodingKey {
      case model
      case voice
      case input
      case instruction
      case responseFormat = "response_format"
    }
  }

  struct BundledMoriStepFunCredentialProvider: WeeklyMemoryAICredentialProviding {
    private let resourceURL: URL?

    init(bundle: Bundle = .main) {
      resourceURL = bundle.url(
        forResource: "MoriStepFunToken",
        withExtension: "private"
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

  final class DirectMoriStepFunSpeechAIClient: MoriSpeechSynthesizing,
    @unchecked Sendable
  {
    private static let maximumAudioBytes = 2_097_152
    private static let model = "stepaudio-2.5-tts"
    private static let voice = "ruanmengnvsheng"
    private static let instruction =
      "声音温暖柔和，像熟悉的陪伴者认真回应；普通话清晰，语速稍慢，避免夸张表演。"

    private let endpoint: URL
    private let credentialProvider: WeeklyMemoryAICredentialProviding
    private let session: URLSession

    init(
      endpoint: URL,
      credentialProvider: WeeklyMemoryAICredentialProviding,
      session: URLSession
    ) {
      self.endpoint = endpoint
      self.credentialProvider = credentialProvider
      self.session = session
    }

    static func live() -> DirectMoriStepFunSpeechAIClient {
      let sessionConfiguration = URLSessionConfiguration.ephemeral
      sessionConfiguration.timeoutIntervalForRequest = 20
      sessionConfiguration.timeoutIntervalForResource = 30
      sessionConfiguration.waitsForConnectivity = false
      return DirectMoriStepFunSpeechAIClient(
        endpoint: URL(string: "https://api.stepfun.com/v1/audio/speech")!,
        credentialProvider: BundledMoriStepFunCredentialProvider(),
        session: URLSession(configuration: sessionConfiguration)
      )
    }

    func synthesize(requestID _: String?, text: String?) async throws -> Data {
      guard
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty,
        let token = credentialProvider.bearerToken()
      else {
        throw MoriSpeechFailure.unauthorized
      }

      var request = URLRequest(url: endpoint)
      request.httpMethod = "POST"
      request.timeoutInterval = 20
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.httpBody = try JSONEncoder().encode(
        MoriStepFunSpeechAPIRequest(
          model: Self.model,
          voice: Self.voice,
          input: text,
          instruction: Self.instruction,
          responseFormat: "mp3"
        )
      )

      let (data, response) = try await session.data(for: request)
      guard data.count <= Self.maximumAudioBytes else {
        throw MoriSpeechFailure.responseTooLarge
      }
      guard let http = response as? HTTPURLResponse else {
        throw MoriSpeechFailure.invalidResponse
      }
      switch http.statusCode {
      case 200:
        break
      case 401, 403:
        throw MoriSpeechFailure.unauthorized
      default:
        throw MoriSpeechFailure.unavailable
      }
      let contentType =
        http.value(forHTTPHeaderField: "Content-Type")?
        .split(separator: ";", maxSplits: 1)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      guard
        let contentType,
        ["audio/mpeg", "audio/mp3", "audio/x-mpeg"].contains(contentType),
        !data.isEmpty
      else {
        throw MoriSpeechFailure.invalidResponse
      }
      return data
    }
  }

  final class DebugMoriSpeechRouter: MoriSpeechSynthesizing {
    private let directSynthesizer: any MoriSpeechSynthesizing
    private let gatewaySynthesizer: any MoriSpeechSynthesizing

    init(
      directSynthesizer: any MoriSpeechSynthesizing,
      gatewaySynthesizer: any MoriSpeechSynthesizing
    ) {
      self.directSynthesizer = directSynthesizer
      self.gatewaySynthesizer = gatewaySynthesizer
    }

    static func live() -> DebugMoriSpeechRouter {
      DebugMoriSpeechRouter(
        directSynthesizer: DirectMoriStepFunSpeechAIClient.live(),
        gatewaySynthesizer: MoriSpeechAIClient.live()
      )
    }

    func synthesize(requestID: String?, text: String?) async throws -> Data {
      if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        return try await directSynthesizer.synthesize(
          requestID: requestID,
          text: text
        )
      }
      return try await gatewaySynthesizer.synthesize(
        requestID: requestID,
        text: nil
      )
    }
  }
#endif

@MainActor
protocol MoriSpeechPlaybackCoordinating: AnyObject {
  func speak(
    messageID: String,
    speechRequestID: String?,
    text: String?
  )
  func stop()
}

@MainActor
final class MoriSpeechPlaybackCoordinator: NSObject, MoriSpeechPlaybackCoordinating,
  AVAudioPlayerDelegate
{
  private let synthesizer: any MoriSpeechSynthesizing
  private var synthesisTask: Task<Void, Never>?
  private var player: AVAudioPlayer?
  private var generation: UInt64 = 0
  private var lastMessageID: String?

  init(synthesizer: any MoriSpeechSynthesizing) {
    self.synthesizer = synthesizer
  }

  static func live() -> MoriSpeechPlaybackCoordinator {
    #if DEBUG
      return MoriSpeechPlaybackCoordinator(synthesizer: DebugMoriSpeechRouter.live())
    #else
      return MoriSpeechPlaybackCoordinator(synthesizer: MoriSpeechAIClient.live())
    #endif
  }

  func speak(
    messageID: String,
    speechRequestID: String?,
    text: String?
  ) {
    guard
      UIApplication.shared.applicationState == .active,
      messageID != lastMessageID
    else { return }
    stopCurrentPlayback()
    lastMessageID = messageID
    let currentGeneration = generation
    let text = text?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard speechRequestID?.isEmpty == false || text?.isEmpty == false else {
      deactivateAudioSession()
      return
    }
    let synthesizer = synthesizer
    synthesisTask = Task { [weak self] in
      do {
        let data = try await synthesizer.synthesize(
          requestID: speechRequestID,
          text: text
        )
        try Task.checkCancellation()
        guard
          let self,
          self.generation == currentGeneration
        else { return }
        try self.play(data)
      } catch {
        guard let self, self.generation == currentGeneration else { return }
        self.synthesisTask = nil
        self.deactivateAudioSession()
      }
    }
  }

  func stop() {
    lastMessageID = nil
    stopCurrentPlayback()
  }

  private func stopCurrentPlayback() {
    generation &+= 1
    synthesisTask?.cancel()
    synthesisTask = nil
    player?.stop()
    player = nil
    deactivateAudioSession()
  }

  private func play(_ data: Data) throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playback,
      mode: .spokenAudio,
      options: .duckOthers
    )
    try session.setActive(true)
    let player = try AVAudioPlayer(data: data)
    player.delegate = self
    player.prepareToPlay()
    guard player.play() else {
      throw MoriSpeechFailure.unavailable
    }
    self.player = player
    synthesisTask = nil
  }

  private func deactivateAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  nonisolated func audioPlayerDidFinishPlaying(
    _ player: AVAudioPlayer,
    successfully _: Bool
  ) {
    Task { @MainActor [weak self] in
      guard let self, self.player === player else { return }
      self.player = nil
      self.deactivateAudioSession()
    }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(
    _ player: AVAudioPlayer,
    error _: (any Error)?
  ) {
    Task { @MainActor [weak self] in
      guard let self, self.player === player else { return }
      self.player = nil
      self.deactivateAudioSession()
    }
  }
}

@MainActor
final class DisabledMoriSpeechPlaybackCoordinator: MoriSpeechPlaybackCoordinating {
  func speak(
    messageID _: String,
    speechRequestID _: String?,
    text _: String?
  ) {}
  func stop() {}
}
