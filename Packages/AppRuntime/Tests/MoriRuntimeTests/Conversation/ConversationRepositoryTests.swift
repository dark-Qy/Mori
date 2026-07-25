import Foundation
import MoriDomain
import MoriPersistence
import Testing

@testable import MoriRuntime

@Suite("Profile-scoped conversation repository")
struct ConversationRepositoryTests {
  @Test("A stable client turn is persisted once across retry and relaunch")
  func stableTurnIsIdempotent() async throws {
    let profile = testMockProfile()
    let storage = InMemoryConversationRepositoryStorage()
    let first = try ConversationRepository(
      storage: storage,
      profile: profile,
      originDeviceID: "phone-chat"
    )

    let inserted = try await first.beginTurn(
      requestID: "request-1",
      clientTurnID: "turn-1",
      expectedClearGeneration: 0,
      explicitMessage: "今天有点累。",
      at: Date(timeIntervalSince1970: 100)
    )
    guard case .inserted(let pending) = inserted else {
      Issue.record("Expected a new turn")
      return
    }
    #expect(pending.messages.count == 1)

    let duplicate = try await first.beginTurn(
      requestID: "request-1",
      clientTurnID: "turn-1",
      expectedClearGeneration: 0,
      explicitMessage: "今天有点累。",
      at: Date(timeIntervalSince1970: 101)
    )
    guard case .duplicate(let duplicateState) = duplicate else {
      Issue.record("Expected a duplicate turn")
      return
    }
    #expect(duplicateState.messages.count == 1)

    _ = try await first.appendReply(
      requestID: "request-1",
      clientTurnID: "turn-1",
      clearGeneration: 0,
      content: "我在这里。",
      referencedMemoryIDs: [],
      at: Date(timeIntervalSince1970: 102)
    )
    let second = try ConversationRepository(
      storage: storage,
      profile: profile,
      originDeviceID: "phone-chat"
    )
    let reloaded = try await second.current()
    #expect(reloaded.messages.map(\.role) == [.user, .mori])
    #expect(reloaded.pendingTurns.isEmpty)
    #expect(reloaded.completedTurns.count == 1)

    let completedDuplicate = try await second.beginTurn(
      requestID: "request-1",
      clientTurnID: "turn-1",
      expectedClearGeneration: 0,
      explicitMessage: "不会重复保存",
      at: Date(timeIntervalSince1970: 103)
    )
    guard case .duplicate(let completedState) = completedDuplicate else {
      Issue.record("Expected completed turn to stay idempotent")
      return
    }
    #expect(completedState.messages.count == 2)
  }

