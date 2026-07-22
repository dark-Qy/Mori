import Domain
import Foundation
import Growth
import Persistence

/// Serializes durable event appends and derives the current state from the append-only ledger.
/// Replaying instead of mutating a second state store keeps Watch and phone recovery deterministic.
public actor CompanionEventEngine<Storage: EventLedgerStorage> {
  private let repository: EventLedgerRepository<Storage>
  private let reducer: CompanionReducer
  private var cachedState: CompanionState?

  public init(
    storage: Storage,
    reducer: CompanionReducer = CompanionReducer()
  ) {
    repository = EventLedgerRepository(storage: storage)
    self.reducer = reducer
  }

  public func currentState() async throws -> CompanionState {
    if let cachedState { return cachedState }
    let ledger = try await repository.currentLedger()
    let state = try reducer.replay(ledger.events)
    cachedState = state
    return state
  }

  public func currentEvents() async throws -> [EventEnvelope] {
    try await repository.currentLedger().events
  }

  @discardableResult
  public func append(_ event: EventEnvelope) async throws -> CompanionState {
    let ledger = try await repository.append(event)
    let state = try reducer.replay(ledger.events)
    cachedState = state
    return state
  }

  @discardableResult
  public func replace(with events: [EventEnvelope]) async throws -> CompanionState {
    let ledger = try EventLedger(events: events)
    try await repository.replace(with: ledger)
    let state = try reducer.replay(ledger.events)
    cachedState = state
    return state
  }
}
