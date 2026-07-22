import XCTest

final class WatchAppUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testPetHomeLaunches() {
    let app = XCUIApplication()
    app.launchArguments += ["-UITesting"]
    app.launch()

    XCTAssertTrue(app.staticTexts["Mori"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Mori"].exists)
  }
}
