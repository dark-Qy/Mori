import XCTest

final class PhoneAppUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testMockOverviewAndManagementTabs() {
    let app = launchApp(scenario: "recovery_low")

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.mock-badge", in: app).exists)
    XCTAssertTrue(app.staticTexts["我会陪你放慢一点，不需要硬撑"].exists)
    XCTAssertTrue(app.staticTexts["点亮营地的第一盏灯"].exists)
    XCTAssertTrue(element("phone.pet-overview", in: app).exists)

    app.tabBars.buttons["历史"].tap()
    XCTAssertTrue(element("phone.history", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("phone.history-chart", in: app).exists)

    app.tabBars.buttons["衣橱"].tap()
    XCTAssertTrue(element("phone.wardrobe", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["phone.wardrobe.leaf"].exists)
    app.buttons["phone.wardrobe.leaf"].tap()

    app.tabBars.buttons["隐私"].tap()
    XCTAssertTrue(element("phone.privacy", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.switches["phone.privacy.care-summary"].exists)
    XCTAssertTrue(app.switches["phone.privacy.health-summary"].exists)
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
