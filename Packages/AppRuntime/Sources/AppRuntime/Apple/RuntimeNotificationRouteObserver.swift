#if canImport(UserNotifications) && (os(iOS) || os(watchOS))
  import AppleAdapters
  import Foundation

  public final class RuntimeNotificationRouteObserver: @unchecked Sendable {
    private static let sharedRouter = AppleNotificationResponseRouter()

    private let router: AppleNotificationResponseRouter

    public static func install() {
      _ = sharedRouter
    }

    public init() {
      router = Self.sharedRouter
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
