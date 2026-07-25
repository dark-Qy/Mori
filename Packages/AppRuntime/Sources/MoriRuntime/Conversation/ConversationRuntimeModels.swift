import Foundation
import MoriDomain

public struct ConversationRuntimeConfiguration: Hashable, Sendable {
  public static let standard = Self()

  public let maximumRecentMessages: Int
  public let maximumMessageScalars: Int
  public let maximumMemoryExcerptScalars: Int
  public let maximumReplyScalars: Int
  public let maximumRequestBytes: Int
  public let maximumResponseBytes: Int
  public let maximumStoredMessages: Int
  public let maximumStoredBytes: Int
  public let maximumTaskCandidates: Int
  public let requestTimeout: TimeInterval
  public let streamChunkDelay: TimeInterval

  public init(
    maximumRecentMessages: Int = 12,
    maximumMessageScalars: Int = 4_000,
    maximumMemoryExcerptScalars: Int = 500,
    maximumReplyScalars: Int = 2_000,
    maximumRequestBytes: Int = 64 * 1_024,
    maximumResponseBytes: Int = 32 * 1_024,
    maximumStoredMessages: Int = 80,
    maximumStoredBytes: Int = 512 * 1_024,
    maximumTaskCandidates: Int = 1,
    requestTimeout: TimeInterval = 20,
    streamChunkDelay: TimeInterval = 0.04
  ) {
    self.maximumRecentMessages = maximumRecentMessages
    self.maximumMessageScalars = maximumMessageScalars
    self.maximumMemoryExcerptScalars = maximumMemoryExcerptScalars
    self.maximumReplyScalars = maximumReplyScalars
    self.maximumRequestBytes = maximumRequestBytes
    self.maximumResponseBytes = maximumResponseBytes
    self.maximumStoredMessages = maximumStoredMessages
    self.maximumStoredBytes = maximumStoredBytes
    self.maximumTaskCandidates = maximumTaskCandidates
    self.requestTimeout = requestTimeout
    self.streamChunkDelay = streamChunkDelay
  }

  public var isValid: Bool {
    (1...20).contains(maximumRecentMessages)
      && (1...8_000).contains(maximumMessageScalars)
      && (1...500).contains(maximumMemoryExcerptScalars)
      && (1...4_000).contains(maximumReplyScalars)
      && (1_024...256 * 1_024).contains(maximumRequestBytes)
      && (1_024...128 * 1_024).contains(maximumResponseBytes)
      && (2...200).contains(maximumStoredMessages)
      && (16 * 1_024...2 * 1_024 * 1_024).contains(maximumStoredBytes)
      && (0...1).contains(maximumTaskCandidates)
      && (1...60).contains(requestTimeout)
      && (0...1).contains(streamChunkDelay)
  }
}

public struct ChatAuthoritySnapshot: Hashable, Sendable {
  public let profile: RuntimeProfile
  public let remoteChatConsent: MoriConsentRecord
  public let memoryContextConsent: MoriConsentRecord

  public init(
    profile: RuntimeProfile,
    remoteChatConsent: MoriConsentRecord,
    memoryContextConsent: MoriConsentRecord
  ) {
    self.profile = profile
    self.remoteChatConsent = remoteChatConsent
    self.memoryContextConsent = memoryContextConsent
  }

  public var remoteChatIsAuthorized: Bool {
    remoteChatConsent.enabled
      && remoteChatConsent.isValid(for: .remoteChat)
  }

  public var memoryContextIsAuthorized: Bool {
    memoryContextConsent.enabled
      && memoryContextConsent.isValid(for: .memoryContext)
  }
}

public protocol ChatAuthorityProviding: Sendable {
  func currentChatAuthority() async throws -> ChatAuthoritySnapshot
}

public struct ChatAuthorityLease: Hashable, Sendable {
  public let requestID: String
  public let clientTurnID: String
  public let profile: RuntimeProfile
  public let conversationID: ConversationID
  public let conversationClearGeneration: UInt64
  public let remoteChatConsentRevision: LamportRevision
  public let memoryContextConsentRevision: LamportRevision?

  public init(
    requestID: String,
    clientTurnID: String,
    profile: RuntimeProfile,
    conversationID: ConversationID,
    conversationClearGeneration: UInt64,
    remoteChatConsentRevision: LamportRevision,
    memoryContextConsentRevision: LamportRevision?
  ) {
    self.requestID = requestID
    self.clientTurnID = clientTurnID
    self.profile = profile
    self.conversationID = conversationID
    self.conversationClearGeneration = conversationClearGeneration
    self.remoteChatConsentRevision = remoteChatConsentRevision
    self.memoryContextConsentRevision = memoryContextConsentRevision
  }

