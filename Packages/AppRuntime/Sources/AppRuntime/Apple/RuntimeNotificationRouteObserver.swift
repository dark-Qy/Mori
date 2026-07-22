#if canImport(UserNotifications) && (os(iOS) || os(watchOS))
  import AppleAdapters
  import Foundation

  public struct RuntimeNotificationRoute: Equatable, Sendable {
    public let route: String
    public let parameters: [String: String]

    public init(route: String, parameters: [String: String] = [:]) {
      self.route = route
      self.parameters = parameters
    }
  }

  public final class RuntimeNotificationRouteObserver: @unchecked Sendable {
    private let router: AppleNotificationResponseRouter

    public init() {
      router = AppleNotificationResponseRouter()
    }

    public func routes() -> AsyncStream<RuntimeNotificationRoute> {
      let source = router.routes()
      return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let task = Task {
          for await deepLink in source {
            guard !Task.isCancelled else { break }
            continuation.yield(
              RuntimeNotificationRoute(
                route: deepLink.route,
                parameters: deepLink.parameters
              )
            )
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }
#endif
