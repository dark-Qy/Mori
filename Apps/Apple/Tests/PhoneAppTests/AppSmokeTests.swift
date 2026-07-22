import XCTest

@testable import WatchCompanion

final class AppSmokeTests: XCTestCase {
  func testAppEntryPointIsLinked() {
    XCTAssertNotNil(WatchCompanionApp.self as Any.Type)
  }
}
