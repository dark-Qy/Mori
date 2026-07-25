import CryptoKit
import Foundation
import MoriDomain
import MoriRuntime
import Testing

@Suite("Global deletion transaction")
struct GlobalDeletionCoordinatorTests {
  @Test("Fence local clear peer and processor acknowledgements persist")
  func durableLifecycle() async throws {
    let storage = InMemoryDeletionFenceStorage()
    let coordinator = GlobalDeletionCoordinator(storage: storage)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let epoch = deletionEpoch(10, requestID: "delete-main")
    let ticket = GlobalDeletionRetryTicket(
      processorID: "chat",
      opaqueTicketID: "ticket-chat-delete-main",
      expiresAt: start.addingTimeInterval(86_400)
    )

    let requested = try await coordinator.request(
      deletionEpoch: epoch,
      peerIDs: ["watch"],
      processorIDs: ["chat"],
      retryTickets: [ticket],
      at: start,
      retainUntil: start.addingTimeInterval(7 * 86_400)
    )
    #expect(requested.phase == .requested)
    #expect(requested.pendingPeerIDs == ["watch"])
    #expect(requested.pendingProcessorIDs == ["chat"])

    let prepared = try await coordinator.prepareFence(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(1)
    )
    #expect(prepared.phase == .deletionFencePrepared)

    let cleared = try await coordinator.markLocalContentCleared(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(2)
    )
    #expect(cleared.phase == .peersPending)

    let peerAcknowledged = try await coordinator.acknowledge(
      kind: .peer,
      identifier: "watch",
      deletionEpoch: epoch,
      at: start.addingTimeInterval(3)
    )
    #expect(peerAcknowledged.phase == .processorsPending)

    let completed = try await coordinator.acknowledge(
      kind: .processor,
      identifier: "chat",
      opaqueTicketID: "ticket-chat-delete-main",
      deletionEpoch: epoch,
      at: start.addingTimeInterval(4)
    )
    #expect(completed.phase == .acknowledged)
    #expect(completed.isAcknowledged)

    let relaunched = GlobalDeletionCoordinator(storage: storage)
    #expect(try await relaunched.current() == completed)
    #expect(
      try await relaunched.acknowledge(
        kind: .processor,
        identifier: "chat",
        opaqueTicketID: "ticket-chat-delete-main",
        deletionEpoch: epoch,
        at: start.addingTimeInterval(5)
      ) == completed
    )
  }

  @Test("Processor tickets acknowledge individually and survive relaunch")
  func processorTicketAcknowledgementsPersist() async throws {
    let storage = InMemoryDeletionFenceStorage()
    let coordinator = GlobalDeletionCoordinator(storage: storage)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let epoch = deletionEpoch(10, requestID: "delete-ticket-by-ticket")
    _ = try await coordinator.request(
      deletionEpoch: epoch,
      peerIDs: [],
      processorIDs: ["chat"],
      retryTickets: [
        GlobalDeletionRetryTicket(
          processorID: "chat",
          opaqueTicketID: "old-ticket",
          expiresAt: start.addingTimeInterval(3_600)
        ),
        GlobalDeletionRetryTicket(
          processorID: "chat",
          opaqueTicketID: "new-ticket",
          expiresAt: start.addingTimeInterval(3_600)
        ),
      ],
      at: start,
      retainUntil: start.addingTimeInterval(86_400)
    )
    _ = try await coordinator.prepareFence(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(1)
    )
    _ = try await coordinator.markLocalContentCleared(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(2)
    )

    await #expect(
      throws: GlobalDeletionCoordinatorError.retryTicketRequired(
        processorID: "chat"
      )
    ) {
      _ = try await coordinator.acknowledge(
        kind: .processor,
        identifier: "chat",
        deletionEpoch: epoch,
        at: start.addingTimeInterval(3)
      )
    }
    let partial = try await coordinator.acknowledge(
      kind: .processor,
      identifier: "chat",
      opaqueTicketID: "old-ticket",
      deletionEpoch: epoch,
      at: start.addingTimeInterval(4)
    )
    #expect(partial.phase == .processorsPending)
    #expect(partial.pendingProcessorIDs == ["chat"])
    #expect(
      partial.retryTickets.first {
        $0.opaqueTicketID == "old-ticket"
      }?.acknowledgedAt == start.addingTimeInterval(4)
    )
    #expect(
      partial.retryTickets.first {
        $0.opaqueTicketID == "new-ticket"
      }?.acknowledgedAt == nil
    )

    let relaunched = GlobalDeletionCoordinator(storage: storage)
    #expect(try await relaunched.current() == partial)
    await #expect(
      throws: GlobalDeletionCoordinatorError.unknownRetryTicket(
        processorID: "chat",
        opaqueTicketID: "failed-new-ticket"
      )
    ) {
      _ = try await relaunched.acknowledge(
        kind: .processor,
        identifier: "chat",
        opaqueTicketID: "failed-new-ticket",
        deletionEpoch: epoch,
        at: start.addingTimeInterval(5)
      )
    }
    #expect(try await relaunched.current() == partial)

    let completed = try await relaunched.acknowledge(
      kind: .processor,
      identifier: "chat",
      opaqueTicketID: "new-ticket",
      deletionEpoch: epoch,
      at: start.addingTimeInterval(6)
    )
    #expect(completed.phase == .acknowledged)
    #expect(completed.pendingProcessorIDs.isEmpty)
    #expect(completed.retryTickets.allSatisfy { $0.acknowledgedAt != nil })
    let secondRelaunch = GlobalDeletionCoordinator(storage: storage)
    #expect(try await secondRelaunch.current() == completed)
  }

  @Test("A processor without tickets acknowledges at participant scope")
  func processorWithoutTicketsAcknowledgesDirectly() async throws {
    let coordinator = GlobalDeletionCoordinator(
      storage: InMemoryDeletionFenceStorage()
    )
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let epoch = deletionEpoch(10, requestID: "delete-no-ticket")
    _ = try await coordinator.request(
      deletionEpoch: epoch,
      peerIDs: [],
      processorIDs: ["local-index"],
      at: start,
      retainUntil: start.addingTimeInterval(86_400)
    )
    _ = try await coordinator.prepareFence(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(1)
    )
    _ = try await coordinator.markLocalContentCleared(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(2)
    )

    let acknowledged = try await coordinator.acknowledge(
      kind: .processor,
      identifier: "local-index",
      deletionEpoch: epoch,
      at: start.addingTimeInterval(3)
    )
    #expect(acknowledged.phase == .acknowledged)
  }

  @Test("Same-epoch retry merges obligations and newer deletion supersedes")
  func retryAndSupersession() async throws {
    let storage = InMemoryDeletionFenceStorage()
    let coordinator = GlobalDeletionCoordinator(storage: storage)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = deletionEpoch(10, requestID: "delete-first")

    let initial = try await coordinator.request(
      deletionEpoch: first,
      peerIDs: [],
      processorIDs: [],
      at: start,
      retainUntil: start.addingTimeInterval(86_400)
    )
    let exactRetry = try await coordinator.request(
      deletionEpoch: first,
      peerIDs: [],
      processorIDs: [],
      at: start,
      retainUntil: start.addingTimeInterval(86_400)
    )
    #expect(exactRetry == initial)

    let mergedRetry = try await coordinator.request(
      deletionEpoch: first,
      peerIDs: ["late-peer"],
      processorIDs: [],
      at: start.addingTimeInterval(1),
      retainUntil: start.addingTimeInterval(86_401)
    )
    #expect(mergedRetry.pendingPeerIDs == ["late-peer"])
    #expect(mergedRetry.createdAt == initial.createdAt)
    #expect(
      mergedRetry.retainUntil
        == start.addingTimeInterval(86_401)
    )

    let second = deletionEpoch(11, requestID: "delete-second")
    let superseding = try await coordinator.request(
      deletionEpoch: second,
      peerIDs: ["watch"],
      processorIDs: [],
      at: start.addingTimeInterval(2),
      retainUntil: start.addingTimeInterval(86_402)
    )
    #expect(superseding.deletionEpoch == second)
    #expect(superseding.phase == .requested)
    #expect(superseding.pendingPeerIDs == ["late-peer", "watch"])

    await #expect(
      throws: GlobalDeletionCoordinatorError.staleDeletionEpoch
    ) {
      _ = try await coordinator.request(
        deletionEpoch: first,
        peerIDs: [],
        processorIDs: [],
        at: start.addingTimeInterval(3),
        retainUntil: start.addingTimeInterval(86_403)
      )
    }
  }

  @Test("Same-epoch conflicting ticket identity fails closed")
  func sameEpochTicketConflict() async throws {
    let storage = InMemoryDeletionFenceStorage()
    let coordinator = GlobalDeletionCoordinator(storage: storage)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let epoch = deletionEpoch(10, requestID: "delete-ticket-conflict")
    let original = GlobalDeletionRetryTicket(
      processorID: "chat",
      opaqueTicketID: "stable-ticket",
      expiresAt: start.addingTimeInterval(3_600)
    )
    let initial = try await coordinator.request(
      deletionEpoch: epoch,
      peerIDs: [],
      processorIDs: ["chat"],
      retryTickets: [original],
      at: start,
      retainUntil: start.addingTimeInterval(86_400)
    )

    await #expect(
      throws: GlobalDeletionCoordinatorError.conflictingRetryTicket(
        processorID: "chat",
        opaqueTicketID: "stable-ticket"
      )
    ) {
      _ = try await coordinator.request(
        deletionEpoch: epoch,
        peerIDs: [],
        processorIDs: ["chat"],
        retryTickets: [
          GlobalDeletionRetryTicket(
            processorID: "chat",
            opaqueTicketID: "stable-ticket",
            expiresAt: start.addingTimeInterval(7_200)
          )
        ],
        at: start,
        retainUntil: start.addingTimeInterval(86_400)
      )
    }
    #expect(try await coordinator.current() == initial)
  }

  @Test("New epoch inherits every pending participant and ticket")
  func supersessionInheritsPendingObligations() async throws {
    let coordinator = GlobalDeletionCoordinator(
      storage: InMemoryDeletionFenceStorage()
    )
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = deletionEpoch(10, requestID: "delete-old")
    let oldRetainUntil = start.addingTimeInterval(7 * 86_400)
    _ = try await coordinator.request(
      deletionEpoch: first,
      peerIDs: ["watch"],
      processorIDs: ["chat", "completed-processor"],
      retryTickets: [
        GlobalDeletionRetryTicket(
          processorID: "chat",
          opaqueTicketID: "old-chat-completed",
          expiresAt: start.addingTimeInterval(86_400)
        ),
        GlobalDeletionRetryTicket(
          processorID: "chat",
          opaqueTicketID: "old-chat-pending",
          expiresAt: start.addingTimeInterval(86_400)
        ),
        GlobalDeletionRetryTicket(
          processorID: "completed-processor",
          opaqueTicketID: "completed-ticket",
          expiresAt: start.addingTimeInterval(86_400)
        ),
      ],
      at: start,
      retainUntil: oldRetainUntil
    )
    _ = try await coordinator.prepareFence(
      deletionEpoch: first,
      at: start.addingTimeInterval(1)
    )
    _ = try await coordinator.markLocalContentCleared(
      deletionEpoch: first,
      at: start.addingTimeInterval(2)
    )
    _ = try await coordinator.acknowledge(
      kind: .processor,
      identifier: "chat",
      opaqueTicketID: "old-chat-completed",
      deletionEpoch: first,
      at: start.addingTimeInterval(3)
    )
    _ = try await coordinator.acknowledge(
      kind: .processor,
      identifier: "completed-processor",
      opaqueTicketID: "completed-ticket",
      deletionEpoch: first,
      at: start.addingTimeInterval(4)
    )

    let second = deletionEpoch(11, requestID: "delete-new")
    let superseding = try await coordinator.request(
      deletionEpoch: second,
      peerIDs: ["ipad"],
      processorIDs: ["chat", "export"],
      retryTickets: [
        GlobalDeletionRetryTicket(
          processorID: "chat",
          opaqueTicketID: "new-chat-ticket",
          expiresAt: start.addingTimeInterval(2 * 86_400)
        ),
        GlobalDeletionRetryTicket(
          processorID: "export",
          opaqueTicketID: "export-ticket",
          expiresAt: start.addingTimeInterval(2 * 86_400)
        ),
      ],
      at: start.addingTimeInterval(10),
      retainUntil: start.addingTimeInterval(2 * 86_400)
    )

    #expect(superseding.phase == .requested)
    #expect(superseding.createdAt == start)
    #expect(superseding.retainUntil == oldRetainUntil)
    #expect(superseding.pendingPeerIDs == ["ipad", "watch"])
    #expect(superseding.pendingProcessorIDs == ["chat", "export"])
    #expect(
      superseding.retryTickets.map(\.opaqueTicketID)
        == [
          "new-chat-ticket",
          "old-chat-completed",
          "old-chat-pending",
          "export-ticket",
        ]
    )
    #expect(
      superseding.retryTickets.first {
        $0.opaqueTicketID == "old-chat-completed"
      }?.acknowledgedAt == start.addingTimeInterval(3)
    )
    #expect(
      superseding.retryTickets.first {
        $0.opaqueTicketID == "old-chat-pending"
      }?.acknowledgedAt == nil
    )
    #expect(
      superseding.participants.contains {
        $0.identifier == "completed-processor"
      } == false
    )
    #expect(
      superseding.retryTickets.contains {
        $0.processorID == "completed-processor"
      } == false
    )
    await #expect(
      throws: GlobalDeletionCoordinatorError.localContentNotCleared
    ) {
      _ = try await coordinator.acknowledge(
        kind: .peer,
        identifier: "watch",
        deletionEpoch: second,
        at: start.addingTimeInterval(11)
      )
    }
  }

  @Test("Same-epoch merge after local clear does not regress the fence")
  func sameEpochMergePreservesLocalClear() async throws {
    let coordinator = GlobalDeletionCoordinator(
      storage: InMemoryDeletionFenceStorage()
    )
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let epoch = deletionEpoch(10, requestID: "delete-cleared")
    _ = try await coordinator.request(
      deletionEpoch: epoch,
      peerIDs: [],
      processorIDs: [],
      at: start,
      retainUntil: start.addingTimeInterval(86_400)
    )
    _ = try await coordinator.prepareFence(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(1)
    )
    let completed = try await coordinator.markLocalContentCleared(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(2)
    )
    #expect(completed.phase == .acknowledged)

    let merged = try await coordinator.request(
      deletionEpoch: epoch,
      peerIDs: ["late-peer"],
      processorIDs: [],
      at: start.addingTimeInterval(3),
      retainUntil: start.addingTimeInterval(86_400)
    )
    #expect(merged.phase == .peersPending)
    let acknowledged = try await coordinator.acknowledge(
      kind: .peer,
      identifier: "late-peer",
      deletionEpoch: epoch,
      at: start.addingTimeInterval(4)
    )
    #expect(acknowledged.phase == .acknowledged)

    let reopened = try await coordinator.request(
      deletionEpoch: epoch,
      peerIDs: [],
      processorIDs: ["chat"],
      retryTickets: [
        GlobalDeletionRetryTicket(
          processorID: "chat",
          opaqueTicketID: "late-chat-ticket",
          expiresAt: start.addingTimeInterval(3_600)
        )
      ],
      at: start.addingTimeInterval(5),
      retainUntil: start.addingTimeInterval(86_400)
    )
    #expect(reopened.phase == .processorsPending)
    #expect(
      reopened.participants.first {
        $0.kind == .peer && $0.identifier == "late-peer"
      }?.status == .acknowledged
    )
    let processorCompleted = try await coordinator.acknowledge(
      kind: .processor,
      identifier: "chat",
      opaqueTicketID: "late-chat-ticket",
      deletionEpoch: epoch,
      at: start.addingTimeInterval(6)
    )
    #expect(processorCompleted.phase == .acknowledged)

    let secondTicket = try await coordinator.request(
      deletionEpoch: epoch,
      peerIDs: [],
      processorIDs: ["chat"],
      retryTickets: [
        GlobalDeletionRetryTicket(
          processorID: "chat",
          opaqueTicketID: "later-chat-ticket",
          expiresAt: start.addingTimeInterval(7_200)
        )
      ],
      at: start.addingTimeInterval(7),
      retainUntil: start.addingTimeInterval(86_400)
    )
    #expect(secondTicket.phase == .processorsPending)
    #expect(
      secondTicket.retryTickets.first {
        $0.opaqueTicketID == "late-chat-ticket"
      }?.acknowledgedAt == start.addingTimeInterval(6)
    )
    #expect(
      secondTicket.retryTickets.first {
        $0.opaqueTicketID == "later-chat-ticket"
      }?.acknowledgedAt == nil
    )
  }

  @Test("Concurrent participant acknowledgements survive one CAS conflict")
  func concurrentAcknowledgementsConverge() async throws {
    let storage = TwoReaderBarrierDeletionFenceStorage()
    let first = GlobalDeletionCoordinator(storage: storage)
    let second = GlobalDeletionCoordinator(storage: storage)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let epoch = deletionEpoch(10, requestID: "delete-concurrent-acks")
    _ = try await first.request(
      deletionEpoch: epoch,
      peerIDs: ["watch"],
      processorIDs: ["chat"],
      at: start,
      retainUntil: start.addingTimeInterval(86_400)
    )
    _ = try await first.prepareFence(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(1)
    )
    _ = try await first.markLocalContentCleared(
      deletionEpoch: epoch,
      at: start.addingTimeInterval(2)
    )
    await storage.armNextTwoLoads()

    async let peer = first.acknowledge(
      kind: .peer,
      identifier: "watch",
      deletionEpoch: epoch,
      at: start.addingTimeInterval(3)
    )
    async let processor = second.acknowledge(
      kind: .processor,
      identifier: "chat",
      deletionEpoch: epoch,
      at: start.addingTimeInterval(3)
    )
    _ = try await (peer, processor)

    let converged = try #require(try await first.current())
    #expect(converged.phase == .acknowledged)
    #expect(converged.pendingPeerIDs.isEmpty)
    #expect(converged.pendingProcessorIDs.isEmpty)
    #expect(
      converged.participants.allSatisfy {
        $0.status == .acknowledged
      }
    )
  }

  @Test("Fresh install rejects an old peer and refuses an unknown newer root")
  func freshInstallHandshake() async throws {
    let coordinator = GlobalDeletionCoordinator(
      storage: InMemoryDeletionFenceStorage()
    )
    let local = deletionEpoch(20, requestID: "local-root")
    let trustedProcessor = deletionEpoch(22, requestID: "processor-delete")

    #expect(
      try await coordinator.resolveFreshInstall(
        localRoot: local,
        trustedExternalFences: [trustedProcessor],
        offeredProfileRoot: deletionEpoch(19, requestID: "offline-watch")
      ) == .rejectStaleContent(highestKnown: trustedProcessor)
    )
    #expect(
      try await coordinator.resolveFreshInstall(
        localRoot: local,
        trustedExternalFences: [trustedProcessor],
        offeredProfileRoot: trustedProcessor
      ) == .accept(deletionEpoch: trustedProcessor)
    )
    #expect(
      try await coordinator.resolveFreshInstall(
        localRoot: local,
        trustedExternalFences: [trustedProcessor],
        offeredProfileRoot: deletionEpoch(23, requestID: "unknown-root")
      ) == .requiresRecovery(highestKnown: trustedProcessor)
    )
  }

  @Test("File store compare-and-swap rejects a stale writer")
  func fileStorageCAS() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "mori-deletion-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("deletion-fence-v1.json")
    let first = FileDeletionFenceStorage(fileURL: fileURL)
    let second = FileDeletionFenceStorage(fileURL: fileURL)
    let firstSnapshot = try await first.load()
    let secondSnapshot = try await second.load()

    _ = try await first.save(
      Data("first".utf8),
      replacing: firstSnapshot.revision
    )
    await #expect(
      throws: GlobalDeletionCoordinatorError.staleStorageRevision
    ) {
      _ = try await second.save(
        Data("stale".utf8),
        replacing: secondSnapshot.revision
      )
    }
    #expect(try await first.load().data == Data("first".utf8))
  }

  @Test("Codec is closed canonical and bounded")
  func codecBoundaries() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let transaction = GlobalDeletionTransaction(
      deletionEpoch: deletionEpoch(10, requestID: "delete-codec"),
      phase: .requested,
      createdAt: start,
      updatedAt: start,
      retainUntil: start.addingTimeInterval(86_400),
      participants: [],
      retryTickets: []
    )
    let codec = GlobalDeletionTransactionCodec()
    let canonical = try codec.encode(transaction)
    #expect(try codec.decode(canonical) == transaction)

    var object = try #require(
      JSONSerialization.jsonObject(with: canonical) as? [String: Any]
    )
    object["privateContent"] = "must-not-survive"
    let extra = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )
    #expect(
      throws: GlobalDeletionCoordinatorError.undeclaredField(
        "$.privateContent"
      )
    ) {
      _ = try codec.decode(extra)
    }
    #expect(
      throws: GlobalDeletionCoordinatorError.nonCanonical
    ) {
      _ = try codec.decode(Data([0x20]) + canonical)
    }
    let bounded = GlobalDeletionTransactionCodec(
      maximumBytes: canonical.count - 1
    )
    #expect(throws: (any Error).self) {
      _ = try bounded.decode(canonical)
    }
  }

  @Test("Pending ticket encoding stays v1-compatible and ACK is canonical")
  func ticketCodecCompatibility() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let epoch = deletionEpoch(10, requestID: "delete-ticket-codec")
    let pendingParticipant = GlobalDeletionParticipant(
      kind: .processor,
      identifier: "chat",
      status: .pending
    )
    let pendingTicket = GlobalDeletionRetryTicket(
      processorID: "chat",
      opaqueTicketID: "legacy-ticket",
      expiresAt: start.addingTimeInterval(3_600)
    )
    let pending = GlobalDeletionTransaction(
      deletionEpoch: epoch,
      phase: .requested,
      createdAt: start,
      updatedAt: start,
      retainUntil: start.addingTimeInterval(86_400),
      participants: [pendingParticipant],
      retryTickets: [pendingTicket]
    )
    let codec = GlobalDeletionTransactionCodec()
    let legacyShape = try codec.encode(pending)
    #expect(try codec.decode(legacyShape) == pending)
    let object = try #require(
      JSONSerialization.jsonObject(with: legacyShape) as? [String: Any]
    )
    let encodedTickets = try #require(
      object["retryTickets"] as? [[String: Any]]
    )
    #expect(encodedTickets.first?["acknowledgedAt"] == nil)

    let acknowledgedAt = start.addingTimeInterval(10)
    let acknowledged = GlobalDeletionTransaction(
      deletionEpoch: epoch,
      phase: .acknowledged,
      createdAt: start,
      updatedAt: acknowledgedAt,
      retainUntil: start.addingTimeInterval(86_400),
      participants: [
        GlobalDeletionParticipant(
          kind: .processor,
          identifier: "chat",
          status: .acknowledged,
          acknowledgedAt: acknowledgedAt
        )
      ],
      retryTickets: [
        GlobalDeletionRetryTicket(
          processorID: "chat",
          opaqueTicketID: "legacy-ticket",
          expiresAt: start.addingTimeInterval(3_600),
          acknowledgedAt: acknowledgedAt
        )
      ]
    )
    let acknowledgedData = try codec.encode(acknowledged)
    #expect(try codec.decode(acknowledgedData) == acknowledged)
    let acknowledgedObject = try #require(
      JSONSerialization.jsonObject(with: acknowledgedData)
        as? [String: Any]
    )
    let acknowledgedTickets = try #require(
      acknowledgedObject["retryTickets"] as? [[String: Any]]
    )
    #expect(acknowledgedTickets.first?["acknowledgedAt"] != nil)
  }

  @Test("Invalid participant and ticket scopes fail closed")
  func invalidParticipants() async throws {
    let coordinator = GlobalDeletionCoordinator(
      storage: InMemoryDeletionFenceStorage()
    )
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await #expect(
      throws: GlobalDeletionCoordinatorError.invalidParticipant
    ) {
      _ = try await coordinator.request(
        deletionEpoch: deletionEpoch(10, requestID: "delete-invalid"),
        peerIDs: ["watch", "watch"],
        processorIDs: [],
        at: start,
        retainUntil: start.addingTimeInterval(86_400)
      )
    }

    await #expect(
      throws: GlobalDeletionCoordinatorError.invalidTransaction
    ) {
      _ = try await coordinator.request(
        deletionEpoch: deletionEpoch(11, requestID: "delete-ticket"),
        peerIDs: [],
        processorIDs: ["chat"],
        retryTickets: [
          GlobalDeletionRetryTicket(
            processorID: "social",
            opaqueTicketID: "wrong-processor",
            expiresAt: start.addingTimeInterval(3_600)
          )
        ],
        at: start,
        retainUntil: start.addingTimeInterval(86_400)
      )
    }
  }
}

