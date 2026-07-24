import Foundation

/// Product and engineering limits for passive inference.
///
/// The inference layer consumes summaries from Apple frameworks. It never consumes,
/// serializes, or persists raw accelerometer samples or precise coordinates.
public enum MoriInferenceCapabilityBudgets {
  /// Health summaries are refreshed opportunistically, no more often than this budget.
  public static let healthSummarySamplingInterval: TimeInterval = 15 * 60

  /// A broad motion classification must remain stable before it can be promoted to a fact.
  public static let motionClassificationStabilityWindow: TimeInterval = 30

  /// Repeated foreground activations inside this window collapse into one interaction fact.
  public static let foregroundInteractionDebounce: TimeInterval = 10

  /// Approved place arrivals are category-only and are debounced before inference.
  public static let approvedPlaceCategoryDebounce: TimeInterval = 60

  /// Defensive in-memory bound used by adapter-side normalization.
  public static let maximumRawEvidenceSamplesInMemory = 128

  /// Raw adapter evidence is short-lived even while the process remains alive.
  public static let maximumRawEvidenceAgeInMemory: TimeInterval = 24 * 60 * 60

  /// An event stores only bounded references to normalized facts.
  public static let maximumPersistedEvidenceReferencesPerEvent = 4

  /// Prevents a single evaluation from doing unbounded work after a long pause.
  public static let maximumNormalizedFactsPerEvaluation = 16

  /// A glance is relevant briefly; a later event may replace it.
  public static let glancePresentationLifetime: TimeInterval = 2 * 60

  /// Companion animations are short reactions, not continuous background workloads.
  public static let maximumContinuousAnimationDuration: TimeInterval = 4
  public static let preferredAnimationFrameRate = 30

  public static let persistsRawEvidence = false
  public static let persistsPreciseCoordinates = false
  public static let guaranteesBackgroundContinuity = false
  public static let makesBatteryLifeGuarantee = false
}

public enum MoriBackgroundDeliveryPolicy: String, Sendable {
  /// Delivery depends on foreground use and system-granted execution opportunities.
  case bestEffort
}
