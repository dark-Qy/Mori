import CryptoKit
import Foundation
import MoriDomain
import MoriPersistence

public enum RuntimeStorageArtifact: String, CaseIterable, Codable, Sendable {
  case profileLedger
  case experienceOutbox
  case cache
  case conversation

  fileprivate var relativePath: String {
    switch self {
    case .profileLedger:
      "ledger/profile-ledger.json"
    case .experienceOutbox:
      "outbox/experience-outbox.json"
    case .cache:
      "cache/runtime-cache.json"
    case .conversation:
      "conversation/conversation.json"
    }
  }
}

public enum RuntimeStorageProfileKind: String, Codable, Sendable {
  case real
  case mock
}

public enum RuntimeStorageError: Error, Equatable, Sendable {
  case nonFileStorageRoot
  case invalidProfile
  case namespaceDoesNotBelongToLayout
  case namespaceNotPrepared
  case namespaceMarkerMismatch
  case realProfileResetForbidden
  case selectionMismatch
  case targetOutsideOwnedNamespace
}

/// Defines the app-private directory in which Mori owns profile data.
///
/// Profile and scenario identifiers are input to SHA-256 and are never used as
/// path components. Real and Mock data also have distinct parent directories,
/// so a Mock reset never relies on two opaque hashes being different.
public struct RuntimeStorageLayout: Sendable {
  public let applicationSupportURL: URL
  public let ownedProfilesURL: URL

  public init(applicationSupportURL: URL) throws {
    guard applicationSupportURL.isFileURL else {
      throw RuntimeStorageError.nonFileStorageRoot
    }
    let supportURL = applicationSupportURL.standardizedFileURL
    self.applicationSupportURL = supportURL
    ownedProfilesURL =
      supportURL
      .appendingPathComponent("mori-runtime-v1", isDirectory: true)
      .appendingPathComponent("profiles", isDirectory: true)
  }

  public func namespace(for profile: RuntimeProfile) throws -> RuntimeStorageNamespace {
    guard profile.isValid else { throw RuntimeStorageError.invalidProfile }
    let kind: RuntimeStorageProfileKind = profile.isMock ? .mock : .real
    let namespaceID = Self.namespaceID(for: profile)
    let namespaceURL =
      ownedProfilesURL
      .appendingPathComponent(kind.rawValue, isDirectory: true)
      .appendingPathComponent(namespaceID, isDirectory: true)

    return RuntimeStorageNamespace(
      profile: profile,
      kind: kind,
      namespaceID: namespaceID,
      ownedProfilesURL: ownedProfilesURL,
      rootURL: namespaceURL
    )
  }

  fileprivate func owns(_ namespace: RuntimeStorageNamespace) -> Bool {
    namespace.ownedProfilesURL.standardizedFileURL == ownedProfilesURL.standardizedFileURL
      && Self.isWithin(namespace.rootURL, parent: ownedProfilesURL)
  }

  private static func namespaceID(for profile: RuntimeProfile) -> String {
    let sourceComponents: [String]
    switch profile.source {
    case .real:
      sourceComponents = ["real"]
    case .mock(let scenarioID, let selectionEpoch):
      sourceComponents = [
        "mock",
        scenarioID.rawValue,
        String(selectionEpoch.revision.counter),
        selectionEpoch.revision.originDeviceID,
      ]
    }
    let input = CanonicalHashInput.data(
      [
        "mori-profile-namespace-v1",
        profile.id.rawValue,
        String(profile.epoch.revision.counter),
        profile.epoch.revision.originDeviceID,
        profile.deletionEpoch.requestID.rawValue,
        String(profile.deletionEpoch.revision.counter),
        profile.deletionEpoch.revision.originDeviceID,
      ] + sourceComponents
    )
    return SHA256.hash(data: input)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  fileprivate static func isWithin(_ candidate: URL, parent: URL) -> Bool {
    let parentURL = resolvingExistingAncestors(of: parent)
    let candidateURL = resolvingExistingAncestors(of: candidate)
    let parentComponents = parentURL.pathComponents
    let candidateComponents = candidateURL.pathComponents
    guard candidateComponents.count >= parentComponents.count else { return false }
    return Array(candidateComponents.prefix(parentComponents.count)) == parentComponents
  }

  /// `URL.resolvingSymlinksInPath()` does not reliably resolve an intermediate
  /// symlink when the final file does not exist. Resolve the nearest existing
  /// ancestor first, then reconstruct the missing suffix.
  private static func resolvingExistingAncestors(of url: URL) -> URL {
    var existing = url.standardizedFileURL
    var missingComponents: [String] = []
    while FileManager.default.fileExists(atPath: existing.path) == false,
      existing.pathComponents.count > 1
    {
      missingComponents.append(existing.lastPathComponent)
      existing.deleteLastPathComponent()
    }
    var resolved = existing.resolvingSymlinksInPath()
    for component in missingComponents.reversed() {
      resolved.appendPathComponent(component)
    }
    return resolved.standardizedFileURL
  }
}

public struct RuntimeStorageNamespace: Sendable {
  public let profile: RuntimeProfile
  public let kind: RuntimeStorageProfileKind
  public let namespaceID: String
  public let rootURL: URL

  fileprivate let ownedProfilesURL: URL

  fileprivate init(
    profile: RuntimeProfile,
    kind: RuntimeStorageProfileKind,
    namespaceID: String,
    ownedProfilesURL: URL,
    rootURL: URL
  ) {
    self.profile = profile
    self.kind = kind
    self.namespaceID = namespaceID
    self.ownedProfilesURL = ownedProfilesURL
    self.rootURL = rootURL
  }