  @Test("Clear is generation fenced, idempotent, and removes all chat-derived content")
  func clearIsCompleteAndIdempotent() async throws {
    let profile = testMockProfile()
    let repository = try ConversationRepository(
      storage: InMemoryConversationRepositoryStorage(),
      profile: profile,
      originDeviceID: "phone-chat"
    )
    _ = try await repository.setDraft("还没发出的内容")
    _ = try await repository.recordFirstSendDisclosure(version: 1)
    _ = try await repository.replaceContextIndex(
      [
        ConversationMemoryContextIndexEntry(
          memoryID: MemoryID("memory-1"),
          memoryRevision: revision(5)
        )
      ],
      expectedClearGeneration: 0
    )
    _ = try await repository.beginTurn(
      requestID: "request-1",
      clientTurnID: "turn-1",
      expectedClearGeneration: 0,
      explicitMessage: "你好",
      at: Date(timeIntervalSince1970: 100)
    )
    _ = try await repository.appendLocalFallback(
      requestID: "request-1",
      clientTurnID: "turn-1",
      clearGeneration: 0,
      content: "现在离线，但我还在。",
      at: Date(timeIntervalSince1970: 101)
    )

    let cleared = try await repository.clear(requestID: "clear-1")
    #expect(cleared.clearGeneration == 1)
    #expect(cleared.messages.isEmpty)
    #expect(cleared.localSummary == nil)
    #expect(cleared.draft == nil)
    #expect(cleared.pendingTurns.isEmpty)
    #expect(cleared.completedTurns.isEmpty)
    #expect(cleared.contextIndex.isEmpty)
    #expect(cleared.firstSendDisclosureVersion == 1)

    let duplicate = try await repository.clear(requestID: "clear-1")
    #expect(duplicate.clearGeneration == 1)

    await #expect(throws: ConversationRepositoryError.staleClearGeneration) {
      _ = try await repository.beginTurn(
        requestID: "request-stale",
        clientTurnID: "turn-stale",
        expectedClearGeneration: 0,
        explicitMessage: "不应跨过清除代际",
        at: Date(timeIntervalSince1970: 102)
      )
    }
    #expect(try await repository.current().messages.isEmpty)
  }

  @Test("A reply that arrives after clear cannot resurrect content")
  func lateReplyIsRejected() async throws {
    let profile = testMockProfile()
    let repository = try ConversationRepository(
      storage: InMemoryConversationRepositoryStorage(),
      profile: profile,
      originDeviceID: "phone-chat"
    )
    _ = try await repository.beginTurn(
      requestID: "request-1",
      clientTurnID: "turn-1",
      expectedClearGeneration: 0,
      explicitMessage: "等一等",
      at: Date(timeIntervalSince1970: 100)
    )
    _ = try await repository.clear(requestID: "clear-1")

    await #expect(throws: ConversationRepositoryError.staleClearGeneration) {
      _ = try await repository.appendReply(
        requestID: "request-1",
        clientTurnID: "turn-1",
        clearGeneration: 0,
        content: "迟到回复",
        referencedMemoryIDs: [],
        at: Date(timeIntervalSince1970: 101)
      )
    }
    #expect(try await repository.current().messages.isEmpty)
  }

  @Test("Wrong profile and undeclared persisted fields fail closed")
  func invalidPersistenceFailsClosed() async throws {
    let expected = testMockProfile(counter: 2)
    let foreign = testMockProfile(counter: 3)
    let codec = CanonicalJSONCodec()
    let wrongProfileStorage = InMemoryConversationRepositoryStorage(
      data: try codec.encode(
        ConversationRepositoryState(profile: foreign)
      )
    )
    let wrongProfileRepository = try ConversationRepository(
      storage: wrongProfileStorage,
      profile: expected,
      originDeviceID: "phone-chat"
    )
    await #expect(throws: ConversationRepositoryError.invalidState) {
      _ = try await wrongProfileRepository.current()
    }

    let validData = try codec.encode(
      ConversationRepositoryState(profile: expected)
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: validData) as? [String: Any]
    )
    object["rawHealthSamples"] = ["forbidden"]
    let injected = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )
    let injectedRepository = try ConversationRepository(
      storage: InMemoryConversationRepositoryStorage(data: injected),
      profile: expected,
      originDeviceID: "phone-chat"
    )
    await #expect(throws: ConversationRepositoryError.nonCanonical) {
      _ = try await injectedRepository.current()
    }
  }

  @Test("A stale repository instance cannot overwrite a newer clear generation")
  func crossInstanceClearUsesDiskCAS() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("conversation.json")
    let profile = testMockProfile()
    let first = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: fileURL),
      profile: profile,
      originDeviceID: "phone-chat"
    )
    let stale = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: fileURL),
      profile: profile,
      originDeviceID: "phone-chat"
    )
    let staleWriter = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: fileURL),
      profile: profile,
      originDeviceID: "phone-chat"
    )

    _ = try await first.beginTurn(
      requestID: "request-private",
      clientTurnID: "turn-private",
      expectedClearGeneration: 0,
      explicitMessage: "不应被旧实例恢复",
      at: Date(timeIntervalSince1970: 100)
    )
    #expect(try await stale.current().messages.count == 1)
    #expect(try await staleWriter.current().messages.count == 1)
    let cleared = try await first.clear(requestID: "clear-private")
    #expect(cleared.clearGeneration == 1)

    let refreshed = try await stale.current()
    #expect(refreshed.clearGeneration == 1)
    #expect(refreshed.messages.isEmpty)
    await #expect(throws: ConversationRepositoryError.staleStorageRevision) {
      _ = try await staleWriter.setDraft("触发旧缓存写回")
    }
    let reloaded = try await staleWriter.current()
    #expect(reloaded.clearGeneration == 1)
    #expect(reloaded.messages.isEmpty)
    #expect(reloaded.draft == nil)
  }

  @Test("A retired artifact rejects stale writes after its profile directory is removed")
  func retiredArtifactRejectsStaleWriter() async throws {
    let applicationRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: applicationRoot) }
    let profilesURL =
      applicationRoot
      .appendingPathComponent("mori-runtime-v1", isDirectory: true)
      .appendingPathComponent("profiles", isDirectory: true)
    let fileURL =
      profilesURL
      .appendingPathComponent("mock", isDirectory: true)
      .appendingPathComponent("namespace", isDirectory: true)
      .appendingPathComponent("conversation", isDirectory: true)
      .appendingPathComponent("conversation.json")
    let firstStorage = FileConversationRepositoryStorage(fileURL: fileURL)
    let staleStorage = FileConversationRepositoryStorage(fileURL: fileURL)
    let profile = testMockProfile()
    let first = try ConversationRepository(
      storage: firstStorage,
      profile: profile,
      originDeviceID: "phone-chat"
    )
    let stale = try ConversationRepository(
      storage: staleStorage,
      profile: profile,
      originDeviceID: "phone-chat"
    )

    _ = try await first.beginTurn(
      requestID: "request-private",
      clientTurnID: "turn-private",
      expectedClearGeneration: 0,
      explicitMessage: "全局删除后不能回来",
      at: Date(timeIntervalSince1970: 100)
    )
    #expect(try await stale.current().messages.count == 1)
    try await first.removeAllContent()
    await #expect(throws: ConversationRepositoryError.retiredStorage) {
      _ = try await stale.current()
    }
    try FileManager.default.removeItem(at: profilesURL)

    await #expect(throws: ConversationRepositoryError.retiredStorage) {
      _ = try await stale.setDraft("不得重建旧 namespace")
    }
    #expect(FileManager.default.fileExists(atPath: profilesURL.path) == false)
    let retirementFenceURL =
      applicationRoot
      .appendingPathComponent("mori-runtime-v1", isDirectory: true)
      .appendingPathComponent("conversation-global-retirement-v1.fence")
    #expect(
      FileManager.default.fileExists(
        atPath: retirementFenceURL.path
      )
    )
    let reopened = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: fileURL),
      profile: profile,
      originDeviceID: "phone-chat"
    )
    await #expect(throws: ConversationRepositoryError.retiredStorage) {
      _ = try await reopened.current()
    }
    try await reopened.removeAllContent()
    try await reopened.removeAllContent()
  }

  @Test("Global retirement rejects cached writers from every old profile namespace")
  func globalRetirementRejectsInactiveProfileWriter() async throws {
    let applicationRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: applicationRoot) }
    let runtimeRoot =
      applicationRoot
      .appendingPathComponent("mori-runtime-v1", isDirectory: true)
    let profilesURL =
      runtimeRoot
      .appendingPathComponent("profiles", isDirectory: true)
    let activeFileURL =
      profilesURL
      .appendingPathComponent("mock/active/conversation/conversation.json")
    let inactiveFileURL =
      profilesURL
      .appendingPathComponent("mock/inactive/conversation/conversation.json")
    let active = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: activeFileURL),
      profile: testMockProfile(counter: 1),
      originDeviceID: "phone-chat"
    )
    let inactive = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: inactiveFileURL),
      profile: testMockProfile(counter: 2),
      originDeviceID: "phone-chat"
    )
    _ = try await active.setDraft("active-private")
    _ = try await inactive.setDraft("inactive-private")
    #expect(try await inactive.current().draft == "inactive-private")

    try await active.removeAllContent()
    await #expect(throws: ConversationRepositoryError.retiredStorage) {
      _ = try await inactive.current()
    }
    try FileManager.default.removeItem(at: profilesURL)
    await #expect(throws: ConversationRepositoryError.retiredStorage) {
      _ = try await inactive.setDraft("must-not-return")
    }
    #expect(FileManager.default.fileExists(atPath: profilesURL.path) == false)

    let reopenedInactive = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: inactiveFileURL),
      profile: testMockProfile(counter: 2),
      originDeviceID: "phone-chat"
    )
    await #expect(throws: ConversationRepositoryError.retiredStorage) {
      _ = try await reopenedInactive.current()
    }

    let freshFileURL =
      profilesURL
      .appendingPathComponent("mock/fresh/conversation/conversation.json")
    let fresh = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: freshFileURL),
      profile: testMockProfile(counter: 3),
      originDeviceID: "phone-chat"
    )
    #expect(try await fresh.current().messages.isEmpty)
  }

  @Test("A malformed global retirement manifest fails closed for every profile")
  func malformedGlobalRetirementManifestFailsClosed() async throws {
    let applicationRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: applicationRoot) }
    let runtimeRoot =
      applicationRoot
      .appendingPathComponent("mori-runtime-v1", isDirectory: true)
    try FileManager.default.createDirectory(
      at: runtimeRoot,
      withIntermediateDirectories: true
    )
    try Data("corrupt-retirement-authority".utf8).write(
      to: runtimeRoot.appendingPathComponent(
        "conversation-global-retirement-v1.fence"
      )
    )

    for (namespace, profile) in [
      ("old", testMockProfile(counter: 1)),
      ("fresh", testMockProfile(counter: 2)),
    ] {
      let fileURL =
        runtimeRoot
        .appendingPathComponent(
          "profiles/mock/\(namespace)/conversation/conversation.json"
        )
      let repository = try ConversationRepository(
        storage: FileConversationRepositoryStorage(fileURL: fileURL),
        profile: profile,
        originDeviceID: "phone-chat"
      )
      await #expect(throws: ConversationRepositoryError.retiredStorage) {
        _ = try await repository.current()
      }
      await #expect(throws: ConversationRepositoryError.retiredStorage) {
        _ = try await repository.setDraft("must-not-persist")
      }
    }
  }

  @Test("Retirement is fence-first and does not decode private content")
  func retirementDoesNotDecodeContent() async throws {
    for data in [
      Data("not-json".utf8),
      Data(repeating: 0x41, count: 2_000_000),
    ] {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let fileURL = directory.appendingPathComponent("conversation.json")
      try data.write(to: fileURL)
      let repository = try ConversationRepository(
        storage: FileConversationRepositoryStorage(fileURL: fileURL),
        profile: testMockProfile(),
        originDeviceID: "phone-chat"
      )

      try await repository.removeAllContent()
      #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
      await #expect(throws: ConversationRepositoryError.retiredStorage) {
        _ = try await repository.current()
      }
    }
  }

  @Test("Concurrent save and retirement converge to retired storage")
  func concurrentSaveAndRetirementConverge() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("conversation.json")
    let profile = testMockProfile()
    let owner = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: fileURL),
      profile: profile,
      originDeviceID: "phone-chat"
    )
    let writer = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: fileURL),
      profile: profile,
      originDeviceID: "phone-chat"
    )
    _ = try await owner.setDraft("before")
    #expect(try await writer.current().draft == "before")

    let saveTask = Task {
      try await writer.setDraft("racing")
    }
    let retireTask = Task {
      try await owner.removeAllContent()
    }
    try await retireTask.value
    do {
      _ = try await saveTask.value
    } catch let error as ConversationRepositoryError {
      #expect(
        error == .retiredStorage
          || error == .staleStorageRevision
      )
    }

    let reopened = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: fileURL),
      profile: profile,
      originDeviceID: "phone-chat"
    )
    await #expect(throws: ConversationRepositoryError.retiredStorage) {
      _ = try await reopened.current()
    }
  }

  @Test("Clear bounds its idempotency key and removes only exact staging orphans")
  func clearBoundsRequestAndCleansOrphans() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("conversation.json")
    let repository = try ConversationRepository(
      storage: FileConversationRepositoryStorage(fileURL: fileURL),
      profile: testMockProfile(),
      originDeviceID: "phone-chat"
    )
    _ = try await repository.beginTurn(
      requestID: "request-private",
      clientTurnID: "turn-private",
      expectedClearGeneration: 0,
      explicitMessage: "待清除",
      at: Date(timeIntervalSince1970: 100)
    )

    let orphan = fileURL.deletingLastPathComponent()
      .appendingPathComponent(
        ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
      )
    let unrelated = fileURL.deletingLastPathComponent()
      .appendingPathComponent(
        ".\(fileURL.lastPathComponent).not-a-uuid.tmp"
      )
    try Data("private orphan".utf8).write(to: orphan)
    try Data("unrelated".utf8).write(to: unrelated)

    await #expect(throws: ConversationRepositoryError.invalidContent) {
      _ = try await repository.clear(
        requestID: String(repeating: "x", count: 129)
      )
    }
    _ = try await repository.clear(requestID: String(repeating: "x", count: 128))
    #expect(FileManager.default.fileExists(atPath: orphan.path) == false)
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  private func testMockProfile(
    counter: UInt64 = 1
  ) -> RuntimeProfile {
    let revision = revision(counter)
    let epoch = ProfileEpoch(revision)
    return RuntimeProfile(
      id: ProfileID("mock-\(counter)"),
      epoch: epoch,
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("test-baseline"),
        revision: revision
      ),
      source: .mock(
        scenarioID: MockScenarioID("mock1"),
        selectionEpoch: epoch
      )
    )
  }

  private func revision(
    _ counter: UInt64
  ) -> LamportRevision {
    LamportRevision(
      counter: counter,
      originDeviceID: "phone"
    )
  }
}