  public var isValid: Bool {
    requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      && clientTurnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      && profile.isValid
      && conversationID.isValid
  }
}

public enum ChatTransportMode: String, Hashable, Codable, Sendable {
  case localMock
  case remote
}

public struct ChatMessageV1: Hashable, Codable, Sendable {
  public let recordID: ConversationRecordID
  public let role: ConversationRole
  public let content: String

  public init(
    recordID: ConversationRecordID,
    role: ConversationRole,
    content: String
  ) {
    self.recordID = recordID
    self.role = role
    self.content = content
  }

  public func isValid(
    maximumMessageScalars: Int
  ) -> Bool {
    recordID.isValid
      && (role == .user || role == .mori)
      && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      && content.unicodeScalars.count <= maximumMessageScalars
  }
}

public struct ChatAppContextV1: Hashable, Codable, Sendable {
  public let identity: MoriIdentity
  public let tone: MoriTone
  public let approvedEventIDs: [EventID]
  public let selectedMemoryExcerpt: SelectedMemoryExcerpt?

  public init(
    identity: MoriIdentity,
    tone: MoriTone,
    approvedEventIDs: [EventID],
    selectedMemoryExcerpt: SelectedMemoryExcerpt?
  ) {
    self.identity = identity
    self.tone = tone
    self.approvedEventIDs = approvedEventIDs
    self.selectedMemoryExcerpt = selectedMemoryExcerpt
  }

  public func isValid(
    memoryContextIsAuthorized: Bool,
    maximumMemoryExcerptScalars: Int
  ) -> Bool {
    approvedEventIDs.allSatisfy(\.isValid)
      && approvedEventIDs.count <= 8
      && {
        guard let selectedMemoryExcerpt else { return true }
        return memoryContextIsAuthorized
          && selectedMemoryExcerpt.isValid
          && selectedMemoryExcerpt.text.unicodeScalars.count
            <= maximumMemoryExcerptScalars
      }()
  }
}

public struct ChatRequestEnvelopeV1: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1
  public static let currentContractVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let contractVersion: UInt16
  public let requestID: String
  public let clientTurnID: String
  public let profileID: ProfileID
  public let profileEpoch: ProfileEpoch
  public let deletionEpoch: DeletionEpoch
  public let conversationID: ConversationID
  public let conversationClearGeneration: UInt64
  public let remoteChatConsentRevision: LamportRevision
  public let memoryContextConsentRevision: LamportRevision?
  public let explicitMessage: String
  public let recentMessages: [ChatMessageV1]
  public let appContext: ChatAppContextV1

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    contractVersion: UInt16 = Self.currentContractVersion,
    requestID: String,
    clientTurnID: String,
    profile: RuntimeProfile,
    conversationID: ConversationID,
    conversationClearGeneration: UInt64,
    remoteChatConsentRevision: LamportRevision,
    memoryContextConsentRevision: LamportRevision?,
    explicitMessage: String,
    recentMessages: [ChatMessageV1],
    appContext: ChatAppContextV1
  ) {
    self.schemaVersion = schemaVersion
    self.contractVersion = contractVersion
    self.requestID = requestID
    self.clientTurnID = clientTurnID
    profileID = profile.id
    profileEpoch = profile.epoch
    deletionEpoch = profile.deletionEpoch
    self.conversationID = conversationID
    self.conversationClearGeneration = conversationClearGeneration
    self.remoteChatConsentRevision = remoteChatConsentRevision
    self.memoryContextConsentRevision = memoryContextConsentRevision
    self.explicitMessage = explicitMessage
    self.recentMessages = recentMessages
    self.appContext = appContext
  }

  public func isValid(
    for lease: ChatAuthorityLease,
    configuration: ConversationRuntimeConfiguration
  ) -> Bool {
    guard
      schemaVersion == Self.currentSchemaVersion,
      contractVersion == Self.currentContractVersion,
      requestID == lease.requestID,
      clientTurnID == lease.clientTurnID,
      profileID == lease.profile.id,
      profileEpoch == lease.profile.epoch,
      deletionEpoch == lease.profile.deletionEpoch,
      conversationID == lease.conversationID,
      conversationClearGeneration == lease.conversationClearGeneration,
      remoteChatConsentRevision == lease.remoteChatConsentRevision,
      memoryContextConsentRevision == lease.memoryContextConsentRevision,
      explicitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      explicitMessage.unicodeScalars.count <= configuration.maximumMessageScalars,
      recentMessages.count <= configuration.maximumRecentMessages,
      recentMessages.allSatisfy({
        $0.isValid(maximumMessageScalars: configuration.maximumMessageScalars)
      }),
      appContext.isValid(
        memoryContextIsAuthorized: memoryContextConsentRevision != nil,
        maximumMemoryExcerptScalars: configuration.maximumMemoryExcerptScalars
      )
    else {
      return false
    }
    return true
  }
}

