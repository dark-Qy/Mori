#if DEBUG
  import Foundation

  struct WatchMockTaskReceipt: Equatable {
    let reward: Int
    let balance: Int
    let wasAlreadySettled: Bool
  }

  /// Durable, Debug-only preview state. It never shares a file with the real
  /// profile ledger and cannot be compiled into Release.
  actor WatchMockExperienceRepository {
    private struct Snapshot: Codable {
      static let currentSchemaVersion = 1

      var schemaVersion = currentSchemaVersion
      var presentedGlanceIDs: [String] = []
      var taskRewards: [String: Int] = [:]
    }

    private let fileURL: URL
    private var cached: Snapshot?

    init(fileURL: URL) {
      self.fileURL = fileURL
    }

    /// Atomically terminalizes every event in one replacement batch.
    ///
    /// The candidate is terminal even when it expired or sensing was disabled,
    /// so a later relaunch cannot revive reality that the user never saw.
    func consumeGlanceBatch(
      supersededIDs: [String],
      candidateID: String,
      candidateIsEligible: Bool
    ) throws -> Bool {
      var snapshot = try load()
      let candidateWasTerminal = snapshot.presentedGlanceIDs.contains(candidateID)
      let terminalIDs = Set(supersededIDs + [candidateID])
      let newTerminalIDs = terminalIDs.filter {
        snapshot.presentedGlanceIDs.contains($0) == false
      }
      if newTerminalIDs.isEmpty == false {
        snapshot.presentedGlanceIDs.append(contentsOf: newTerminalIDs)
        snapshot.presentedGlanceIDs.sort()
        try save(snapshot)
      }
      return candidateIsEligible && candidateWasTerminal == false
    }

    func isTaskCompleted(id: String) throws -> Bool {
      try load().taskRewards[id] != nil
    }

    func settleTask(id: String, reward: Int) throws -> WatchMockTaskReceipt {
      var snapshot = try load()
      if let existing = snapshot.taskRewards[id] {
        return WatchMockTaskReceipt(
          reward: existing,
          balance: snapshot.taskRewards.values.reduce(0, +),
          wasAlreadySettled: true
        )
      }
      snapshot.taskRewards[id] = reward
      try save(snapshot)
      return WatchMockTaskReceipt(
        reward: reward,
        balance: snapshot.taskRewards.values.reduce(0, +),
        wasAlreadySettled: false
      )
    }

    func reset(profileKey: String) throws {
      var snapshot = try load()
      let prefix = "\(profileKey):"
      snapshot.presentedGlanceIDs.removeAll { $0.hasPrefix(prefix) }
      snapshot.taskRewards = snapshot.taskRewards.filter {
        $0.key.hasPrefix(prefix) == false
      }
      try save(snapshot)
    }

    private func load() throws -> Snapshot {
      if let cached { return cached }
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        let snapshot = Snapshot()
        cached = snapshot
        return snapshot
      }
      let snapshot = try JSONDecoder().decode(
        Snapshot.self,
        from: Data(contentsOf: fileURL)
      )
      guard snapshot.schemaVersion == Snapshot.currentSchemaVersion else {
        throw CocoaError(.coderReadCorrupt)
      }
      cached = snapshot
      return snapshot
    }

    private func save(_ snapshot: Snapshot) throws {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(snapshot).write(to: fileURL, options: [.atomic])
      cached = snapshot
    }
  }
#endif
