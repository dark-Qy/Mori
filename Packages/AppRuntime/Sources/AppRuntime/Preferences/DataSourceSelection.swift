import Foundation

public enum CompanionDataSource: String, Codable, CaseIterable, Sendable {
  case healthKit
  #if DEBUG
    case mock1
    case mock2
    case mock3
    case mock4
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
      case .mock4: "Mock 4 · 实时场景"
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
      case .mock4: "mock4"
      case .mock7Active: "mock7_active"
      case .mock7Recovery: "mock7_recovery"
      case .mock7Rhythm: "mock7_rhythm"
      case .mock7Sparse: "mock7_sparse"
      case .mock7Stable: "mock7_stable"
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

public struct PeerDataSourceSelectionPlan: Equatable, Sendable {
  fileprivate let id: UUID
  fileprivate let previousSelection: CompanionDataSource
  fileprivate let previousToken: String?
  fileprivate let selection: CompanionDataSource
  fileprivate let token: String?

  public var changesMode: Bool {
    previousSelection != selection
  }

  public var target: CompanionDataSource {
    selection
  }

  public var leavesProduction: Bool {
    previousSelection == .healthKit && selection != .healthKit
  }
}

public actor DataSourceSelectionRepository {
  private let defaults: UserDefaults
  private let key: String
  private let tokenKey: String
  private let mockCareNotificationTokenKey: String
  private var pendingPeerPlan: PeerDataSourceSelectionPlan?

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
    pendingPeerPlan = nil
    let token = UUID().uuidString
    defaults.set(selection.rawValue, forKey: key)
    defaults.set(token, forKey: tokenKey)
    return token
  }

  public func clearForDeletion() {
    pendingPeerPlan = nil
    defaults.removeObject(forKey: key)
    defaults.removeObject(forKey: tokenKey)
    defaults.removeObject(forKey: mockCareNotificationTokenKey)
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

  /// Previews the exact idempotency rule used by `applyPeerSelection`.
  ///
  /// Callers use this to avoid tearing down production services for replayed
  /// peer snapshots. A new token can still represent an intentional
  /// same-source reselection, such as resetting a Mock scenario.
  public func wouldApplyPeerSelection(
    _ selection: CompanionDataSource,
    token: String?
  ) -> Bool {
    if let token {
      return token != defaults.string(forKey: tokenKey)
    }
    return selection != load()
  }

  /// Reserves one peer action without changing the selected source. A local
  /// save or a newer peer preparation invalidates the reservation, allowing
  /// the runtime to establish its mode-transition fence before commit.
  public func preparePeerSelection(
    _ selection: CompanionDataSource,
    token: String?
  ) -> PeerDataSourceSelectionPlan? {
    guard wouldApplyPeerSelection(selection, token: token) else {
      pendingPeerPlan = nil
      return nil
    }
    let plan = PeerDataSourceSelectionPlan(
      id: UUID(),
      previousSelection: load(),
      previousToken: defaults.string(forKey: tokenKey),
      selection: selection,
      token: token
    )
    pendingPeerPlan = plan
    return plan
  }

  @discardableResult
  public func commitPeerSelection(
    _ plan: PeerDataSourceSelectionPlan
  ) -> Bool {
    guard
      pendingPeerPlan == plan,
      load() == plan.previousSelection,
      defaults.string(forKey: tokenKey) == plan.previousToken
    else {
      return false
    }
    pendingPeerPlan = nil
    defaults.set(plan.selection.rawValue, forKey: key)
    defaults.set(plan.token ?? UUID().uuidString, forKey: tokenKey)
    return true
  }

  /// Returns true when the peer sent a new selection action. A token lets reselecting the same
  /// Mock reset both devices without replaying old peer snapshots as fresh resets.
  @discardableResult
  public func applyPeerSelection(
    _ selection: CompanionDataSource,
    token: String?
  ) -> Bool {
    guard let plan = preparePeerSelection(selection, token: token) else {
      return false
    }
    return commitPeerSelection(plan)
  }
}
