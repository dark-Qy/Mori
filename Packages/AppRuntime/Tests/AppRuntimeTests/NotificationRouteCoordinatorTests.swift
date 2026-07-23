import AppRuntime
import Testing

@Suite("Notification navigation coordinator")
struct NotificationRouteCoordinatorTests {
  @Test("Known routes map to bounded presentation destinations")
  func knownRoutesMap() {
    let coordinator = NotificationRouteCoordinator()

    #expect(
      coordinator.destination(for: RuntimeNotificationRoute(route: "pet/recovery"))
        == .recoveryMessage
    )
    #expect(
      coordinator.destination(for: RuntimeNotificationRoute(route: "pet/activity"))
        == .activityMessage
    )
    #expect(
      coordinator.destination(for: RuntimeNotificationRoute(route: "pet/care"))
        == .careMessage
    )
  }

  @Test("Unknown routes are ignored and repeated opens are idempotent")
  func unknownAndRepeatedRoutes() {
    let coordinator = NotificationRouteCoordinator()
    let route = RuntimeNotificationRoute(route: "pet/recovery")

    #expect(coordinator.destination(for: route) == coordinator.destination(for: route))
    #expect(coordinator.destination(for: RuntimeNotificationRoute(route: "settings/delete")) == nil)
  }
}
