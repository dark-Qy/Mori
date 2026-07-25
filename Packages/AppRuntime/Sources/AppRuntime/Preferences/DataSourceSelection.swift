import Foundation

public enum CompanionDataSource: String, Codable, CaseIterable, Sendable {
  case healthKit
  #if DEBUG
    case mock1
    case mock2
    case mock3
    case mock7Active = "mock7_active"
    case mock7Recovery = "mock7_recovery"
    case mock7Rhythm = "mock7_rhythm"
    case mock7Sparse = "mock7_sparse"
    case mock7Stable = "mock7_stable"
  #endif

  public var displayName: String {
    switch self {
    case .healthKit: "Apple 健康"
    #if DEBUG
      case .mock1: "Mock 1"
      case .mock2: "Mock 2"
      case .mock3: "Mock 3"
      case .mock7Active: "35 日 · 活动旅程"
      case .mock7Recovery: "35 日 · 恢复旅程"
      case .mock7Rhythm: "35 日 · 节律旅程"
      case .mock7Sparse: "35 日 · 片段旅程"
      case .mock7Stable: "35 日 · 平稳旅程"
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
      case .mock7Active: "mock7_active"
      case .mock7Recovery: "mock7_recovery"
      case .mock7Rhythm: "mock7_rhythm"
      case .mock7Sparse: "mock7_sparse"
      case .mock7Stable: "mock7_stable"
    #endif
    }
  }

  public var isMock: Bool {
    self != .healthKit
  }

  public static var defaultSelection: Self {
    #if DEBUG
      .mock1
    #else
      .healthKit
    #endif
  }

  public static func isPeerExchangeFixtureID(_ id: String?) -> Bool {
    #if DEBUG
      id == CompanionDataSource.mock2.fixtureID
    #else
      false
    #endif
  }

  public var simulatesPeerExchange: Bool {
    #if DEBUG
      self == .mock2
    #else
      false
    #endif
  }
}

public actor DataSourceSelectionRepository {
  private let defaults: UserDefaults
  private let key: String
  private let tokenKey: String
  private let mockCareNotificationTokenKey: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = "companion.data-source"
  ) {
    self.defaults = defaults
    self.key = key
    tokenKey = "\(key).selection-token"
    mockCareNotificationTokenKey = "\(key).mock-care-notification-token"
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

  #if DEBUG
    public func mockCareNotificationTokenIfNeeded() -> String? {
      guard
        load() == .mock2,
        let token = loadSelectionToken(),
        token != defaults.string(forKey: mockCareNotificationTokenKey)
      else { return nil }
      return token
    }

    @discardableResult
    public func markMockCareNotificationScheduled(selectionToken: String) -> Bool {
      guard load() == .mock2, loadSelectionToken() == selectionToken else { return false }
      defaults.set(selectionToken, forKey: mockCareNotificationTokenKey)
      return true
    }

    public func lastScheduledMockCareNotificationToken() -> String? {
      defaults.string(forKey: mockCareNotificationTokenKey)
    }
  #endif

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
