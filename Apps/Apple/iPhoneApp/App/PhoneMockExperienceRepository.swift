#if DEBUG
  import Foundation
  import MoriDomain
  import MoriRuntime

  struct PhoneMockTaskSettlement: Sendable {
    let projection: PhoneMockExperienceProjection
    let wasAlreadySettled: Bool
  }

  enum PhoneMockPurchaseResult: Sendable {
    case purchased(PhoneMockExperienceProjection)
    case alreadyOwned(PhoneMockExperienceProjection)
    case insufficientBalance(PhoneMockExperienceProjection)
  }

  enum PhoneMockExperienceError: Error {
    case invalidProfile
    case invalidTask
    case unknownItem
    case itemNotOwned
  }

  /// Debug-only durable preview state. Every selected Mock profile generation
  /// has an isolated namespace; a scenario name by itself is never a key.
  nonisolated final class PhoneMockExperienceRepository: @unchecked Sendable {
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
      var profiles: [String: PhoneMockExperienceProjection] = [:]
      var deletionFence: DeletionFence?
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var cached: Snapshot?

    init(fileURL: URL) {
      self.fileURL = fileURL
    }

    func projection(
      profile: MoriGlobalProfileScope
    ) throws -> PhoneMockExperienceProjection {
      lock.lock()
      defer { lock.unlock() }
      let snapshot = try loadValidated(profile)
      return snapshot.profiles[profile.storageKey] ?? .initial
    }

    func reset(
      profile: MoriGlobalProfileScope
    ) throws -> PhoneMockExperienceProjection {
      lock.lock()
      defer { lock.unlock() }
      var snapshot = try loadValidated(profile)
      snapshot.profiles[profile.storageKey] = .initial
      try save(snapshot)
      return .initial
    }

    func deleteAll(fence: MoriGlobalProfileScope) throws {
      lock.lock()
      defer { lock.unlock() }
      guard fence.isMock == false else {
        throw PhoneMockExperienceError.invalidProfile
      }
      try save(
        Snapshot(
          profiles: [:],
          deletionFence: DeletionFence(scope: fence)
        )
      )
    }

    func prepareRecommendedTask(
      profile profileScope: MoriGlobalProfileScope,
      sensing sensingScope: MoriGlobalSensingScope,
      candidate: PhoneRecommendedTask?
    ) throws -> PhoneMockExperienceProjection {
      lock.lock()
      defer { lock.unlock() }
      var snapshot = try loadValidated(profileScope)
      var profile = snapshot.profiles[profileScope.storageKey] ?? .initial
      profile.sensingAuthorization =
        PhoneMockSensingAuthorization(sensingScope)

      guard sensingScope.enabled, let candidate else {
        profile.recommendedTask = nil
        snapshot.profiles[profileScope.storageKey] = profile
        try save(snapshot)
        return profile
      }
      guard
        candidate.isValid,
        candidate.scenarioID == profileScope.mockScenarioID,
        candidate.sensingEpochCounter == sensingScope.epochCounter,
        candidate.sensingEpochOriginDeviceID
          == sensingScope.epochOriginDeviceID
      else {
        throw PhoneMockExperienceError.invalidTask
      }
      if let current = profile.recommendedTask,
        profile.completedTaskIDs.contains(current.id) == false
      {
        guard
          current.sensingEpochCounter != sensingScope.epochCounter
            || current.sensingEpochOriginDeviceID
              != sensingScope.epochOriginDeviceID
        else {
          return profile
        }
        profile.recommendedTask = nil
      }

      var generated = profile.generatedTaskSourceEventIDs ?? []
      guard generated.contains(candidate.sourceEventID) == false else {
        return profile
      }
      let cooldowns = profile.taskCooldownUntilByKey ?? [:]
      if let nextEligibleAt = cooldowns[candidate.cooldownKey],
        candidate.issuedAt < nextEligibleAt
      {
        profile.recommendedTask = nil
        snapshot.profiles[profileScope.storageKey] = profile
        try save(snapshot)
        return profile
      }

      generated.insert(candidate.sourceEventID)
      profile.generatedTaskSourceEventIDs = generated
      profile.recommendedTask = candidate
      var updatedCooldowns = cooldowns
      updatedCooldowns[candidate.cooldownKey] =
        candidate.issuedAt.addingTimeInterval(candidate.cooldownDuration)
      profile.taskCooldownUntilByKey = updatedCooldowns
      snapshot.profiles[profileScope.storageKey] = profile
      try save(snapshot)
      return profile
    }

    func settleTask(
      profile profileScope: MoriGlobalProfileScope,
      sensing sensingScope: MoriGlobalSensingScope,
      taskID: String
    ) throws -> PhoneMockTaskSettlement {
      lock.lock()
      defer { lock.unlock() }
      var snapshot = try loadValidated(profileScope)
      var profile = snapshot.profiles[profileScope.storageKey] ?? .initial
      guard
        let task = profile.recommendedTask,
        task.id == taskID,
        task.isValid,
        sensingScope.enabled,
        profile.sensingAuthorization
          == PhoneMockSensingAuthorization(sensingScope),
        task.sensingEpochCounter == sensingScope.epochCounter,
        task.sensingEpochOriginDeviceID
          == sensingScope.epochOriginDeviceID
      else {
        throw PhoneMockExperienceError.invalidTask
      }
      guard profile.completedTaskIDs.contains(taskID) == false else {
        return PhoneMockTaskSettlement(
          projection: profile,
          wasAlreadySettled: true
        )
      }
      profile.completedTaskIDs.insert(taskID)
      profile.coinBalance += task.reward
      snapshot.profiles[profileScope.storageKey] = profile
      try save(snapshot)
      return PhoneMockTaskSettlement(
        projection: profile,
        wasAlreadySettled: false
      )
    }

    func purchase(
      profile profileScope: MoriGlobalProfileScope,
      itemID: String
    ) throws -> PhoneMockPurchaseResult {
      lock.lock()
      defer { lock.unlock() }
      guard let item = PhoneCollectionItem.catalog.first(where: { $0.id == itemID })
      else {
        throw PhoneMockExperienceError.unknownItem
      }
      var snapshot = try loadValidated(profileScope)
      var profile = snapshot.profiles[profileScope.storageKey] ?? .initial
      if profile.ownedItemIDs.contains(itemID) {
        return .alreadyOwned(profile)
      }
      let cost = item.price
      guard profile.coinBalance >= cost else {
        return .insufficientBalance(profile)
      }
      profile.coinBalance -= cost
      profile.ownedItemIDs.insert(itemID)
      snapshot.profiles[profileScope.storageKey] = profile
      try save(snapshot)
      return .purchased(profile)
    }

    func equip(
      profile profileScope: MoriGlobalProfileScope,
      itemID: String
    ) throws -> PhoneMockExperienceProjection {
      lock.lock()
      defer { lock.unlock() }
      guard
        let item = PhoneCollectionItem.catalog.first(where: { $0.id == itemID }),
        item.sceneID == nil
      else {
        throw PhoneMockExperienceError.unknownItem
      }
      var snapshot = try loadValidated(profileScope)
      var profile = snapshot.profiles[profileScope.storageKey] ?? .initial
      guard profile.ownedItemIDs.contains(itemID) else {
        throw PhoneMockExperienceError.itemNotOwned
      }
      switch item.category {
      case .clothing:
        profile.equippedItemID = itemID
      case .accessories:
        profile.equippedAccessoryID = itemID
      case .scenes:
        throw PhoneMockExperienceError.unknownItem
      }
      snapshot.profiles[profileScope.storageKey] = profile
      try save(snapshot)
      return profile
    }

    func selectScene(
      profile profileScope: MoriGlobalProfileScope,
      sceneID: String
    ) throws -> PhoneMockExperienceProjection {
      lock.lock()
      defer { lock.unlock() }
      guard
        PhoneCollectionItem.catalog.contains(where: {
          $0.id == sceneID && $0.sceneID == sceneID
        })
      else {
        throw PhoneMockExperienceError.unknownItem
      }
      var snapshot = try loadValidated(profileScope)
      var profile = snapshot.profiles[profileScope.storageKey] ?? .initial
      guard profile.ownedItemIDs.contains(sceneID) else {
        throw PhoneMockExperienceError.itemNotOwned
      }
      profile.selectedSceneID = sceneID
      snapshot.profiles[profileScope.storageKey] = profile
      try save(snapshot)
      return profile
    }

    func appendConversation(
      profile profileScope: MoriGlobalProfileScope,
      userText: String,
      moriText: String
    ) throws -> PhoneMockExperienceProjection {
      lock.lock()
      defer { lock.unlock() }
      var snapshot = try loadValidated(profileScope)
      var profile = snapshot.profiles[profileScope.storageKey] ?? .initial
      profile.conversation.append(
        PhoneConversationMessage(role: .user, text: String(userText.prefix(500)))
      )
      profile.conversation.append(
        PhoneConversationMessage(role: .mori, text: String(moriText.prefix(500)))
      )
      profile.conversation = Array(profile.conversation.suffix(40))
      snapshot.profiles[profileScope.storageKey] = profile
      try save(snapshot)
      return profile
    }

    func clearConversation(
      profile profileScope: MoriGlobalProfileScope
    ) throws -> PhoneMockExperienceProjection {
      lock.lock()
      defer { lock.unlock() }
      var snapshot = try loadValidated(profileScope)
      var profile = snapshot.profiles[profileScope.storageKey] ?? .initial
      profile.conversation = PhoneMockExperienceProjection.initial.conversation
      snapshot.profiles[profileScope.storageKey] = profile
      try save(snapshot)
      return profile
    }

    func setMemoryContext(
      profile profileScope: MoriGlobalProfileScope,
      enabled: Bool
    ) throws -> PhoneMockExperienceProjection {
      lock.lock()
      defer { lock.unlock() }
      var snapshot = try loadValidated(profileScope)
      var profile = snapshot.profiles[profileScope.storageKey] ?? .initial
      profile.usesMemoryContext = enabled
      snapshot.profiles[profileScope.storageKey] = profile
      try save(snapshot)
      return profile
    }

    func setAppPreferences(
      profile profileScope: MoriGlobalProfileScope,
      proactiveMessagesEnabled: Bool,
      socialSharingEnabled: Bool,
      publicPetSocialStateRawValue: String
    ) throws -> PhoneMockExperienceProjection {
      lock.lock()
      defer { lock.unlock() }
      guard
        publicPetSocialStateRawValue.isEmpty == false,
        publicPetSocialStateRawValue.count <= 80
      else {
        throw PhoneMockExperienceError.invalidProfile
      }
      var snapshot = try loadValidated(profileScope)
      var profile = snapshot.profiles[profileScope.storageKey] ?? .initial
      profile.proactiveMessagesEnabled = proactiveMessagesEnabled
      profile.socialSharingEnabled = socialSharingEnabled
      profile.publicPetSocialStateRawValue = publicPetSocialStateRawValue
      snapshot.profiles[profileScope.storageKey] = profile
      try save(snapshot)
      return profile
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
        throw PhoneMockExperienceError.invalidProfile
      }
    }

    private func loadValidated(
      _ profile: MoriGlobalProfileScope
    ) throws -> Snapshot {
      try validate(profile)
      let snapshot = try load()
      guard snapshot.deletionFence?.rejects(profile) != true else {
        throw PhoneMockExperienceError.invalidProfile
      }
      return snapshot
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
