import Foundation
import MoriDomain

public struct LegacyResetSourceSnapshot: Equatable, Sendable {
  public let progressionData: Data?
  public let preferencesData: Data?

  public init(progressionData: Data?, preferencesData: Data?) {
    self.progressionData = progressionData
    self.preferencesData = preferencesData
  }
}

public protocol LegacyResetSourceStorage: Sendable {
  func loadSnapshot() async throws -> LegacyResetSourceSnapshot
  func purgeLegacyStores() async throws
}

public protocol LegacyResetBundleStorage: Sendable {
  func load() async throws -> Data?
  func save(_ data: Data) async throws
}

public struct LegacyResetBundle: Codable, Equatable, Sendable {
  public static let currentSchemaVersion: UInt16 = 1

  public let schemaVersion: UInt16
  public let marker: LegacyResetMarker
  public let preservedPreferences: LegacyPreservedPreferences
  public let profileLedger: ProfileLedger

  public init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    marker: LegacyResetMarker,
    preservedPreferences: LegacyPreservedPreferences,
    profileLedger: ProfileLedger
  ) {
    self.schemaVersion = schemaVersion
    self.marker = marker
    self.preservedPreferences = preservedPreferences
    self.profileLedger = profileLedger
  }
}

public enum LegacyResetCoordinatorError: Error, Equatable, Sendable {
  case unsupportedBundleSchema(UInt16)
  case bundleScopeMismatch
  case bundleProfileMismatch
}

public enum LegacyResetExecutionResult: Equatable, Sendable {
  case applied(LegacyResetBundle)
  case alreadyApplied(LegacyResetBundle)
  case blocked(LegacyResetBlockReason)
}

/// Writes the empty Mori ledger, reset marker, and preserved allowlist as one
/// atomic destination bundle. Legacy files are purged only after that write
/// succeeds. Relaunch also finishes a purge interrupted after the bundle write.
public actor LegacyResetCoordinator<
  Source: LegacyResetSourceStorage,
  Destination: LegacyResetBundleStorage
> {
  private let source: Source
  private let destination: Destination
  private let reset: LegacyDevelopmentReset
  private let codec: CanonicalJSONCodec

  public init(
    source: Source,
    destination: Destination,
    reset: LegacyDevelopmentReset = LegacyDevelopmentReset(),
    codec: CanonicalJSONCodec = CanonicalJSONCodec()
  ) {
    self.source = source
    self.destination = destination
    self.reset = reset
    self.codec = codec
  }

  public func run(
    scope: LegacyStoreScope,
    initialState: ProfileState
  ) async throws -> LegacyResetExecutionResult {
    guard Self.scopeKindMatchesProfileSource(scope.kind, initialState.runtimeProfile.source) else {
      throw LegacyResetCoordinatorError.bundleProfileMismatch
    }
    let sourceSnapshot = try await source.loadSnapshot()
    let existingBundle = try await loadBundleIfPresent(
      scope: scope,
      initialState: initialState
    )
    let markerData = try existingBundle.map { try reset.encodeMarker($0.marker) }
    let plan = reset.plan(
      scope: scope,
      progressionData: sourceSnapshot.progressionData,
      preferencesData: sourceSnapshot.preferencesData,
      markerData: markerData
    )

    switch plan {
    case .alreadyApplied:
      guard let existingBundle else {
        throw LegacyResetCoordinatorError.bundleScopeMismatch
      }
      try await source.purgeLegacyStores()
      return .alreadyApplied(existingBundle)

    case .blocked(let reason):
      return .blocked(reason)

    case .apply(let marker, let preservedPreferences, _):
      let ledger = try ProfileLedger(initialState: initialState)
      let bundle = LegacyResetBundle(
        marker: marker,
        preservedPreferences: preservedPreferences,
        profileLedger: ledger
      )
      try await destination.save(codec.encode(bundle))
      try await source.purgeLegacyStores()
      return .applied(bundle)
    }
  }

  private func loadBundleIfPresent(
    scope: LegacyStoreScope,
    initialState: ProfileState
  ) async throws -> LegacyResetBundle? {
    guard let data = try await destination.load() else { return nil }
    let bundle = try codec.decode(LegacyResetBundle.self, from: data)
    guard bundle.schemaVersion == LegacyResetBundle.currentSchemaVersion else {
      throw LegacyResetCoordinatorError.unsupportedBundleSchema(bundle.schemaVersion)
    }
    guard bundle.marker.scope == scope else {
      throw LegacyResetCoordinatorError.bundleScopeMismatch
    }
    guard
      bundle.profileLedger.initialState.runtimeProfile
        == initialState.runtimeProfile
    else {
      throw LegacyResetCoordinatorError.bundleProfileMismatch
    }
    return bundle
  }

  private static func scopeKindMatchesProfileSource(
    _ kind: LegacyStoreKind,
    _ source: RuntimeProfileSource
  ) -> Bool {
    switch (kind, source) {
    case (.real, .real), (.mock, .mock(_, _)):
      return true
    default:
      return false
    }
  }
}

public actor InMemoryLegacyResetSourceStorage: LegacyResetSourceStorage {
  private var snapshot: LegacyResetSourceSnapshot
  public private(set) var purgeCount = 0

  public init(snapshot: LegacyResetSourceSnapshot) {
    self.snapshot = snapshot
  }

  public func loadSnapshot() -> LegacyResetSourceSnapshot {
    snapshot
  }

  public func purgeLegacyStores() {
    snapshot = LegacyResetSourceSnapshot(progressionData: nil, preferencesData: nil)
    purgeCount += 1
  }
}

public actor InMemoryLegacyResetBundleStorage: LegacyResetBundleStorage {
  private var data: Data?

  public init(data: Data? = nil) {
    self.data = data
  }

  public func load() -> Data? {
    data
  }

  public func save(_ data: Data) {
    self.data = data
  }
}

public actor FileLegacyResetBundleStorage: LegacyResetBundleStorage {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL)
  }

  public func save(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: [.atomic])

    var protectedURL = fileURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try protectedURL.setResourceValues(values)

    #if os(iOS) || os(watchOS) || os(tvOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path
      )
    #endif
  }
}
