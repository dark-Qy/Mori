import Foundation

public enum CompanionDataSource: String, Codable, CaseIterable, Sendable {
  case healthKit
  #if DEBUG
    case mock1
    case mock2
    case mock3
  #endif

  public var displayName: String {
    switch self {
    case .healthKit: "Apple 健康"
    #if DEBUG
      case .mock1: "Mock 1"
      case .mock2: "Mock 2"
      case .mock3: "Mock 3"
    #endif
    }
  }

  public var fixtureID: String? {
    switch self {
    case .healthKit: nil
    #if DEBUG
      case .mock1: "mock1"
      case .mock2: "mock2"
      case .mock3: "mock3"
    #endif
    }
  }

  public var isMock: Bool {
    #if DEBUG
      self != .healthKit
    #else
      false
    #endif
  }

  public static var defaultSelection: Self {
    #if DEBUG
      .mock1
    #else
      .healthKit
    #endif
  }
}

public actor DataSourceSelectionRepository {
  private let defaults: UserDefaults
  private let key: String
  private let tokenKey: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = "companion.data-source"
  ) {
    self.defaults = defaults
    self.key = key
    tokenKey = "\(key).selection-token"
  }

  public func load() -> CompanionDataSource {
    guard
      let storedValue = defaults.string(forKey: key),
      let selection = CompanionDataSource(rawValue: storedValue)
    else {
      return .defaultSelection
    }
    return selection
  }

  @discardableResult
  public func save(_ selection: CompanionDataSource) -> String {
    let token = UUID().uuidString
    defaults.set(selection.rawValue, forKey: key)
    defaults.set(token, forKey: tokenKey)
    return token
  }

  public func loadSelectionToken() -> String? {
    defaults.string(forKey: tokenKey)
  }

  /// Returns true when the peer sent a new selection action. A token lets reselecting the same
  /// Mock reset both devices without replaying old peer snapshots as fresh resets.
  @discardableResult
  public func applyPeerSelection(
    _ selection: CompanionDataSource,
    token: String?
  ) -> Bool {
    if let token {
      guard token != defaults.string(forKey: tokenKey) else { return false }
      defaults.set(selection.rawValue, forKey: key)
      defaults.set(token, forKey: tokenKey)
      return true
    }

    guard selection != load() else { return false }
    _ = save(selection)
    return true
  }
}
