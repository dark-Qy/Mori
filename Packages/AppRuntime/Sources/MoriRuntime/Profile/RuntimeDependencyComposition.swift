import Foundation
import MoriDomain

public enum RuntimeDependencyRole: String, CaseIterable, Codable, Sendable {
  case health
  case location
  case motion
  case notification
  case chat
  case narration
  case connectivity
  case social
}

public enum RuntimeServiceIsolation: String, Codable, Sendable {
  case production
  case localOnly
}

public protocol MoriRuntimeService: Sendable {
  var role: RuntimeDependencyRole { get }
  var isolation: RuntimeServiceIsolation { get }
}

public typealias RuntimeServiceFactory =
  @Sendable () async throws -> any MoriRuntimeService

public struct ProductionRuntimeFactories: Sendable {
  public let health: RuntimeServiceFactory
  public let location: RuntimeServiceFactory
  public let motion: RuntimeServiceFactory
  public let notification: RuntimeServiceFactory
  public let chat: RuntimeServiceFactory
  public let narration: RuntimeServiceFactory
  public let connectivity: RuntimeServiceFactory
  public let social: RuntimeServiceFactory

  public init(
    health: @escaping RuntimeServiceFactory,
    location: @escaping RuntimeServiceFactory,
    motion: @escaping RuntimeServiceFactory,
    notification: @escaping RuntimeServiceFactory,
    chat: @escaping RuntimeServiceFactory,
    narration: @escaping RuntimeServiceFactory,
    connectivity: @escaping RuntimeServiceFactory,
    social: @escaping RuntimeServiceFactory
  ) {
    self.health = health
    self.location = location
    self.motion = motion
    self.notification = notification
    self.chat = chat
    self.narration = narration
    self.connectivity = connectivity
    self.social = social
  }

  fileprivate func factory(for role: RuntimeDependencyRole) -> RuntimeServiceFactory {
    switch role {
    case .health: health
    case .location: location
    case .motion: motion
    case .notification: notification
    case .chat: chat
    case .narration: narration
    case .connectivity: connectivity
    case .social: social
    }
  }
}

public enum RuntimeCompositionError: Error, Equatable, Sendable {
  case invalidProfile
  case wrongServiceRole(
    expected: RuntimeDependencyRole,
    actual: RuntimeDependencyRole
  )
  case productionFactoryReturnedLocalService(RuntimeDependencyRole)
}

public struct RuntimeServiceBundle: Sendable {
  public let profile: RuntimeProfile
  private let services: [RuntimeDependencyRole: any MoriRuntimeService]

  fileprivate init(
    profile: RuntimeProfile,
    services: [RuntimeDependencyRole: any MoriRuntimeService]
  ) {
    self.profile = profile
    self.services = services
  }

  public func service(for role: RuntimeDependencyRole) -> any MoriRuntimeService {
    // The composer creates exactly one service for every enum case.
    services[role]!
  }

  public var conversationIsLocalOnly: Bool {
    service(for: .chat).isolation == .localOnly
  }

  public var touchExchangeIsLocalOnly: Bool {
    service(for: .social).isolation == .localOnly
  }
}

public struct LocalMockRuntimeService: MoriRuntimeService, Sendable {
  public let role: RuntimeDependencyRole
  public let scenarioID: MockScenarioID
  public let isolation: RuntimeServiceIsolation = .localOnly

  public init(role: RuntimeDependencyRole, scenarioID: MockScenarioID) {
    self.role = role
    self.scenarioID = scenarioID
  }
}

public struct LocalMockConversationService: MoriRuntimeService, Sendable {
  public let role: RuntimeDependencyRole = .chat
  public let scenarioID: MockScenarioID
  public let isolation: RuntimeServiceIsolation = .localOnly

  public init(scenarioID: MockScenarioID) {
    self.scenarioID = scenarioID
  }
}

public struct LocalMockTouchExchangeService: MoriRuntimeService, Sendable {
  public let role: RuntimeDependencyRole = .social
  public let scenarioID: MockScenarioID
  public let isolation: RuntimeServiceIsolation = .localOnly

  public init(scenarioID: MockScenarioID) {
    self.scenarioID = scenarioID
  }
}

/// Composes the runtime only after profile validity is established. Mock
/// composition has no path to the injected production factory closures.
public struct MoriRuntimeDependencyComposer: Sendable {
  private let production: ProductionRuntimeFactories

  public init(production: ProductionRuntimeFactories) {
    self.production = production
  }

  public func compose(for profile: RuntimeProfile) async throws -> RuntimeServiceBundle {
    guard profile.isValid else {
      throw RuntimeCompositionError.invalidProfile
    }

    switch profile.source {
    case .real:
      return try await productionBundle(for: profile)
    case .mock(let scenarioID, _):
      return mockBundle(for: profile, scenarioID: scenarioID)
    }
  }

  private func productionBundle(
    for profile: RuntimeProfile
  ) async throws -> RuntimeServiceBundle {
    var services: [RuntimeDependencyRole: any MoriRuntimeService] = [:]
    for role in RuntimeDependencyRole.allCases {
      let service = try await production.factory(for: role)()
      guard service.role == role else {
        throw RuntimeCompositionError.wrongServiceRole(
          expected: role,
          actual: service.role
        )
      }
      guard service.isolation == .production else {
        throw RuntimeCompositionError.productionFactoryReturnedLocalService(role)
      }
      services[role] = service
    }
    return RuntimeServiceBundle(profile: profile, services: services)
  }

  private func mockBundle(
    for profile: RuntimeProfile,
    scenarioID: MockScenarioID
  ) -> RuntimeServiceBundle {
    var services: [RuntimeDependencyRole: any MoriRuntimeService] = [:]
    for role in RuntimeDependencyRole.allCases {
      switch role {
      case .chat:
        services[role] = LocalMockConversationService(scenarioID: scenarioID)
      case .social:
        services[role] = LocalMockTouchExchangeService(scenarioID: scenarioID)
      default:
        services[role] = LocalMockRuntimeService(role: role, scenarioID: scenarioID)
      }
    }
    return RuntimeServiceBundle(profile: profile, services: services)
  }
}
