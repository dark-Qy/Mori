import Foundation

/// Writes a protected app-owned file without any throwable work after the new
/// bytes become authoritative. Metadata is applied to a sibling temporary file
/// first; the final move/replace is the commit point.
enum ProtectedAtomicFile {
  static func write(
    _ data: Data,
    to fileURL: URL
  ) throws {
    let fileManager = FileManager.default
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let temporaryURL = directory.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
    )
    defer {
      try? fileManager.removeItem(at: temporaryURL)
    }

    try data.write(to: temporaryURL, options: [.atomic])
    var protectedURL = temporaryURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try protectedURL.setResourceValues(values)

    #if os(iOS) || os(watchOS) || os(tvOS)
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: temporaryURL.path
      )
    #endif

    if fileManager.fileExists(atPath: fileURL.path) {
      _ = try fileManager.replaceItemAt(
        fileURL,
        withItemAt: temporaryURL
      )
    } else {
      try fileManager.moveItem(
        at: temporaryURL,
        to: fileURL
      )
    }
  }

  /// Removes only staging files created by this writer for the exact artifact.
  /// The UUID-shaped middle component prevents a broad prefix from deleting
  /// unrelated hidden files in the same app-owned directory.
  static func removeOrphanedStagingFiles(
    for fileURL: URL,
    fileManager: FileManager = FileManager.default
  ) throws {
    let directory = fileURL.deletingLastPathComponent()
    guard fileManager.fileExists(atPath: directory.path) else { return }
    let prefix = ".\(fileURL.lastPathComponent)."
    let suffix = ".tmp"
    for candidate in try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants]
    ) {
      let name = candidate.lastPathComponent
      guard
        name.hasPrefix(prefix),
        name.hasSuffix(suffix),
        name.count > prefix.count + suffix.count
      else {
        continue
      }
      let identifier = String(
        name.dropFirst(prefix.count).dropLast(suffix.count)
      )
      guard UUID(uuidString: identifier) != nil else { continue }
      try fileManager.removeItem(at: candidate)
    }
  }
}
