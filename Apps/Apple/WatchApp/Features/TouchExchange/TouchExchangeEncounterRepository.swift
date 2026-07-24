import AppRuntime
import Foundation

/// A small, idempotent local store for completed touch encounters.
///
/// The rendezvous transport remains ephemeral. Only the completed, game-only
/// encounter is retained, and repeat delivery of an encounter ID is ignored.
@MainActor
final class TouchExchangeEncounterRepository {
  private static let storageKey = "social.completed-encounters.v1"
  private static let consumedTransferEventsKey =
    "social.consumed-transfer-events.v1"
  private static let maximumStoredEncounters = 100
  private static let maximumConsumedTransferEvents = 100

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  @discardableResult
  func save(_ encounter: Encounter) -> Bool {
    var encounters = load()
    if encounters.contains(where: { $0.id == encounter.id }) {
      return true
    }
    encounters.append(encounter)
    if encounters.count > Self.maximumStoredEncounters {
      encounters.removeFirst(encounters.count - Self.maximumStoredEncounters)
    }
    guard let data = try? JSONEncoder().encode(encounters) else {
      return false
    }
    defaults.set(data, forKey: Self.storageKey)
    return true
  }

  func contains(encounterID: String) -> Bool {
    load().contains(where: { $0.id == encounterID })
  }

  /// Returns `true` exactly once for a presentation event on this installation.
  ///
  /// The animation is presentation-only, so this list is deliberately stored
  /// separately from completed encounter history.
  @discardableResult
  func consumeTransferEvent(id: String) -> Bool {
    var eventIDs =
      defaults.stringArray(
        forKey: Self.consumedTransferEventsKey
      ) ?? []
    guard !eventIDs.contains(id) else { return false }
    eventIDs.append(id)
    if eventIDs.count > Self.maximumConsumedTransferEvents {
      eventIDs.removeFirst(
        eventIDs.count - Self.maximumConsumedTransferEvents
      )
    }
    defaults.set(eventIDs, forKey: Self.consumedTransferEventsKey)
    return true
  }

  #if DEBUG
    func resetConsumedTransferEventsForTesting() {
      defaults.removeObject(forKey: Self.consumedTransferEventsKey)
    }
  #endif

  private func load() -> [Encounter] {
    guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
    return (try? JSONDecoder().decode([Encounter].self, from: data)) ?? []
  }
}
