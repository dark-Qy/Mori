import Foundation
import MoriDomain
import MoriPersistence

public enum CollectionMutationRuntimeError:
  Error, Equatable, Sendable
{
  case invalidOriginDeviceID
  case invalidOperationID
  case idempotencyKeyReuse
  case unresolvedMutation
  case unknownItem(CosmeticID)
  case invalidProfileState(MoriDomainRejection)
  case insufficientBalance(required: Int, available: Int)
  case itemNotOwned(CosmeticID)
  case itemSlotMismatch(CosmeticID)
  case mutationRejected(MoriDomainRejection)
  case logicalClockOverflow
}

/// The product authority for purchase price and cosmetic slot.
///
/// Presentation layers may decorate these IDs with localized names and
/// artwork, but must never redefine price or slot.
public struct MoriProductCosmeticCatalog: Sendable {
  public static let product = MoriProductCosmeticCatalog()

  private static let productItems: [CosmeticCatalogItem] = [
    CosmeticCatalogItem(
      id: CosmeticID("scarf"),
      slot: .outfit,
      coinPrice: 8
    ),
    CosmeticCatalogItem(
      id: CosmeticID("soccer_scarf"),
      slot: .outfit,
      coinPrice: 12
    ),
    CosmeticCatalogItem(
      id: CosmeticID("leaf"),
      slot: .accessory,
      coinPrice: 4
    ),
    CosmeticCatalogItem(
      id: CosmeticID("star"),
      slot: .accessory,
      coinPrice: 8
    ),
    CosmeticCatalogItem(
      id: CosmeticID("moonlit_forest_camp"),
      slot: .scene,
      coinPrice: 50
    ),
  ]

  private let itemsByID: [CosmeticID: CosmeticCatalogItem]

  private init() {
    itemsByID = Dictionary(
      uniqueKeysWithValues: Self.productItems.map { ($0.id, $0) }
    )
  }

  public var purchasableItems: [CosmeticCatalogItem] {
    itemsByID.values.sorted { $0.id < $1.id }
  }

  public func item(for cosmeticID: CosmeticID) -> CosmeticCatalogItem? {
    itemsByID[cosmeticID]
  }
}

public struct CollectionOperationID:
  RawRepresentable, Hashable, Codable, Sendable
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  fileprivate var normalized: String {
    rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate var isValid: Bool {
    let value = normalized
    return value.isEmpty == false
      && value.unicodeScalars.count <= 128
      && value.unicodeScalars.allSatisfy {
        $0.isASCII
          && (CharacterSet.alphanumerics.contains($0)
            || $0 == "-"
            || $0 == "_"
            || $0 == ".")
      }
  }
}

public struct CollectionPurchaseMutationResult:
  Equatable, Sendable
{
  public let cosmeticID: CosmeticID
  public let eventID: ExperienceEventID?
  public let didRecordPurchase: Bool
  public let balance: Int

  public init(
    cosmeticID: CosmeticID,
    eventID: ExperienceEventID?,
    didRecordPurchase: Bool,
    balance: Int
  ) {
    self.cosmeticID = cosmeticID
    self.eventID = eventID
    self.didRecordPurchase = didRecordPurchase
    self.balance = balance
  }
}

public struct CollectionEquipMutationResult:
  Equatable, Sendable
{
  public let cosmeticID: CosmeticID
  public let slot: CosmeticSlot
  public let eventID: ExperienceEventID?
  public let didRecordTransition: Bool
  public let isEquipped: Bool

  public init(
    cosmeticID: CosmeticID,
    slot: CosmeticSlot,
    eventID: ExperienceEventID?,
    didRecordTransition: Bool,
    isEquipped: Bool
  ) {
    self.cosmeticID = cosmeticID
    self.slot = slot
    self.eventID = eventID
    self.didRecordTransition = didRecordTransition
    self.isEquipped = isEquipped
  }
}

/// Serializes local collection commands into atomic synchronized envelopes.
///
/// A purchase always carries its debit and ownership in one payload. Stable
/// operation IDs make an interrupted retry byte-identical; state checks make
/// retries with a fresh operation ID harmless after the first commit. A fresh
/// command that is already satisfied still writes a domain-valid receipt, so
/// its operation ID cannot later authorize a different command; that receipt
/// never repeats the original debit.
public actor CollectionMutationRuntime<
  Store: TaskSettlementEventStore
