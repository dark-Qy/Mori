#if DEBUG
  import AppRuntime
  import Foundation
  import MoriDomain
  import MoriRuntime

  enum PhoneMockProfileSettingsError: Error {
    case invalidProfile
    case invalidPublicPetState
  }

  /// Profile-local, non-product preferences used by the Debug Mock experience.
  ///
  /// Tasks, coins, collection ownership, and equipment are deliberately absent:
  /// `ProductLoopAppRuntime` is the only authority for those product states.
  nonisolated struct PhoneMockProfileSettings: Codable, Equatable, Sendable {
    var proactiveMessagesEnabled = false
    var socialSharingEnabled = false
    var publicPetSocialStateRawValue =
      PublicPetSocialStateV1.greeting.rawValue
    var conversationMemoryContextEnabled = false
  }

  nonisolated final class PhoneMockProfileSettingsRepository:
    @unchecked Sendable
  {
    private struct DeletionFence: Codable {
      let requestID: String
      let epochCounter: UInt64
      let epochOriginDeviceID: String

      init(scope: MoriGlobalProfileScope) {
        requestID = scope.deletionRequestID
        epochCounter = scope.deletionEpochCounter
        epochOriginDeviceID = scope.deletionEpochOriginDeviceID
      }

      func rejects(_ profile: MoriGlobalProfileScope) -> Bool {
        let fence = DeletionEpoch(
          requestID: DeletionRequestID(requestID),
          revision: LamportRevision(
            counter: epochCounter,
            originDeviceID: epochOriginDeviceID
          )
        )
        let candidate = DeletionEpoch(
          requestID: DeletionRequestID(profile.deletionRequestID),
          revision: LamportRevision(
            counter: profile.deletionEpochCounter,
            originDeviceID: profile.deletionEpochOriginDeviceID
          )
        )
        guard candidate == fence else {
          return candidate < fence
        }
        let profileEpoch = LamportRevision(
          counter: profile.profileEpochCounter,
          originDeviceID: profile.profileEpochOriginDeviceID
        )
        return profileEpoch <= fence.revision
      }
    }

    private struct Snapshot: Codable {
      static let currentSchemaVersion = 1

      var schemaVersion = currentSchemaVersion
      var profiles: [String: PhoneMockProfileSettings] = [:]
      var deletionFence: DeletionFence?
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var cached: Snapshot?

    init(fileURL: URL) {
      self.fileURL = fileURL
    }

    func settings(
      profile: MoriGlobalProfileScope
    ) throws -> PhoneMockProfileSettings {
      lock.lock()
      defer { lock.unlock() }
      let snapshot = try loadValidated(profile)
      return snapshot.profiles[profile.storageKey] ?? PhoneMockProfileSettings()
    }

    func remove(profile: MoriGlobalProfileScope) throws {
      lock.lock()
      defer { lock.unlock() }
      var snapshot = try loadValidated(profile)
      snapshot.profiles.removeValue(forKey: profile.storageKey)
      try save(snapshot)
    }

    func deleteAll(fence: MoriGlobalProfileScope) throws {
      lock.lock()
      defer { lock.unlock() }
      guard fence.isMock == false else {
        throw PhoneMockProfileSettingsError.invalidProfile
      }
      try save(
        Snapshot(
          profiles: [:],
          deletionFence: DeletionFence(scope: fence)
        )
      )
    }

    func setAppPreferences(
      profile: MoriGlobalProfileScope,
      proactiveMessagesEnabled: Bool,
      socialSharingEnabled: Bool,
      publicPetSocialStateRawValue: String
    ) throws -> PhoneMockProfileSettings {
      guard
        publicPetSocialStateRawValue.isEmpty == false,
        publicPetSocialStateRawValue.count <= 80
      else {
        throw PhoneMockProfileSettingsError.invalidPublicPetState
      }
      lock.lock()
      defer { lock.unlock() }
      var snapshot = try loadValidated(profile)
      var value =
        snapshot.profiles[profile.storageKey] ?? PhoneMockProfileSettings()
      value.proactiveMessagesEnabled = proactiveMessagesEnabled
      value.socialSharingEnabled = socialSharingEnabled
      value.publicPetSocialStateRawValue = publicPetSocialStateRawValue
      snapshot.profiles[profile.storageKey] = value
      try save(snapshot)
      return value
    }

    func setConversationMemoryContext(
      profile: MoriGlobalProfileScope,
      enabled: Bool
    ) throws -> PhoneMockProfileSettings {
      lock.lock()
      defer { lock.unlock() }
      var snapshot = try loadValidated(profile)
      var value =
        snapshot.profiles[profile.storageKey] ?? PhoneMockProfileSettings()
      value.conversationMemoryContextEnabled = enabled
      snapshot.profiles[profile.storageKey] = value
      try save(snapshot)
      return value
    }

    private func loadValidated(
      _ profile: MoriGlobalProfileScope
    ) throws -> Snapshot {
      try validate(profile)
      let snapshot = try load()
      guard snapshot.deletionFence?.rejects(profile) != true else {
        throw PhoneMockProfileSettingsError.invalidProfile
      }
      return snapshot
    }

    private func validate(_ profile: MoriGlobalProfileScope) throws {
      guard
        profile.isMock,
        profile.mockScenarioID?.isEmpty == false,
        profile.storageKey.count == 64,
        profile.storageKey.allSatisfy({
          $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        })
      else {
        throw PhoneMockProfileSettingsError.invalidProfile
      }
    }

    private func load() throws -> Snapshot {
      if let cached { return cached }
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        let snapshot = Snapshot()
        cached = snapshot
        return snapshot
      }
      let snapshot = try JSONDecoder().decode(
        Snapshot.self,
        from: Data(contentsOf: fileURL)
      )
      guard snapshot.schemaVersion == Snapshot.currentSchemaVersion else {
        throw CocoaError(.coderReadCorrupt)
      }
      cached = snapshot
      return snapshot
    }

    private func save(_ snapshot: Snapshot) throws {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
      cached = snapshot
    }
  }
#endif
