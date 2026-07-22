import XCTest

final class PhoneAppUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testRootScreenLaunches() {
    let app = XCUIApplication()
    app.launchArguments += ["-UITesting"]
    app.launch()

    XCTAssertTrue(app.staticTexts["Watch Companion"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Mori lives on your Watch"].exists)
  }
}
