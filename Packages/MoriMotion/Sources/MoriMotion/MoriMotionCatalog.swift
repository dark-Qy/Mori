import Foundation

/// An open-set identifier. Product code may add IDs without changing this package.
public struct MoriMotionID: RawRepresentable, Codable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.init(rawValue: value)
  }

  public var description: String { rawValue }

  public static let idleNeutral: Self = "idle_neutral"
  public static let idleResting: Self = "idle_resting"
}

public enum MoriCatalogStatus: String, Codable, Sendable {
  case authoring
  case ready
}

public enum MoriPriorityClass: String, Codable, CaseIterable, Sendable {
  case idle
  case attention
  case companion
  case conversation
  case event
  case touch

  public var arbitrationRank: Int {
    switch self {
    case .idle: 0
    case .attention: 1
    case .companion: 2
    case .conversation: 3
    case .event: 4
    case .touch: 5
    }
  }
}

public enum MoriPlayback: String, Codable, Sendable {
  case loop
  case oneShot
  case oneShotHoldFinal
}

public enum MoriReturnPolicy: String, Codable, Sendable {
  case remain
  case currentIdle
  case idleResting
}

public enum MoriReplacementPolicy: String, Codable, Sendable {
  case ignoreDuplicateIdentity
  case newestSameKind
  case replaceSameKind
  case restartNewest
}

public enum MoriHaptic: String, Codable, Sendable {
  case none
  case click
  case directionUp
  case success
}

public enum MoriHitTest: String, Codable, Sendable {
  case none
  case character
  case head
  case body
}

public enum MoriProductionForm: String, Codable, Sendable {
  case unique
}

public enum MoriAuthoringStatus: String, Codable, Sendable {
  case approvedFoundation
  case required
  case ready
}

public enum MoriApparelOcclusion: String, Codable, Sendable {
  case compatible
  case requiresMask
  case notApplicable
}

public enum MoriMotionSourceKind: String, Codable, Sendable {
  case productClip
  case hatchV2Row
}

public struct MoriMotionSource: Codable, Equatable, Sendable {
  public let kind: MoriMotionSourceKind
  public let id: String
}

public struct MoriMotionDefinition: Codable, Equatable, Sendable {
  public let id: MoriMotionID
  public let productionForm: MoriProductionForm
  public let authoringStatus: MoriAuthoringStatus
  public let source: MoriMotionSource
  public let playback: MoriPlayback
  public let priorityClass: MoriPriorityClass
  public let triggers: [String]
  public let surfaces: [String]
  public let returnPolicy: MoriReturnPolicy
  public let cooldownMilliseconds: Int
  public let replacementPolicy: MoriReplacementPolicy
  public let haptic: MoriHaptic
  public let hitTest: MoriHitTest
  public let reduceMotionFrame: Int
  public let voiceOverKey: String
  public let visibleAlternateKey: String
  public let watchAllowed: Bool
  public let apparelOcclusion: MoriApparelOcclusion
}

public enum MoriAliasTargetKind: String, Codable, Sendable {
  case motion
  case hatchV2Row
}

public struct MoriAliasTarget: Codable, Equatable, Sendable {
  public let kind: MoriAliasTargetKind
  public let id: String
}

public struct MoriMotionAlias: Codable, Equatable, Sendable {
  public let id: MoriMotionID
  public let target: MoriAliasTarget
}

public struct MoriCell: Codable, Equatable, Sendable {
  public let width: Int
  public let height: Int
}

public struct MoriAnchor: Codable, Equatable, Sendable {
  public let x: Double
  public let footY: Double
}

public struct MoriLayout: Codable, Equatable, Sendable {
  public let anchor: MoriAnchor
  public let scale: Double
}

public struct MoriCatalogDefaults: Codable, Equatable, Sendable {
  public let frameCount: Int
  public let frameOrder: [String]
  public let framesPerSecond: Int
  public let layoutPreset: String
  public let interruptPolicy: String
  public let reduceMotionTransitionMilliseconds: Int
  public let missingFramePolicy: String
  public let backgroundPolicy: String
}

public struct MoriPriorityDefinition: Codable, Equatable, Sendable {
  public let id: MoriPriorityClass
  public let priority: Int
}

public struct MoriPoseSource: Codable, Equatable, Sendable {
  public let kind: String
  public let degrees: Int
}

public struct MoriPose: Codable, Equatable, Sendable {
  public let id: String
  public let sourceMotionID: MoriMotionID?
  public let frame: Int?
  public let source: MoriPoseSource?
}

public struct MoriForbiddenMapping: Codable, Equatable, Sendable {
  public let motionID: MoriMotionID
  public let forbiddenSource: String
}

