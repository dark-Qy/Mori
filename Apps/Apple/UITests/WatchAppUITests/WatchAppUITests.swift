import XCTest

final class WatchAppUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testMockPetHomeAndInteraction() {
    let app = launchApp(scenario: "active_day")

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.mock-badge", in: app).exists)
    XCTAssertTrue(app.staticTexts["Mori · Lv.8"].exists)
    XCTAssertTrue(app.buttons["watch.interact"].waitForExistence(timeout: 5))

    app.buttons["watch.interact"].tap()
    XCTAssertTrue(app.staticTexts["watch.interaction-response"].waitForExistence(timeout: 5))
  }

  func testTrendAndMessageNavigation() {
    let app = launchApp(scenario: "steady_week")

    let trendLink = app.buttons["watch.open-trends"]
    scrollToElement(trendLink, in: app)
    XCTAssertTrue(trendLink.exists)
    trendLink.tap()
    XCTAssertTrue(element("watch.trends", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("watch.trend-chart", in: app).exists)

    app.navigationBars.buttons.firstMatch.tap()

    let messageLink = app.buttons["watch.open-messages"]
    scrollToElement(messageLink, in: app)
    XCTAssertTrue(messageLink.exists)
    messageLink.tap()
    XCTAssertTrue(element("watch.messages", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("watch.message.pause", in: app).exists)
  }

  func testDefaultLaunchUsesNeutralHealthKitMode() {
    let app = XCUIApplication()
    app.launchArguments = ["-UITesting"]
    app.launch()

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.live-badge", in: app).exists)
    XCTAssertFalse(element("watch.mock-badge", in: app).exists)
    let connectButton = app.buttons["watch.connect-health"]
    scrollToElement(connectButton, in: app)
    XCTAssertTrue(connectButton.exists)
  }

  func testNotificationRouteShowsSafeOptionalAction() {
    let app = launchApp(
      scenario: "recovery_low",
      additionalArguments: ["--notification-route=pet/recovery"]
    )

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["Mori：今天可以慢一点，由你决定是否回应"].exists)
  }

  func testLiveMainStoryAndHabitPersistWithoutHealthData() {
    let storageID = "phase-one-progression"
    let app = launchLiveApp(storageID: storageID, reset: true)

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.status-message", in: app).waitForExistence(timeout: 8))
    let storyButton = app.buttons["watch.advance-story"]
    scrollToElement(storyButton, in: app)
    XCTAssertTrue(storyButton.isHittable)
    storyButton.tap()
    XCTAssertTrue(
      app.staticTexts["今日主线已推进，获得 10 点世界经验"].waitForExistence(timeout: 5))

    let habitButton = app.buttons["watch.interact"]
    scrollToElement(habitButton, in: app)
    XCTAssertTrue(habitButton.isHittable)
    habitButton.tap()
    XCTAssertTrue(
      app.staticTexts["今天的小行动已记下；奖励只结算一次"].waitForExistence(timeout: 5))
    app.terminate()

    let relaunched = launchLiveApp(storageID: storageID, reset: false)
    XCTAssertTrue(element("watch.pet-home", in: relaunched).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.status-message", in: relaunched).waitForExistence(timeout: 8))
    let repeatedStoryButton = relaunched.buttons["watch.advance-story"]
    scrollToElement(repeatedStoryButton, in: relaunched)
    repeatedStoryButton.tap()
    XCTAssertTrue(
      relaunched.staticTexts["今天的主线已经完成，明天继续"].waitForExistence(timeout: 5))

    let repeatedHabitButton = relaunched.buttons["watch.interact"]
    scrollToElement(repeatedHabitButton, in: relaunched)
    XCTAssertTrue(repeatedHabitButton.exists)
    XCTAssertFalse(repeatedHabitButton.isEnabled)
  }

  private func launchApp(
    scenario: String,
    additionalArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITesting", "--mock-scenario=\(scenario)"] + additionalArguments
    app.launch()
    return app
  }

  private func launchLiveApp(storageID: String, reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITesting", "--e2e-storage-id=\(storageID)"]
    if reset {
      app.launchArguments.append("--reset-e2e-storage")
    }
    app.launch()
    return app
  }

  private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<8 where !element.isHittable {
      app.swipeUp()
    }
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
}
