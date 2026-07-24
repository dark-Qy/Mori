import Foundation

enum WeeklyMemoryCopySource: String, Codable, Equatable {
  case mock
}

struct WeeklyMemoryMetric: Codable, Equatable, Identifiable {
  let id: String
  let label: String
  let value: String
  let accessibilityValue: String
  let symbol: String
}

struct WeeklyMemoryHighlight: Codable, Equatable {
  let title: String
  let symbol: String
  let durationMinutes: Int?
}

struct ArchivedWeeklyMemory: Codable, Equatable, Identifiable {
  var id: String { weekID }

  let weekID: String
  let sourceHash: String
  let weekOrdinal: Int
  let weekLabel: String
  let dateLabel: String
  var title: String
  var body: String
  let metrics: [WeeklyMemoryMetric]
  let highlight: WeeklyMemoryHighlight
  let bundledCoverAssetName: String
  var source: WeeklyMemoryCopySource
  var isFavorite: Bool
  var isHidden: Bool
  let createdAt: Date
  var accessibilityDescription: String
}

struct PhoneWeeklyMemory: Equatable, Identifiable {
  var id: String { record.id }
  var record: ArchivedWeeklyMemory
}

actor WeeklyMemoryArchiveStore {
  private let indexURL: URL?
  private var cachedRecords: [ArchivedWeeklyMemory]?

  init(storageDirectory: URL?) {
    indexURL = storageDirectory?.appendingPathComponent("weekly-memories-v2.json")
  }

  func load() throws -> [PhoneWeeklyMemory] {
    try loadRecords()
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.weekID > rhs.weekID
      }
      .map(PhoneWeeklyMemory.init(record:))
  }

  @discardableResult
  func upsert(_ incoming: ArchivedWeeklyMemory) throws -> PhoneWeeklyMemory {
    var records = try loadRecords()
    var record = incoming
    if let existing = records.first(where: { $0.weekID == incoming.weekID }) {
      record.isFavorite = existing.isFavorite
      record.isHidden = existing.isHidden
    }
    records.removeAll { $0.weekID == record.weekID }
    records.append(record)
    try saveRecords(records)
    return PhoneWeeklyMemory(record: record)
  }

  @discardableResult
  func setFavorite(_ value: Bool, weekID: String) throws -> [PhoneWeeklyMemory] {
    var records = try loadRecords()
    guard let index = records.firstIndex(where: { $0.weekID == weekID }) else {
      return try load()
    }
    records[index].isFavorite = value
    try saveRecords(records)
    return try load()
  }

  @discardableResult
  func setHidden(_ value: Bool, weekID: String) throws -> [PhoneWeeklyMemory] {
    var records = try loadRecords()
    guard let index = records.firstIndex(where: { $0.weekID == weekID }) else {
      return try load()
    }
    records[index].isHidden = value
    try saveRecords(records)
    return try load()
  }

  @discardableResult
  func delete(weekID: String) throws -> [PhoneWeeklyMemory] {
    var records = try loadRecords()
    records.removeAll { $0.weekID == weekID }
    try saveRecords(records)
    return try load()
  }

  private func loadRecords() throws -> [ArchivedWeeklyMemory] {
    if let cachedRecords { return cachedRecords }
    guard
      let indexURL,
      FileManager.default.fileExists(atPath: indexURL.path)
    else {
      cachedRecords = []
      return []
    }
    let data = try Data(contentsOf: indexURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let records = try decoder.decode([ArchivedWeeklyMemory].self, from: data)
    cachedRecords = records
    return records
  }

  private func saveRecords(_ records: [ArchivedWeeklyMemory]) throws {
    cachedRecords = records
    guard let indexURL else { return }
    try FileManager.default.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(records).write(to: indexURL, options: [.atomic])
    try protect(indexURL)
  }

  private func protect(_ url: URL) throws {
    var protectedURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try protectedURL.setResourceValues(values)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
  }
}