public enum MoriMotionResolutionKind: Equatable, Sendable {
  case motion
  case hatchV2Row
}

public struct MoriResolvedMotion: Equatable, Sendable {
  public let requestedID: MoriMotionID
  public let motionID: MoriMotionID
  public let assetMotionID: String
  public let definition: MoriMotionDefinition
  public let isAlias: Bool
  public let resolutionKind: MoriMotionResolutionKind
}

public struct MoriAssetReference: Equatable, Sendable {
  public let characterID: String
  public let assetMotionID: String
  public let frameIndex: Int
}

public enum MoriMotionCatalogError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidJSON(String)
  case unsupportedSchemaVersion(Int)
  case invalidContract(String)
  case duplicateID(String)
  case missingFallback(String)
  case unknownMotion(String)
  case aliasCycle([String])
  case invalidAssetReference(String)

  public var description: String {
    switch self {
    case .invalidJSON(let reason): "Invalid motion catalog JSON: \(reason)"
    case .unsupportedSchemaVersion(let version): "Unsupported motion catalog schema: \(version)"
    case .invalidContract(let reason): "Invalid motion catalog contract: \(reason)"
    case .duplicateID(let id): "Duplicate motion catalog ID: \(id)"
    case .missingFallback(let id): "Missing fallback motion: \(id)"
    case .unknownMotion(let id): "Unknown motion or alias: \(id)"
    case .aliasCycle(let path): "Motion alias cycle: \(path.joined(separator: " -> "))"
    case .invalidAssetReference(let value): "Invalid asset reference: \(value)"
    }
  }
}

