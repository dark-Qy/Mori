import Foundation
import Testing

@testable import MoriDomain

@Suite("Conversation privacy boundary")
struct ConversationBoundaryTests {
  @Test("Selected memory excerpt limit counts Unicode scalars")
  func scalarBoundary() {
    let memoryID = MemoryID("daily")
    let exactly500 = SelectedMemoryExcerpt(
      memoryID: memoryID,
      text: String(repeating: "🐧", count: 500)
    )
    let over500 = SelectedMemoryExcerpt(
      memoryID: memoryID,
      text: String(repeating: "🐧", count: 501)
    )

    #expect(exactly500.text.unicodeScalars.count == 500)
    #expect(exactly500.isValid)
    #expect(over500.isValid == false)
  }

  @Test("An excerpt must reference an explicitly selected memory")
  func excerptMustBeSelected() {
    let excerpt = SelectedMemoryExcerpt(memoryID: MemoryID("memory-a"), text: "一小段")
    let invalid = AppAddedChatContext(
      identity: .penguin,
      tone: .gentle,
      approvedEventIDs: [],
      memoryReferences: [MemoryID("memory-b")],
      selectedMemoryExcerpt: excerpt
    )
    let valid = AppAddedChatContext(
      identity: .penguin,
      tone: .gentle,
      approvedEventIDs: [],
      memoryReferences: [MemoryID("memory-a")],
      selectedMemoryExcerpt: excerpt
    )

    #expect(invalid.isValid == false)
    #expect(valid.isValid)
  }

  @Test("Only matching, visible, bounded recent conversation enters the boundary")
  func recentMessageBoundary() {
    let profile = MoriTestFixtures.profile()
    let validRecord = MoriTestFixtures.conversation("valid", profile: profile)
    let user = UserConversationContext(
      explicitMessage: "Mori，今天我们去了哪里？",
      recentMessages: [validRecord]
    )
    let app = AppAddedChatContext(
      identity: .penguin,
      tone: .gentle,
      approvedEventIDs: [EventID("walk")],
      memoryReferences: [],
      selectedMemoryExcerpt: nil
    )
    #expect(
      ConversationBoundary.validate(
        userContext: user,
        appContext: app,
        profile: profile
      ) == nil
    )

    let foreign = UserConversationContext(
      explicitMessage: user.explicitMessage,
      recentMessages: [
        MoriTestFixtures.conversation(
          "foreign",
          profile: .init(
            id: ProfileID("other"),
            epoch: profile.epoch,
            deletionEpoch: profile.deletionEpoch,
            source: .real
          ))
      ]
    )
    #expect(
      ConversationBoundary.validate(
        userContext: foreign,
        appContext: app,
        profile: profile
      ) == .profileMismatch
    )
  }

  @Test("Model task proposals remain untrusted and need an approved event")
  func candidateBoundary() {
    let approved = EventID("approved")
    #expect(
      ConversationBoundary.acceptsCandidate(
        .taskProposal(kind: .walkTogether, sourceEventID: approved),
        approvedEvents: [approved]
      )
    )
    #expect(
      ConversationBoundary.acceptsCandidate(
        .taskProposal(kind: .walkTogether, sourceEventID: EventID("invented")),
        approvedEvents: [approved]
      ) == false
    )
    #expect(
      ConversationBoundary.acceptsCandidate(.replyText(" \n"), approvedEvents: []) == false
    )
    #expect(
      ConversationBoundary.acceptsCandidate(
        .replyText(String(repeating: "太", count: 2_001)),
        approvedEvents: []
      ) == false
    )
  }

  @Test("Remote recent window rejects local-system, mixed, and unordered records")
  func recentWindowShapeIsStrict() {
    let profile = MoriTestFixtures.profile()
    let base = MoriTestFixtures.conversation("first", profile: profile)
    let local = ConversationRecord(
      header: base.header,
      conversationID: base.conversationID,
      role: .localSystem,
      content: "local fallback",
      localTime: base.localTime,
      referencedMemoryIDs: [],
      revision: base.revision
    )
    let app = AppAddedChatContext(
      identity: .penguin,
      tone: .gentle,
      approvedEventIDs: [],
      memoryReferences: [],
      selectedMemoryExcerpt: nil
    )
    #expect(
      ConversationBoundary.validate(
        userContext: UserConversationContext(
          explicitMessage: "hello",
          recentMessages: [local]
        ),
        appContext: app,
        profile: profile
      ) == .invalidRecord
    )

    let laterFixture = MoriTestFixtures.conversation(
      "second",
      profile: profile,
      revision: MoriTestFixtures.revision(90)
    )
    let otherConversation = ConversationRecord(
      header: laterFixture.header,
      conversationID: ConversationID("other"),
      role: .mori,
      content: laterFixture.content,
      localTime: laterFixture.localTime,
      referencedMemoryIDs: [],
      revision: laterFixture.revision
    )
    #expect(
      ConversationBoundary.validate(
        userContext: UserConversationContext(
          explicitMessage: "hello",
          recentMessages: [base, otherConversation]
        ),
        appContext: app,
        profile: profile
      ) == .invalidRecord
    )
    #expect(
      ConversationBoundary.validate(
        userContext: UserConversationContext(
          explicitMessage: "hello",
          recentMessages: [laterFixture, base]
        ),
        appContext: app,
        profile: profile
      ) == .invalidRecord
    )
  }

  @Test("Conversation is not an Experience event type or decodable payload")
  func conversationCannotEnterExperiencePayload() throws {
    #expect(
      ExperienceEventType.allCases.allSatisfy {
        $0.rawValue.localizedCaseInsensitiveContains("conversation") == false
          && $0.rawValue.localizedCaseInsensitiveContains("chat") == false
      }
    )

    let record = MoriTestFixtures.conversation("private")
    let recordJSON = try JSONEncoder().encode(record)
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(ExperienceSyncPayload.self, from: recordJSON)
    }

    let injectedCase = Data(
      """
      {"conversation":{"_0":\(String(decoding: recordJSON, as: UTF8.self))}}
      """.utf8
    )
    #expect(throws: (any Error).self) {
      _ = try JSONDecoder().decode(ExperienceSyncPayload.self, from: injectedCase)
    }
  }

  @Test("Deleting a conversation scrubs content and removes it from chat projection")
  func deletionScrubsContent() {
    let profile = MoriTestFixtures.profile()
    var state = MoriTestFixtures.state(profile: profile)
    let memory = MoriTestFixtures.memory(profile: profile)
    #expect(ProfileReducer.apply(.memory(memory), to: &state) == .applied)
    let memoryID = memory.header.recordID
    let fixture = MoriTestFixtures.conversation("private", profile: profile)
    let record = ConversationRecord(
      header: fixture.header,
      conversationID: fixture.conversationID,
      role: fixture.role,
      content: fixture.content,
      localTime: fixture.localTime,
      referencedMemoryIDs: [memoryID],
      revision: fixture.revision
    )
    #expect(ProfileReducer.apply(.conversation(record), to: &state) == .applied)

    let deletion = ConversationTransition(
      header: MoriTestFixtures.header(
        ConversationTransitionID("delete-private"),
        profile: profile
      ),
      recordID: record.header.recordID,
      revision: MoriTestFixtures.revision(81),
      deletedAt: MoriTestFixtures.now
    )
    #expect(
      ProfileReducer.apply(.conversationTransition(deletion), to: &state) == .applied
    )
    #expect(state.conversation.first?.content == "")
    #expect(state.conversation.first?.referencedMemoryIDs.isEmpty == true)
    #expect(ProfileQueries.chatContext(from: state).recentMessages.isEmpty)
  }
}
