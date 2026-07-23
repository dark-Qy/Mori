import AppleAdapters
import Domain
import Foundation

public struct HealthIngestionResult: Equatable, Sendable {
  public let requestState: HealthAccessRequestState
  public let snapshot: Domain.HealthSnapshot
  public let event: EventEnvelope

  public init(
    requestState: HealthAccessRequestState,
    snapshot: Domain.HealthSnapshot,
    event: EventEnvelope
  ) {
    self.requestState = requestState
    self.snapshot = snapshot
    self.event = event
  }
}

public struct HealthIngestionService<Client: HealthDataClient>: Sendable {
  public var client: Client
  public var mapper: HealthSnapshotMapper
  public var source: EventSource

  public init(
    client: Client,
    mapper: HealthSnapshotMapper = HealthSnapshotMapper(),
    source: EventSource
  ) {
    self.client = client
    self.mapper = mapper
    self.source = source
  }

  public func ingest(
    window: HealthQueryWindow,
    timeZone: TimeZone,
    requestAccessIfNeeded: Bool
  ) async throws -> HealthIngestionResult {
    var requestState = await client.accessRequestState()
    if requestState == .notRequested && requestAccessIfNeeded {
      requestState = await client.requestAccess()
    }
    let adapterSnapshot = try await client.fetchSnapshot(in: window)
    let snapshot = mapper.map(
      adapterSnapshot,
      requestState: requestState,
      timeZone: timeZone
    )
    let event = EventEnvelope(
      eventID: HealthEventIdentity.make(for: snapshot),
      occurredAt: adapterSnapshot.capturedAt,
      source: source,
      payload: .healthSnapshotReceived(snapshot)
    )
    return HealthIngestionResult(requestState: requestState, snapshot: snapshot, event: event)
  }
}

enum HealthEventIdentity {
  static func make(for snapshot: Domain.HealthSnapshot) -> UUID {
    let sources = snapshot.sources.sorted { $0.identifier < $1.identifier }.map {
      "\($0.identifier):\($0.displayName):\($0.kind.rawValue)"
    }.joined(separator: ",")
    let stages =
      snapshot.sleepStages.map {
        "\($0.coreMinutes):\($0.deepMinutes):\($0.remMinutes):\($0.unspecifiedMinutes):\($0.awakeMinutes)"
      } ?? "nil"
    let workouts = snapshot.workouts.sorted { $0.id.uuidString < $1.id.uuidString }.map {
      [
        $0.id.uuidString,
        $0.activity.rawValue,
        String($0.startedAt.timeIntervalSince1970),
        String($0.durationMinutes),
        $0.activeEnergyKilocalories.map { String($0) } ?? "nil",
      ].joined(separator: ":")
    }.joined(separator: ",")
    let stateOfMindSamples = (snapshot.stateOfMindSamples ?? [])
      .sorted { $0.id.uuidString < $1.id.uuidString }
      .map {
        [
          $0.id.uuidString,
          String($0.recordedAt.timeIntervalSince1970),
          String($0.valence),
          $0.labels.map(\.rawValue).sorted().joined(separator: ","),
        ].joined(separator: ":")
      }
      .joined(separator: ",")
    let descriptor = [
      String(snapshot.schemaVersion),
      String(snapshot.capturedAt.timeIntervalSince1970),
      snapshot.timeZoneIdentifier,
      snapshot.localDay.rawValue,
      snapshot.freshness.rawValue,
      snapshot.requestState.rawValue,
      snapshot.availability.rawValue,
      sources,
      String(snapshot.sleepMinutes ?? -1),
      stages,
      snapshot.sleepWindowStart.map { String($0.timeIntervalSince1970) } ?? "nil",
      snapshot.sleepWindowEnd.map { String($0.timeIntervalSince1970) } ?? "nil",
      String(snapshot.steps ?? -1),
      String(snapshot.activeMinutes ?? -1),
      String(snapshot.restingHeartRateBPM ?? -1),
      workouts,
      stateOfMindSamples,
    ].joined(separator: "|")
    let first = fnv1a(descriptor.utf8, seed: 0xCBF2_9CE4_8422_2325)
    let second = fnv1a(descriptor.utf8.reversed(), seed: 0x8422_2325_CBF2_9CE4)
    return UUID(
      uuid: (
        UInt8(truncatingIfNeeded: first >> 56), UInt8(truncatingIfNeeded: first >> 48),
        UInt8(truncatingIfNeeded: first >> 40), UInt8(truncatingIfNeeded: first >> 32),
        UInt8(truncatingIfNeeded: first >> 24), UInt8(truncatingIfNeeded: first >> 16),
        UInt8(truncatingIfNeeded: first >> 8), UInt8(truncatingIfNeeded: first),
        UInt8(truncatingIfNeeded: second >> 56), UInt8(truncatingIfNeeded: second >> 48),
        UInt8(truncatingIfNeeded: second >> 40), UInt8(truncatingIfNeeded: second >> 32),
        UInt8(truncatingIfNeeded: second >> 24), UInt8(truncatingIfNeeded: second >> 16),
        UInt8(truncatingIfNeeded: second >> 8), UInt8(truncatingIfNeeded: second)
      ))
  }

  private static func fnv1a<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64
  where S.Element == UInt8 {
    bytes.reduce(seed) { hash, byte in
      (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
  }
}