  public func url(for artifact: RuntimeStorageArtifact) -> URL {
    rootURL.appendingPathComponent(artifact.relativePath, isDirectory: false)
  }

  public func profileLedgerStorage() -> FileProfileLedgerStorage {
    FileProfileLedgerStorage(fileURL: url(for: .profileLedger))
  }

  /// Creates this namespace and its ownership marker. Existing namespaces are
  /// accepted only when their marker exactly matches this derived namespace.
  public func prepare(fileManager: FileManager = FileManager()) throws {
    guard RuntimeStorageLayout.isWithin(rootURL, parent: ownedProfilesURL) else {
      throw RuntimeStorageError.targetOutsideOwnedNamespace
    }
    if fileManager.fileExists(atPath: rootURL.path) {
      try verifyOwnershipMarker(fileManager: fileManager)
    } else {
      try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
      try writeOwnershipMarker()
    }

    for artifact in RuntimeStorageArtifact.allCases {
      try assertOwns(url(for: artifact))
      try fileManager.createDirectory(
        at: url(for: artifact).deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }
  }

  /// Validates both lexical and symlink-resolved containment.
  public func assertOwns(_ targetURL: URL) throws {
    guard
      RuntimeStorageLayout.isWithin(targetURL, parent: rootURL),
      RuntimeStorageLayout.isWithin(rootURL, parent: ownedProfilesURL)
    else {
      throw RuntimeStorageError.targetOutsideOwnedNamespace
    }
  }

  fileprivate func verifyOwnershipMarker(
    fileManager: FileManager = FileManager()
  ) throws {
    let markerURL = rootURL.appendingPathComponent(".mori-namespace.json")
    guard fileManager.fileExists(atPath: markerURL.path) else {
      throw RuntimeStorageError.namespaceNotPrepared
    }

    let marker: RuntimeStorageMarker
    do {
      marker = try JSONDecoder().decode(
        RuntimeStorageMarker.self,
        from: Data(contentsOf: markerURL)
      )
    } catch {
      throw RuntimeStorageError.namespaceMarkerMismatch
    }
    guard
      marker.schemaVersion == RuntimeStorageMarker.currentSchemaVersion,
      marker.namespaceID == namespaceID,
      marker.kind == kind
    else {
      throw RuntimeStorageError.namespaceMarkerMismatch
    }
  }

  fileprivate func writeOwnershipMarker() throws {
    let marker = RuntimeStorageMarker(namespaceID: namespaceID, kind: kind)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(marker)
    try data.write(
      to: rootURL.appendingPathComponent(".mori-namespace.json"),
      options: [.atomic]
    )
  }
}

/// Deletes only the currently selected Mock namespace. A matching ownership
/// marker is required before any filesystem mutation.
public actor SelectedMockResetService {
  private let layout: RuntimeStorageLayout
  private let selectionAuthority: ProfileSelectionAuthority
  private let fileManager: FileManager

  public init(
    layout: RuntimeStorageLayout,
    selectionAuthority: ProfileSelectionAuthority,
    fileManager: FileManager = FileManager()
  ) {
    self.layout = layout
    self.selectionAuthority = selectionAuthority
    self.fileManager = fileManager
  }

  public func resetSelectedMock(
    namespace: RuntimeStorageNamespace
  ) async throws {
    try await validateSelectedMock(namespace: namespace)
    try namespace.verifyOwnershipMarker(fileManager: fileManager)
    try namespace.assertOwns(namespace.rootURL)
    try fileManager.removeItem(at: namespace.rootURL)
    try namespace.prepare(fileManager: fileManager)
  }

  /// A guarded primitive for deleting an individual owned Mock artifact. It is
  /// intentionally unavailable for Real profiles.
  public func removeOwnedItem(
    at targetURL: URL,
    namespace: RuntimeStorageNamespace
  ) async throws {
    try await validateSelectedMock(namespace: namespace)
    try namespace.verifyOwnershipMarker(fileManager: fileManager)
    try namespace.assertOwns(targetURL)
    guard
      targetURL.standardizedFileURL != namespace.rootURL.standardizedFileURL
    else {
      throw RuntimeStorageError.targetOutsideOwnedNamespace
    }
    guard fileManager.fileExists(atPath: targetURL.path) else { return }
    try fileManager.removeItem(at: targetURL)
  }

  private func validateSelectedMock(
    namespace: RuntimeStorageNamespace
  ) async throws {
    guard layout.owns(namespace) else {
      throw RuntimeStorageError.namespaceDoesNotBelongToLayout
    }
    guard let selection = await selectionAuthority.current() else {
      throw RuntimeStorageError.selectionMismatch
    }
    guard selection.profile.isMock, namespace.kind == .mock else {
      throw RuntimeStorageError.realProfileResetForbidden
    }
    guard selection.isValid, selection.profile == namespace.profile else {
      throw RuntimeStorageError.selectionMismatch
    }
  }
}

private struct RuntimeStorageMarker: Codable, Sendable {
  static let currentSchemaVersion: UInt16 = 1

  let schemaVersion: UInt16
  let namespaceID: String
  let kind: RuntimeStorageProfileKind

  init(
    schemaVersion: UInt16 = Self.currentSchemaVersion,
    namespaceID: String,
    kind: RuntimeStorageProfileKind
  ) {
    self.schemaVersion = schemaVersion
    self.namespaceID = namespaceID
    self.kind = kind
  }
}