public struct ChatResponseEnvelopeV1: Hashable, Codable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1
  public static let currentContractVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let contractVersion: UInt16
  public let requestID: String
  public let clientTurnID: String
  public let profileID: ProfileID
  public let profileEpoch: ProfileEpoch
  public let deletionEpoch: DeletionEpoch
  public let conversationID: ConversationID
  public let conversationClearGeneration: UInt64
  public let replyText: String
  public let taskCandidates: [ChatCandidate]

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    contractVersion: UInt16 = Self.currentContractVersion,
    lease: ChatAuthorityLease,
    replyText: String,
    taskCandidates: [ChatCandidate] = []
  ) {
    self.schemaVersion = schemaVersion
    self.contractVersion = contractVersion
    requestID = lease.requestID
    clientTurnID = lease.clientTurnID
    profileID = lease.profile.id
    profileEpoch = lease.profile.epoch
    deletionEpoch = lease.profile.deletionEpoch
    conversationID = lease.conversationID
    conversationClearGeneration = lease.conversationClearGeneration
    self.replyText = replyText
    self.taskCandidates = taskCandidates
  }

  public func isValid(
    for lease: ChatAuthorityLease,
    configuration: ConversationRuntimeConfiguration,
    approvedEventIDs: Set<EventID>
  ) -> Bool {
    schemaVersion == Self.currentSchemaVersion
      && contractVersion == Self.currentContractVersion
      && requestID == lease.requestID
      && clientTurnID == lease.clientTurnID
      && profileID == lease.profile.id
      && profileEpoch == lease.profile.epoch
      && deletionEpoch == lease.profile.deletionEpoch
      && conversationID == lease.conversationID
      && conversationClearGeneration == lease.conversationClearGeneration
      && replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      && replyText.unicodeScalars.count <= configuration.maximumReplyScalars
      && taskCandidates.count <= configuration.maximumTaskCandidates
      && taskCandidates.allSatisfy {
        ConversationBoundary.acceptsCandidate(
          $0,
          approvedEvents: approvedEventIDs
        )
      }
  }
}

public enum ChatStreamEvent: Hashable, Sendable {
  case chunk(String)
  case completed(ChatResponseEnvelopeV1)
}

public protocol ChatTransport: Sendable {
  var isolation: RuntimeServiceIsolation { get }

  func stream(
    request: ChatRequestEnvelopeV1,
    lease: ChatAuthorityLease
  ) -> AsyncThrowingStream<ChatStreamEvent, any Error>
}

public enum ConversationFailure: String, Error, Hashable, Codable, Sendable {
  case unavailable
  case unauthorized
  case invalidProfile
  case staleAuthority
  case unsafeInput
  case offline
  case timedOut
  case cancelled
  case rateLimited
  case providerFailure
  case malformedResponse
  case oversizedResponse
  case persistenceFailure

  public var isRetryable: Bool {
    switch self {
    case .offline, .timedOut, .rateLimited, .providerFailure:
      true
    default:
      false
    }
  }
}

public enum ConversationPresentationPhase: Hashable, Sendable {
  case idle
  case scanning
  case warningConfirmationRequired
  case sending(requestID: String)
  case streaming(requestID: String, text: String)
  case failed(requestID: String?, failure: ConversationFailure)
}

public struct ConversationPresentationState: Hashable, Sendable {
  public let messages: [ConversationRecord]
  public let draft: String
  public let phase: ConversationPresentationPhase
  public let warnings: [ConversationScanIssue]
  public let canRetry: Bool
  public let pendingRetryRequestID: String?
  public let memoryContextIsEnabled: Bool

  public init(
    messages: [ConversationRecord],
    draft: String = "",
    phase: ConversationPresentationPhase,
    warnings: [ConversationScanIssue] = [],
    canRetry: Bool = false,
    pendingRetryRequestID: String? = nil,
    memoryContextIsEnabled: Bool
  ) {
    self.messages = messages
    self.draft = draft
    self.phase = phase
    self.warnings = warnings
    self.canRetry = canRetry
    self.pendingRetryRequestID = pendingRetryRequestID
    self.memoryContextIsEnabled = memoryContextIsEnabled
  }
}