> {
  private let originDeviceID: String
  private let store: Store
  private let catalog: MoriProductCosmeticCatalog
  private var operationIsActive = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    originDeviceID: String,
    store: Store,
    catalog: MoriProductCosmeticCatalog = .product
  ) {
    self.originDeviceID = originDeviceID
    self.store = store
    self.catalog = catalog
  }

  public func purchase(
    cosmeticID: CosmeticID,
    operationID: CollectionOperationID,
    at date: Date
  ) async throws -> CollectionPurchaseMutationResult {
    await acquireOperation()
    defer { releaseOperation() }
    try requireValidInputs(operationID: operationID)
    let ledger = try await validatedLedger()
    let state = ledger.replay().state
    if let existing = operationEnvelope(
      operationID: operationID,
      profile: state.runtimeProfile,
      in: ledger
    ) {
      guard case .collectionPurchase(let purchase) = existing.payload,
        purchase.item.id == cosmeticID
      else {
        throw CollectionMutationRuntimeError.idempotencyKeyReuse
      }
      guard
        state.experienceLedger.contains(where: {
          $0.eventID == existing.eventID
        })
      else {
        throw CollectionMutationRuntimeError.unresolvedMutation
      }
      return CollectionPurchaseMutationResult(
        cosmeticID: cosmeticID,
        eventID: existing.eventID,
        didRecordPurchase: false,
        balance: state.coinLedger.balance
      )
    }
    guard let item = catalog.item(for: cosmeticID) else {
      throw CollectionMutationRuntimeError.unknownItem(cosmeticID)
    }
    let existingOwnership = state.collection.ownership.first(where: {
      $0.cosmeticID == cosmeticID
    })
    if let existing = existingOwnership {
      guard existing.slot == item.slot else {
        throw CollectionMutationRuntimeError.itemSlotMismatch(
          cosmeticID
        )
      }
    }
    guard
      existingOwnership != nil
        || state.coinLedger.balance >= item.coinPrice
    else {
      throw CollectionMutationRuntimeError.insufficientBalance(
        required: item.coinPrice,
        available: state.coinLedger.balance
      )
    }

    let metadata = try metadata(in: ledger)
    let operation = operationID.normalized
    let transaction = CoinTransaction(
      header: header(
        CoinTransactionID(
          stableID(
            prefix: "collection-purchase-transaction",
            profile: state.runtimeProfile,
            components: [operation]
          )
        ),
        profile: state.runtimeProfile
      ),
      revision: metadata.revision,
      authoredAt: date,
      direction: .debit,
      amount: item.coinPrice,
      reason: .cosmeticPurchase(item.id)
    )
    let ownership = CollectionOwnershipRecord(
      header: header(
        CollectionOwnershipID(
          stableID(
            prefix: "collection-operation",
            profile: state.runtimeProfile,
            components: [operation]
          )
        ),
        profile: state.runtimeProfile
      ),
      cosmeticID: item.id,
      slot: item.slot,
      acquiredAt: date,
      purchaseTransactionID: transaction.header.recordID,
      revision: metadata.revision
    )
    let payload = ExperienceSyncPayload.collectionPurchase(
      CollectionPurchaseRecord(
        item: item,
        ownership: ownership,
        transaction: transaction
      )
    )
    let envelope = ProductLoopEventSupport.envelope(
      payload: payload,
      profile: state.runtimeProfile,
      originDeviceID: originDeviceID,
      metadata: metadata,
      observedAt: nil,
      authoredAt: date
    )
    try preflight(envelope, state: state)
    try await store.recordLocal(envelope)
    let updated = try await validatedLedger().replay().state
    return CollectionPurchaseMutationResult(
      cosmeticID: item.id,
      eventID: envelope.eventID,
      didRecordPurchase: existingOwnership == nil,
      balance: updated.coinLedger.balance
    )
  }

  public func equip(
    cosmeticID: CosmeticID,
    operationID: CollectionOperationID,
    at date: Date
  ) async throws -> CollectionEquipMutationResult {
    await acquireOperation()
    defer { releaseOperation() }
    try requireValidInputs(operationID: operationID)
    let ledger = try await validatedLedger()
    let state = ledger.replay().state
    if let existing = operationEnvelope(
      operationID: operationID,
      profile: state.runtimeProfile,
      in: ledger
    ) {
      guard case .collectionTransition(let transition) = existing.payload,
        transition.cosmeticID == cosmeticID
      else {
        throw CollectionMutationRuntimeError.idempotencyKeyReuse
      }
      guard
        state.experienceLedger.contains(where: {
          $0.eventID == existing.eventID
        })
      else {
        throw CollectionMutationRuntimeError.unresolvedMutation
      }
      return CollectionEquipMutationResult(
        cosmeticID: cosmeticID,
        slot: transition.slot,
        eventID: existing.eventID,
        didRecordTransition: false,
        isEquipped:
          state.collection.equipped[transition.slot]?.cosmeticID
          == cosmeticID
      )
    }
    guard
      let ownership = state.collection.ownership.first(where: {
        $0.cosmeticID == cosmeticID
      })
    else {
      throw CollectionMutationRuntimeError.itemNotOwned(cosmeticID)
    }
    let slot = ownership.slot
    let metadata = try metadata(in: ledger)
    let operation = operationID.normalized
    let transition = CollectionTransition(
      header: header(
        CollectionTransitionID(
          stableID(
            prefix: "collection-operation",
            profile: state.runtimeProfile,
            components: [operation]
          )
        ),
        profile: state.runtimeProfile
      ),
      cosmeticID: cosmeticID,
      slot: slot,
      revision: metadata.revision
    )
    let envelope = ProductLoopEventSupport.envelope(
      payload: .collectionTransition(transition),
      profile: state.runtimeProfile,
      originDeviceID: originDeviceID,
      metadata: metadata,
      observedAt: nil,
      authoredAt: date
    )
    try preflight(envelope, state: state)
    try await store.recordLocal(envelope)
    let updated = try await validatedLedger().replay().state
    return CollectionEquipMutationResult(
      cosmeticID: cosmeticID,
      slot: slot,
      eventID: envelope.eventID,
      didRecordTransition: true,
      isEquipped:
        updated.collection.equipped[slot]?.cosmeticID
        == cosmeticID
    )
  }

  private func validatedLedger() async throws -> ProfileLedger {
    let ledger = try await store.currentLedger()
    if let rejection = ledger.replay().state.validate() {
      throw CollectionMutationRuntimeError.invalidProfileState(
        rejection
      )
    }
    return ledger
  }

  private func preflight(
    _ envelope: ExperienceSyncEnvelope,
    state: ProfileState
  ) throws {
    var candidate = state
    if case .rejected(let rejection) = ProfileReducer.apply(
      envelope,
      to: &candidate
    ) {
      throw CollectionMutationRuntimeError.mutationRejected(
        rejection
      )
    }
  }

  private func requireValidInputs(
    operationID: CollectionOperationID
  ) throws {
    guard
      originDeviceID.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty == false
    else {
      throw CollectionMutationRuntimeError.invalidOriginDeviceID
    }
    guard operationID.isValid else {
      throw CollectionMutationRuntimeError.invalidOperationID
    }
  }

  private func metadata(
    in ledger: ProfileLedger
  ) throws -> ProductLoopEventMetadata {
    do {
      return try ProductLoopEventSupport.nextMetadata(
        in: ledger,
        originDeviceID: originDeviceID
      )
    } catch ProductLoopEventSupportError.logicalClockOverflow {
      throw CollectionMutationRuntimeError.logicalClockOverflow
    } catch {
      throw CollectionMutationRuntimeError.invalidOriginDeviceID
    }
  }

  private func stableID(
    prefix: String,
    profile: RuntimeProfile,
    components: [String]
  ) -> String {
    ProductLoopEventSupport.stableID(
      prefix: prefix,
      profile: profile,
      components: components + [originDeviceID]
    )
  }

  private func header<RecordID>(
    _ recordID: RecordID,
    profile: RuntimeProfile
  ) -> ProfileScopedRecordHeader<RecordID>
  where RecordID: Hashable & Codable & Sendable {
    ProfileScopedRecordHeader(
      recordID: recordID,
      profileID: profile.id,
      profileEpoch: profile.epoch,
      deletionEpoch: profile.deletionEpoch
    )
  }

  private func operationEnvelope(
    operationID: CollectionOperationID,
    profile: RuntimeProfile,
    in ledger: ProfileLedger
  ) -> ExperienceSyncEnvelope? {
    let recordID = stableID(
      prefix: "collection-operation",
      profile: profile,
      components: [operationID.normalized]
    )
    return ledger.envelopes.first {
      switch $0.payload {
      case .collectionPurchase(let purchase):
        purchase.ownership.header.recordID.rawValue == recordID
      case .collectionTransition(let transition):
        transition.header.recordID.rawValue == recordID
      default:
        false
      }
    }
  }

  private func acquireOperation() async {
    guard operationIsActive == false else {
      await withCheckedContinuation { continuation in
        operationWaiters.append(continuation)
      }
      return
    }
    operationIsActive = true
  }

  private func releaseOperation() {
    guard operationWaiters.isEmpty == false else {
      operationIsActive = false
      return
    }
    operationWaiters.removeFirst().resume()
  }
}
