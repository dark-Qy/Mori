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
}
