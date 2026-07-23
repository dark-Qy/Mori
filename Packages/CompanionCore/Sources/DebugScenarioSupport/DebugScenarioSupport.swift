#if DEBUG
  import Domain
  import Foundation
  import MockKit

  public enum DebugScenarioPrimaryState: String, Equatable, Sendable {
    case onboarding
    case petIntroduction
    case petHome
    case wardrobe
  }

  public enum DebugNarrationState: Equatable, Sendable {
    case providerAvailable
    case localFallback
  }

  /// A presentation-safe projection of an executable repository fixture.
  ///
  /// JSON and MockKit implementation details stop at this boundary. Both Apple clients receive the
  /// state produced by the real reducer plus the minimum non-authoritative fixture metadata needed
  /// to render deterministic failure and capability states.
  public struct DebugScenarioSeed: Sendable {
    public let id: String
    public let displayName: String
    public let now: Date
    public let timeZoneIdentifier: String
    public let hasCompletedOnboarding: Bool
    public let primaryState: DebugScenarioPrimaryState
    public let companionState: CompanionState
    public let healthSnapshot: HealthSnapshot
    public let petLevel: Int
    public let selectedOutfitID: String?
    public let unlockedOutfitIDs: Set<String>
    public let previewOutfitID: String?
    public let narrationState: DebugNarrationState
    public let syncAvailable: Bool
    public let eligibleRandomStoryID: String?

    fileprivate init(runtime: MockScenarioRuntime, run: MockScenarioRun) {
      id = runtime.id
      displayName = runtime.displayName
      now = runtime.clock.now
      timeZoneIdentifier = runtime.clock.timeZoneIdentifier
      hasCompletedOnboarding = runtime.hasCompletedOnboarding
      primaryState = DebugScenarioPrimaryState(rawValue: runtime.primaryState.rawValue) ?? .petHome
      companionState = run.state
      healthSnapshot = runtime.healthSnapshot
      petLevel = runtime.petLevel
      selectedOutfitID = runtime.wardrobe.selectedOutfitID
      unlockedOutfitIDs = runtime.wardrobe.unlockedOutfitIDs
      previewOutfitID = runtime.wardrobe.previewOutfitID
      narrationState =
        runtime.aiState == .available || runtime.aiState == .reachable
        ? .providerAvailable : .localFallback
      syncAvailable = runtime.syncState == .available || runtime.syncState == .reachable
      eligibleRandomStoryID = runtime.eligibleRandomStoryID
    }
  }

  public enum DebugScenarioSelection: Sendable {
    case none
    case scenario(DebugScenarioSeed)
    case invalid(requestedID: String)
  }

  public enum DebugScenarioCatalog {
    /// Only reviewed, synthetic repository fixtures may be selected. The identifier is checked
    /// before a data provider is called, so launch arguments can never become arbitrary file paths.
    public static let allowlistedIDs: Set<String> = [
      "activity_high",
      "ai_malformed",
      "ai_offline",
      "fresh_install",
      "health_no_data",
      "health_normal",
      "health_partial",
      "mock1",
      "mock2",
      "mock3",
      "notification_denied",
      "outfit_locked",
      "outfit_unlocked",
      "permission_not_requested",
      "pet_new",
      "sleep_stale",
      "soccer_workout",
      "sync_unreachable",
    ]

    public static func selection(
      from arguments: [String],
      enabled: Bool,
      dataForScenario: (String) -> Data?
    ) -> DebugScenarioSelection {
      guard enabled else { return .none }
      guard case .scenario(let requestedID) = MockLaunchArguments.selection(from: arguments) else {
        return .none
      }
      guard allowlistedIDs.contains(requestedID) else {
        return .invalid(requestedID: requestedID)
      }
      guard let data = dataForScenario(requestedID) else {
        return .invalid(requestedID: requestedID)
      }

      do {
        let fixture = try ScenarioFixture(data: data)
        guard fixture.validationIssues(fileStem: requestedID).isEmpty else {
          return .invalid(requestedID: requestedID)
        }
        let runtime = try MockScenarioRuntime(fixture: fixture)
        let run = try MockScenarioRun(runtime: runtime)
        return .scenario(DebugScenarioSeed(runtime: runtime, run: run))
      } catch {
        return .invalid(requestedID: requestedID)
      }
    }
  }
#endif
