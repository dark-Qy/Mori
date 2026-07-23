import XCTest

final class PhoneAppUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testMockOverviewAndManagementTabs() {
    let app = launchApp(scenario: "health_normal")

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.mock-badge", in: app).exists)
    XCTAssertTrue(app.staticTexts["今天的冒险能量正在发光"].exists)
    XCTAssertTrue(app.staticTexts["点亮营地的第一盏灯"].exists)
    XCTAssertTrue(element("phone.pet-overview", in: app).exists)

    app.tabBars.buttons["历史"].tap()
    XCTAssertTrue(element("phone.history", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("phone.history-empty", in: app).exists)
    XCTAssertTrue(app.staticTexts["至少保留两天已知数据后再开始比较；缺失日不会按零计算。"].exists)

    app.tabBars.buttons["衣橱"].tap()
    XCTAssertTrue(element("phone.wardrobe", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["phone.wardrobe.leaf"].exists)
    app.buttons["phone.wardrobe.leaf"].tap()

    app.tabBars.buttons["隐私"].tap()
    XCTAssertTrue(element("phone.privacy", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.switches["phone.privacy.social-sharing"].exists)
    XCTAssertTrue(element("phone.privacy.sharing-scope", in: app).exists)
  }

  func testDefaultLaunchNeverPretendsMockDataIsLive() {
    let app = XCUIApplication()
    app.launchArguments = ["-UITesting"]
    app.launch()

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.live-badge", in: app).exists)
    XCTAssertFalse(element("phone.mock-badge", in: app).exists)
    XCTAssertTrue(app.buttons["phone.connect-health"].exists)
  }

  func testInvalidMockFailsClosedWithoutHealthKitControls() {
    let app = launchApp(scenario: "not_allowlisted")

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.invalid-mock-badge", in: app).exists)
    XCTAssertFalse(element("phone.mock-badge", in: app).exists)
    XCTAssertFalse(element("phone.live-badge", in: app).exists)
    XCTAssertFalse(app.buttons["phone.connect-health"].exists)
  }

  func testNotificationRouteOpensSafeOverviewWithoutSettlingAReward() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITesting", "--mock-scenario=health_normal", "--notification-route=pet/recovery",
    ]
    app.launch()

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(
      app.staticTexts["已打开 Mori 的恢复来信；不会自动完成任务或领取奖励"].exists)
  }

  private func launchApp(scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITesting", "--mock-scenario=\(scenario)"]
    app.launch()
    return app
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
}
