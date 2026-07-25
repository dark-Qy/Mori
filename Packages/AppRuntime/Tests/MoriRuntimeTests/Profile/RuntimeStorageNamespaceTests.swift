import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Profile storage isolation")
struct RuntimeStorageNamespaceTests {
  @Test("Raw profile values never become path components")
  func opaqueNamespacePaths() throws {
    let temporaryRoot = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let layout = try RuntimeStorageLayout(applicationSupportURL: temporaryRoot)
    let profile = realProfile(
      id: "../../private/REAL USER",
      revision: LamportRevision(counter: 7, originDeviceID: "watch/../../")
    )

    let namespace = try layout.namespace(for: profile)

    #expect(namespace.kind == .real)
    #expect(namespace.namespaceID.count == 64)
    #expect(namespace.namespaceID.allSatisfy { $0.isHexDigit })
    #expect(namespace.rootURL.path.contains(profile.id.rawValue) == false)
    #expect(namespace.rootURL.path.contains("watch/../../") == false)
    #expect(
      namespace.rootURL.deletingLastPathComponent().lastPathComponent
        == RuntimeStorageProfileKind.real.rawValue
    )
    #expect(
      namespace.url(for: .profileLedger).path
        != namespace.url(for: .experienceOutbox).path
    )
    #expect(
      namespace.url(for: .cache).path
        != namespace.url(for: .conversation).path
    )
  }

  @Test("Namespace hashing frames profile components that contain delimiters")
  func namespaceHashingHasNoDelimiterCollision() throws {
    let layout = try RuntimeStorageLayout(
      applicationSupportURL: makeTemporaryRoot()
    )
    let first = RuntimeProfile(
      id: ProfileID("x|1"),
      epoch: ProfileEpoch(
        LamportRevision(counter: 2, originDeviceID: "device")
      ),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("test-baseline"),
        revision: LamportRevision(counter: 7, originDeviceID: "phone")
      ),
      source: .real
    )
    let second = RuntimeProfile(
      id: ProfileID("x"),
      epoch: ProfileEpoch(
        LamportRevision(counter: 1, originDeviceID: "2|device")
      ),
      deletionEpoch: DeletionEpoch(
        requestID: DeletionRequestID("test-baseline"),
        revision: LamportRevision(counter: 7, originDeviceID: "phone")
      ),
      source: .real
    )

    #expect(first.isValid)
    #expect(second.isValid)
    #expect(
      try layout.namespace(for: first).namespaceID
        != layout.namespace(for: second).namespaceID
    )
  }

  @Test("Selected Mock reset preserves Real bytes and rejects outside targets")
  func selectedMockResetIsolation() async throws {
    let temporaryRoot = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let layout = try RuntimeStorageLayout(applicationSupportURL: temporaryRoot)

    let real = realProfile(
      id: "real-profile",
      revision: LamportRevision(counter: 1, originDeviceID: "phone")
    )
    let mockSelection = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("rainy-day"),
      revision: LamportRevision(counter: 8, originDeviceID: "watch")
    )
    let realNamespace = try layout.namespace(for: real)
    let mockNamespace = try layout.namespace(for: mockSelection.profile)
    try realNamespace.prepare()
    try mockNamespace.prepare()

    for (index, artifact) in RuntimeStorageArtifact.allCases.enumerated() {
      try Data("real-\(index)-payload".utf8)
        .write(to: realNamespace.url(for: artifact), options: [.atomic])
      try Data("mock-\(index)-payload".utf8)
        .write(to: mockNamespace.url(for: artifact), options: [.atomic])
    }
    let realBefore = try recursiveSnapshot(of: realNamespace.rootURL)
    let authority = try ProfileSelectionAuthority(initial: mockSelection)
    let resetter = SelectedMockResetService(
      layout: layout,
      selectionAuthority: authority
    )

    try await resetter.resetSelectedMock(
      namespace: mockNamespace
    )

    #expect(try recursiveSnapshot(of: realNamespace.rootURL) == realBefore)
    for artifact in RuntimeStorageArtifact.allCases {
      #expect(
        FileManager.default.fileExists(atPath: mockNamespace.url(for: artifact).path) == false)
    }

    let outsideURL = temporaryRoot.appendingPathComponent("outside.keep")
    let outsideBytes = Data("must-not-change".utf8)
    try outsideBytes.write(to: outsideURL, options: [.atomic])
    do {
      try await resetter.removeOwnedItem(
        at: outsideURL,
        namespace: mockNamespace
      )
      Issue.record("Expected outside target to be rejected")
    } catch let error as RuntimeStorageError {
      #expect(error == .targetOutsideOwnedNamespace)
    }
    #expect(try Data(contentsOf: outsideURL) == outsideBytes)
    #expect(try recursiveSnapshot(of: realNamespace.rootURL) == realBefore)

    await #expect(
      throws: RuntimeStorageError.targetOutsideOwnedNamespace
    ) {
      try await resetter.removeOwnedItem(
        at: mockNamespace.rootURL,
        namespace: mockNamespace
      )
    }
    #expect(
      FileManager.default.fileExists(atPath: mockNamespace.rootURL.path)
    )
  }

  @Test("Reset refuses Real and mismatched selected Mock profiles")
  func resetRequiresSelectedMock() async throws {
    let temporaryRoot = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let layout = try RuntimeStorageLayout(applicationSupportURL: temporaryRoot)
    let real = realProfile(
      id: "real",
      revision: LamportRevision(counter: 1, originDeviceID: "phone")
    )
    let realSelection = try ProfileSelectionRecord.real(
      profile: real,
      selectionRevision: LamportRevision(counter: 2, originDeviceID: "phone")
    )
    let realNamespace = try layout.namespace(for: real)
    try realNamespace.prepare()
    let realAuthority = try ProfileSelectionAuthority(initial: realSelection)
    let realResetter = SelectedMockResetService(
      layout: layout,
      selectionAuthority: realAuthority
    )

    do {
      try await realResetter.resetSelectedMock(namespace: realNamespace)
      Issue.record("Expected Real reset to be rejected")
    } catch let error as RuntimeStorageError {
      #expect(error == .realProfileResetForbidden)
    }

    let selectedMock = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("selected"),
      revision: LamportRevision(counter: 3, originDeviceID: "phone")
    )
    let otherMock = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("other"),
      revision: LamportRevision(counter: 4, originDeviceID: "phone")
    )
    let selectedNamespace = try layout.namespace(for: selectedMock.profile)
    try selectedNamespace.prepare()
    let otherAuthority = try ProfileSelectionAuthority(initial: otherMock)
    let mockResetter = SelectedMockResetService(
      layout: layout,
      selectionAuthority: otherAuthority
    )

    do {
      try await mockResetter.resetSelectedMock(namespace: selectedNamespace)
      Issue.record("Expected mismatched selection to be rejected")
    } catch let error as RuntimeStorageError {
      #expect(error == .selectionMismatch)
    }
  }

  @Test("Advancing a Mock generation can remove the old namespace")
  func selectedMockGenerationDeletion() async throws {
    let temporaryRoot = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let layout = try RuntimeStorageLayout(applicationSupportURL: temporaryRoot)
    let selection = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("selected"),
      revision: LamportRevision(counter: 8, originDeviceID: "phone")
    )
    let namespace = try layout.namespace(for: selection.profile)
    try namespace.prepare()
    try Data("private conversation".utf8).write(
      to: namespace.url(for: .conversation),
      options: [.atomic]
    )
    let authority = try ProfileSelectionAuthority(initial: selection)
    let resetter = SelectedMockResetService(
      layout: layout,
      selectionAuthority: authority
    )

    try await resetter.deleteSelectedMockNamespace(namespace: namespace)

    #expect(
      FileManager.default.fileExists(atPath: namespace.rootURL.path) == false
    )
  }

  @Test("Preparing a namespace refuses an existing symlink outside owned storage")
  func prepareRejectsEscapingSymlink() throws {
    let temporaryRoot = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let layout = try RuntimeStorageLayout(applicationSupportURL: temporaryRoot)
    let namespace = try layout.namespace(
      for: realProfile(
        id: "real",
        revision: LamportRevision(counter: 1, originDeviceID: "phone")
      )
    )
    let outside = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(
      at: outside,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: namespace.rootURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: namespace.rootURL,
      withDestinationURL: outside
    )

    #expect(throws: RuntimeStorageError.targetOutsideOwnedNamespace) {
      try namespace.prepare()
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test("Preparing artifacts refuses an escaping child-directory symlink")
  func prepareRejectsEscapingArtifactDirectory() throws {
    let temporaryRoot = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let layout = try RuntimeStorageLayout(applicationSupportURL: temporaryRoot)
    let namespace = try layout.namespace(
      for: realProfile(
        id: "real",
        revision: LamportRevision(counter: 1, originDeviceID: "phone")
      )
    )
    try namespace.prepare()
    let outside = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(
      at: outside,
      withIntermediateDirectories: true
    )
    let ledgerDirectory = namespace.url(for: .profileLedger).deletingLastPathComponent()
    try FileManager.default.removeItem(at: ledgerDirectory)
    try FileManager.default.createSymbolicLink(
      at: ledgerDirectory,
      withDestinationURL: outside
    )

    #expect(throws: RuntimeStorageError.targetOutsideOwnedNamespace) {
      try namespace.prepare()
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test("Global profile deletion removes every namespace but preserves sibling authority")
  func globalProfileDeletionIsBounded() throws {
    let temporaryRoot = makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let layout = try RuntimeStorageLayout(applicationSupportURL: temporaryRoot)
    let real = try layout.namespace(
      for: realProfile(
        id: "real",
        revision: LamportRevision(counter: 1, originDeviceID: "phone")
      )
    )
    let mock = try layout.namespace(
      for: MockProfileDerivation.selection(
        scenarioID: MockScenarioID("mock1"),
        revision: LamportRevision(counter: 2, originDeviceID: "phone")
      ).profile
    )
    try real.prepare()
    try mock.prepare()
    try Data("private-real-chat".utf8).write(
      to: real.url(for: .conversation)
    )
    try Data("private-mock-chat".utf8).write(
      to: mock.url(for: .conversation)
    )
    let authorityURL = temporaryRoot.appendingPathComponent(
      "mori-global-authority-v1.json"
    )
    let authorityBytes = Data("content-free-fence".utf8)
    try authorityBytes.write(to: authorityURL)

    try layout.removeAllOwnedProfileData()

    #expect(!FileManager.default.fileExists(atPath: real.rootURL.path))
    #expect(!FileManager.default.fileExists(atPath: mock.rootURL.path))
    #expect(try Data(contentsOf: authorityURL) == authorityBytes)
    try layout.removeAllOwnedProfileData()
    #expect(try Data(contentsOf: authorityURL) == authorityBytes)
  }
}

private func makeTemporaryRoot() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("MoriRuntimeTests-\(UUID().uuidString)", isDirectory: true)
}

private func realProfile(
  id: String,
  revision: LamportRevision
) -> RuntimeProfile {
  RuntimeProfile(
    id: ProfileID(id),
    epoch: ProfileEpoch(revision),
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("real-baseline"),
      revision: revision
    ),
    source: .real
  )
}

private func recursiveSnapshot(of rootURL: URL) throws -> [String: Data] {
  guard
    let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
  else {
    return [:]
  }
  var result: [String: Data] = [:]
  for case let fileURL as URL in enumerator {
    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else { continue }
    let relative = String(fileURL.path.dropFirst(rootURL.path.count + 1))
    result[relative] = try Data(contentsOf: fileURL)
  }

  // Include the hidden ownership marker as reset isolation covers every byte.
  let markerURL = rootURL.appendingPathComponent(".mori-namespace.json")
  if FileManager.default.fileExists(atPath: markerURL.path) {
    result[".mori-namespace.json"] = try Data(contentsOf: markerURL)
  }
  return result
}
