import Foundation

/// A closed, coarse category that the user has explicitly approved for local place
/// recognition. It cannot carry a free-form address, coordinate, or place name.
public enum ApprovedPlaceCategory: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case home
  case work
  case park
  case transit
  case other
}

/// A coordinate used only to configure a device-local approved region. This type
/// intentionally has no `Codable` conformance, and no adapter event contains it.
public struct DeviceLocalCoordinate: Equatable, Sendable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }

  fileprivate var isValid: Bool {
    latitude.isFinite
      && longitude.isFinite
      && (-90...90).contains(latitude)
      && (-180...180).contains(longitude)
  }
}

/// Input-only configuration for a region the user has approved. Coordinates and
/// radii remain inside the live adapter and are never included in emitted events.
public struct DeviceLocalApprovedRegion: Equatable, Sendable {
  public let category: ApprovedPlaceCategory
  public let center: DeviceLocalCoordinate
  public let radiusMeters: Double

  public init(
    category: ApprovedPlaceCategory,
    center: DeviceLocalCoordinate,
    radiusMeters: Double
  ) {
    self.category = category
    self.center = center
    self.radiusMeters = radiusMeters
  }

  fileprivate var isValid: Bool {
    center.isValid && radiusMeters.isFinite && radiusMeters > 0
  }
}

public enum ApprovedPlacePresence: String, Codable, Equatable, Sendable {
  case entered
  case exited
}

/// The privacy-minimized output of place recognition. It contains only an approved
/// category, a presence transition, and the observation time.
public struct ApprovedPlaceObservation: Codable, Equatable, Sendable {
  public let category: ApprovedPlaceCategory
  public let presence: ApprovedPlacePresence
  public let observedAt: Date

  public init(
    category: ApprovedPlaceCategory,
    presence: ApprovedPlacePresence,
    observedAt: Date
  ) {
    self.category = category
    self.presence = presence
    self.observedAt = observedAt
  }
}

public enum ApprovedPlaceMonitoringAvailability: Equatable, Sendable {
  case available
  case unavailable(reason: String)
}

public enum ApprovedPlacePermissionState: Equatable, Sendable {
  case notDetermined
  case authorizedWhenInUse
  case authorizedAlways
  case denied
  case restricted
  case unavailable(reason: String)
}

public enum ApprovedPlacePermissionRequest: Equatable, Sendable {
  case whenInUse
  case always
}

public enum ApprovedPlaceMonitoringFailure: Equatable, Sendable {
  case unavailable(String)
  case permissionNotDetermined
  case permissionDenied
  case permissionRestricted
  case invalidRegion
  case tooManyRegions(maximum: Int)
  case systemFailure
}

public enum ApprovedPlaceMonitoringEvent: Equatable, Sendable {
  case observation(ApprovedPlaceObservation)
  case permissionChanged(ApprovedPlacePermissionState)
  case stopped
  case failed(ApprovedPlaceMonitoringFailure)
}

public protocol ApprovedPlaceMonitoringClient: Sendable {
  func availability() async -> ApprovedPlaceMonitoringAvailability
  func permissionState() async -> ApprovedPlacePermissionState
  func requestPermission(_ request: ApprovedPlacePermissionRequest) async
  func events() -> AsyncStream<ApprovedPlaceMonitoringEvent>
  func startMonitoring(_ regions: [DeviceLocalApprovedRegion]) async throws
  func stop() async
}

public enum ApprovedPlaceAdapterError: Error, Equatable, Sendable {
  case unavailable(String)
  case permissionNotDetermined
  case permissionDenied
  case permissionRestricted
  case invalidRegion
  case tooManyRegions(maximum: Int)
}

extension DeviceLocalApprovedRegion {
  static func validate(_ regions: [Self], maximum: Int) throws {
    guard regions.count <= maximum else {
      throw ApprovedPlaceAdapterError.tooManyRegions(maximum: maximum)
    }
    guard regions.allSatisfy(\.isValid) else {
      throw ApprovedPlaceAdapterError.invalidRegion
    }
  }
}