private func deletionEpoch(
  _ counter: UInt64,
  requestID: String
) -> DeletionEpoch {
  DeletionEpoch(
    requestID: DeletionRequestID(requestID),
    revision: LamportRevision(
      counter: counter,
      originDeviceID: "iphone"
    )
  )
}

private actor TwoReaderBarrierDeletionFenceStorage:
  DeletionFenceStorage
{
  private var data: Data?
  private var barrierIsArmed = false
  private var barrierLoadCount = 0
  private var barrierWaiters: [CheckedContinuation<Void, Never>] = []

  func armNextTwoLoads() {
    barrierIsArmed = true
    barrierLoadCount = 0
  }

  func load() async -> DeletionFenceStorageSnapshot {
    let snapshot = DeletionFenceStorageSnapshot(
      data: data,
      revision: deletionStorageRevision(for: data)
    )
    if barrierIsArmed {
      barrierLoadCount += 1
      if barrierLoadCount == 2 {
        barrierIsArmed = false
        let waiters = barrierWaiters
        barrierWaiters.removeAll()
        for waiter in waiters {
          waiter.resume()
        }
      } else {
        await withCheckedContinuation { continuation in
          barrierWaiters.append(continuation)
        }
      }
    }
    return snapshot
  }

  func save(
    _ newData: Data,
    replacing expectedRevision: DeletionFenceStorageRevision
  ) throws -> DeletionFenceStorageRevision {
    guard deletionStorageRevision(for: data) == expectedRevision else {
      throw GlobalDeletionCoordinatorError.staleStorageRevision
    }
    data = newData
    return deletionStorageRevision(for: newData)
  }

  private func deletionStorageRevision(
    for data: Data?
  ) -> DeletionFenceStorageRevision {
    guard let data else { return .absent }
    let digest = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return .digest(digest)
  }
}