public struct MoriMotionCatalog: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let status: MoriCatalogStatus
  public let characterIDs: [String]
  public let fallbackMotionID: MoriMotionID
  public let assetKeyTemplate: String
  public let cell: MoriCell
  public let layoutPresets: [String: MoriLayout]
  public let defaults: MoriCatalogDefaults
  public let priorityClasses: [MoriPriorityDefinition]
  public let motions: [MoriMotionDefinition]
  public let aliases: [MoriMotionAlias]
  public let poses: [MoriPose]
  public let policies: [String]
  public let forbiddenMappings: [MoriForbiddenMapping]

  public static func load(data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> Self {
    let catalog: Self
    do {
      catalog = try decoder.decode(Self.self, from: data)
    } catch {
      throw MoriMotionCatalogError.invalidJSON(String(describing: error))
    }
    try catalog.validate()
    return catalog
  }

  public static func load(contentsOf url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> Self {
    try load(data: Data(contentsOf: url), decoder: decoder)
  }

  public func definition(for id: MoriMotionID) -> MoriMotionDefinition? {
    motions.first { $0.id == id }
  }

  public func priority(for priorityClass: MoriPriorityClass) -> Int {
    priorityClasses.first { $0.id == priorityClass }?.priority
      ?? priorityClass.arbitrationRank
  }

  public func resolve(_ id: MoriMotionID) throws -> MoriResolvedMotion {
    try resolve(id, path: [])
  }

  public func assetName(
    characterID: String,
    motionID: MoriMotionID,
    frameIndex: Int
  ) throws -> String {
    guard characterIDs.contains(characterID),
      defaults.frameOrder.indices.contains(frameIndex)
    else {
      throw MoriMotionCatalogError.invalidAssetReference(
        "\(characterID)/\(motionID.rawValue)/\(frameIndex)"
      )
    }
    let resolved = try resolve(motionID)
    return renderAssetName(
      characterID: characterID,
      assetMotionID: resolved.assetMotionID,
      frame: defaults.frameOrder[frameIndex]
    )
  }

  public func frameNames(
    characterID: String,
    motionID: MoriMotionID
  ) throws -> [String] {
    let resolved = try resolve(motionID)
    guard characterIDs.contains(characterID) else {
      throw MoriMotionCatalogError.invalidAssetReference(characterID)
    }
    return defaults.frameOrder.map {
      renderAssetName(
        characterID: characterID,
        assetMotionID: resolved.assetMotionID,
        frame: $0
      )
    }
  }

  public func parseAssetName(_ name: String) -> MoriAssetReference? {
    guard assetKeyTemplate == "character_{character}_{motion}_{frame}",
      name.hasPrefix("character_")
    else { return nil }

    let body = String(name.dropFirst("character_".count))
    guard let character = characterIDs.sorted(by: { $0.count > $1.count }).first(where: {
      body.hasPrefix($0 + "_")
    }) else { return nil }

    let motionAndFrame = String(body.dropFirst(character.count + 1))
    guard let separator = motionAndFrame.lastIndex(of: "_") else { return nil }
    let assetMotionID = String(motionAndFrame[..<separator])
    let frame = String(motionAndFrame[motionAndFrame.index(after: separator)...])
    guard let frameIndex = defaults.frameOrder.firstIndex(of: frame),
      validAssetMotionIDs.contains(assetMotionID)
    else { return nil }

    return MoriAssetReference(
      characterID: character,
      assetMotionID: assetMotionID,
      frameIndex: frameIndex
    )
  }

  public func validate() throws {
    guard schemaVersion == 2 else {
      throw MoriMotionCatalogError.unsupportedSchemaVersion(schemaVersion)
    }
    guard fallbackMotionID == .idleNeutral else {
      throw MoriMotionCatalogError.invalidContract("fallbackMotionID must be idle_neutral")
    }
    guard !characterIDs.isEmpty, Set(characterIDs).count == characterIDs.count,
      characterIDs.allSatisfy(Self.isValidID)
    else {
      throw MoriMotionCatalogError.invalidContract("characterIDs must be unique valid IDs")
    }
    guard assetKeyTemplate == "character_{character}_{motion}_{frame}" else {
      throw MoriMotionCatalogError.invalidContract("unsupported assetKeyTemplate")
    }
    guard cell.width > 0, cell.height > 0,
      defaults.frameCount > 0,
      defaults.frameOrder.count == defaults.frameCount,
      Set(defaults.frameOrder).count == defaults.frameOrder.count,
      defaults.framesPerSecond > 0,
      defaults.reduceMotionTransitionMilliseconds >= 0,
      defaults.interruptPolicy == "higherPriorityOrReplacement",
      defaults.missingFramePolicy == "fallbackToNeutralIdle",
      defaults.backgroundPolicy == "clear"
    else {
      throw MoriMotionCatalogError.invalidContract("invalid playback defaults")
    }
    guard layoutPresets[defaults.layoutPreset] != nil else {
      throw MoriMotionCatalogError.invalidContract("missing default layout preset")
    }

    let priorityIDs = priorityClasses.map(\.id)
    guard priorityIDs.count == MoriPriorityClass.allCases.count,
      Set(priorityIDs) == Set(MoriPriorityClass.allCases)
    else {
      throw MoriMotionCatalogError.invalidContract("priority classes must be complete and unique")
    }
    let orderedPriorities = MoriPriorityClass.allCases.compactMap { priorityClass in
      priorityClasses.first { $0.id == priorityClass }?.priority
    }
    guard zip(orderedPriorities, orderedPriorities.dropFirst()).allSatisfy(<) else {
      throw MoriMotionCatalogError.invalidContract(
        "priority order must be touch > event > conversation > companion > attention > idle"
      )
    }

    var allIDs = Set<String>()
    for motion in motions {
      guard Self.isValidID(motion.id.rawValue) else {
        throw MoriMotionCatalogError.invalidContract("invalid motion ID \(motion.id)")
      }
      guard allIDs.insert(motion.id.rawValue).inserted else {
        throw MoriMotionCatalogError.duplicateID(motion.id.rawValue)
      }
      guard motion.cooldownMilliseconds >= 0,
        defaults.frameOrder.indices.contains(motion.reduceMotionFrame),
        !motion.triggers.isEmpty,
        !motion.surfaces.isEmpty,
        motion.surfaces.allSatisfy({ !$0.isEmpty })
      else {
        throw MoriMotionCatalogError.invalidContract("invalid motion \(motion.id)")
      }
    }
    guard definition(for: fallbackMotionID) != nil else {
      throw MoriMotionCatalogError.missingFallback(fallbackMotionID.rawValue)
    }
    for alias in aliases {
      guard Self.isValidID(alias.id.rawValue),
        Self.isValidID(alias.target.id)
      else {
        throw MoriMotionCatalogError.invalidContract("invalid alias \(alias.id)")
      }
      guard allIDs.insert(alias.id.rawValue).inserted else {
        throw MoriMotionCatalogError.duplicateID(alias.id.rawValue)
      }
    }
    for alias in aliases {
      _ = try resolve(alias.id)
    }
  }

  private var validAssetMotionIDs: Set<String> {
    Set(motions.map(\.source.id))
      .union(aliases.compactMap { $0.target.kind == .hatchV2Row ? $0.target.id : nil })
  }

  private func resolve(_ id: MoriMotionID, path: [MoriMotionID]) throws -> MoriResolvedMotion {
    if let motion = definition(for: id) {
      return MoriResolvedMotion(
        requestedID: path.first ?? id,
        motionID: motion.id,
        assetMotionID: motion.source.id,
        definition: motion,
        isAlias: !path.isEmpty,
        resolutionKind: .motion
      )
    }
    guard !path.contains(id) else {
      throw MoriMotionCatalogError.aliasCycle((path + [id]).map(\.rawValue))
    }
    guard let alias = aliases.first(where: { $0.id == id }) else {
      throw MoriMotionCatalogError.unknownMotion(id.rawValue)
    }

    switch alias.target.kind {
    case .motion:
      let target = try resolve(
        MoriMotionID(rawValue: alias.target.id),
        path: path + [id]
      )
      return MoriResolvedMotion(
        requestedID: path.first ?? id,
        motionID: target.motionID,
        assetMotionID: target.assetMotionID,
        definition: target.definition,
        isAlias: true,
        resolutionKind: target.resolutionKind
      )
    case .hatchV2Row:
      guard let fallback = definition(for: fallbackMotionID) else {
        throw MoriMotionCatalogError.missingFallback(fallbackMotionID.rawValue)
      }
      return MoriResolvedMotion(
        requestedID: path.first ?? id,
        motionID: id,
        assetMotionID: alias.target.id,
        definition: fallback,
        isAlias: true,
        resolutionKind: .hatchV2Row
      )
    }
  }

  private func renderAssetName(
    characterID: String,
    assetMotionID: String,
    frame: String
  ) -> String {
    assetKeyTemplate
      .replacingOccurrences(of: "{character}", with: characterID)
      .replacingOccurrences(of: "{motion}", with: assetMotionID)
      .replacingOccurrences(of: "{frame}", with: frame)
  }

  private static func isValidID(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
      CharacterSet.lowercaseLetters.contains(first)
    else { return false }
    let allowed = CharacterSet.lowercaseLetters
      .union(.decimalDigits)
      .union(CharacterSet(charactersIn: "_"))
    return value.unicodeScalars.allSatisfy(allowed.contains)
  }
}

public struct MoriCatalogLoadResult: Sendable {
  public let catalog: MoriMotionCatalog
  public let usedFallback: Bool
  public let errorDescription: String?
}

public enum MoriMotionCatalogLoader {
  public static func loadOrFallback(
    data: Data,
    decoder: JSONDecoder = JSONDecoder()
  ) -> MoriCatalogLoadResult {
    do {
      return MoriCatalogLoadResult(
        catalog: try MoriMotionCatalog.load(data: data, decoder: decoder),
        usedFallback: false,
        errorDescription: nil
      )
    } catch {
      return MoriCatalogLoadResult(
        catalog: .emergencyFallback,
        usedFallback: true,
        errorDescription: String(describing: error)
      )
    }
  }
}

extension MoriMotionCatalog {
  /// A deliberately tiny, deterministic last-resort catalog for malformed input.
  public static let emergencyFallback: Self = {
    let idle = MoriMotionDefinition(
      id: .idleNeutral,
      productionForm: .unique,
      authoringStatus: .approvedFoundation,
      source: MoriMotionSource(kind: .hatchV2Row, id: "idle"),
      playback: .loop,
      priorityClass: .idle,
      triggers: ["mood.neutral"],
      surfaces: [
        "watch.home", "watch.memory", "phone.mori", "phone.today", "phone.memory",
        "phone.chat",
      ],
      returnPolicy: .remain,
      cooldownMilliseconds: 0,
      replacementPolicy: .ignoreDuplicateIdentity,
      haptic: .none,
      hitTest: .character,
      reduceMotionFrame: 0,
      voiceOverKey: "motion.idle_neutral.voice_over",
      visibleAlternateKey: "motion.idle_neutral.visible",
      watchAllowed: true,
      apparelOcclusion: .compatible
    )
    return Self(
      schemaVersion: 2,
      status: .ready,
      characterIDs: ["penguin"],
      fallbackMotionID: .idleNeutral,
      assetKeyTemplate: "character_{character}_{motion}_{frame}",
      cell: MoriCell(width: 192, height: 208),
      layoutPresets: [
        "standardGrounded": MoriLayout(
          anchor: MoriAnchor(x: 0.5, footY: 0.94),
          scale: 1
        )
      ],
      defaults: MoriCatalogDefaults(
        frameCount: 8,
        frameOrder: (0..<8).map { String(format: "%02d", $0) },
        framesPerSecond: 10,
        layoutPreset: "standardGrounded",
        interruptPolicy: "higherPriorityOrReplacement",
        reduceMotionTransitionMilliseconds: 150,
        missingFramePolicy: "fallbackToNeutralIdle",
        backgroundPolicy: "clear"
      ),
      priorityClasses: MoriPriorityClass.allCases.enumerated().map {
        MoriPriorityDefinition(id: $0.element, priority: ($0.offset + 1) * 100)
      },
      motions: [idle],
      aliases: [],
      poses: [],
      policies: [],
      forbiddenMappings: []
    )
  }()
}
