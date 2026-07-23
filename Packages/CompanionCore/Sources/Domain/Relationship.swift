import Foundation

public enum RelationshipPresence: String, Codable, Equatable, Sendable {
  case present
  case quietlyMissingYou
}

extension PetState {
  /// Three complete local calendar days must pass after the last meaningful interaction. A pet
  /// with no interaction history stays neutral so a new person is never greeted with guilt.
  public func relationshipPresence(
    at now: Date,
    timeZone: TimeZone
  ) -> RelationshipPresence {
    guard let lastInteractionAt else { return .present }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let lastDay = calendar.startOfDay(for: lastInteractionAt)
    let currentDay = calendar.startOfDay(for: now)
    guard
      let firstMissingDay = calendar.date(byAdding: .day, value: 4, to: lastDay),
      currentDay >= firstMissingDay
    else { return .present }
    return .quietlyMissingYou
  }
}
