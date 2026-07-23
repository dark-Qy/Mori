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
    let leaf = app.buttons["phone.wardrobe.preview.leaf"]
    scrollToElement(leaf, in: app)
    XCTAssertTrue(leaf.exists)
    leaf.tap()
    XCTAssertTrue(element("phone.wardrobe.locked-reason", in: app).exists)

    app.tabBars.buttons["隐私"].tap()
    XCTAssertTrue(element("phone.privacy", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.switches["phone.privacy.social-sharing"].exists)
    XCTAssertTrue(element("phone.privacy.sharing-scope", in: app).exists)
  }

  func testDefaultLaunchNeverPretendsMockDataIsLive() {
    let app = launchLiveApp(storageID: "phone-live-neutral", reset: true)

    XCTAssertTrue(element("phone.onboarding", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.live-badge", in: app).exists)
    XCTAssertFalse(element("phone.mock-badge", in: app).exists)
    app.buttons["phone.onboarding.complete"].tap()
    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["phone.connect-health"].exists)
  }

  func testFreshInstallOnboardingUsesNoPermissionPromptAndMockRemainsInMemory() {
    let app = launchApp(scenario: "fresh_install")

    XCTAssertTrue(element("phone.onboarding", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.mock-badge", in: app).exists)
    XCTAssertFalse(app.buttons["phone.connect-health"].exists)
    app.buttons["phone.onboarding.complete"].tap()
    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("phone.mock-badge", in: app).exists)
  }

  func testLiveOnboardingAndWardrobePersistOfflineAcrossRelaunchAndReset() {
    let storageID = "phone-wardrobe-state"
    let app = launchLiveApp(storageID: storageID, reset: true)

    XCTAssertTrue(element("phone.onboarding", in: app).waitForExistence(timeout: 8))
    app.buttons["phone.onboarding.complete"].tap()
    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))

    app.tabBars.buttons["衣橱"].tap()
    XCTAssertTrue(element("phone.wardrobe", in: app).waitForExistence(timeout: 5))
    let scarf = app.buttons["phone.wardrobe.preview.soccer_scarf"]
    scrollToElement(scarf, in: app)
    scarf.tap()
    XCTAssertTrue(app.staticTexts["正在预览：球场围巾"].exists)
    let equip = app.buttons["phone.wardrobe.equip"]
    scrollToElement(equip, in: app)
    equip.tap()
    XCTAssertTrue(
      app.staticTexts["装扮已保存在本机；已保存，等待 Apple Watch"]
        .waitForExistence(timeout: 8)
    )
    XCTAssertTrue(app.staticTexts["当前已装备：球场围巾"].exists)
    app.terminate()

    let relaunched = launchLiveApp(storageID: storageID, reset: false)
    XCTAssertTrue(element("phone.overview", in: relaunched).waitForExistence(timeout: 8))
    XCTAssertFalse(element("phone.onboarding", in: relaunched).exists)
    relaunched.tabBars.buttons["衣橱"].tap()
    XCTAssertTrue(element("phone.wardrobe", in: relaunched).waitForExistence(timeout: 5))
    XCTAssertTrue(relaunched.staticTexts["当前已装备：球场围巾"].exists)

    let reset = relaunched.buttons["phone.wardrobe.reset"]
    scrollToElement(reset, in: relaunched)
    reset.tap()
    XCTAssertTrue(
      relaunched.staticTexts["已恢复默认外观；已保存，等待 Apple Watch"]
        .waitForExistence(timeout: 8)
    )
    relaunched.terminate()

    let resetRelaunch = launchLiveApp(storageID: storageID, reset: false)
    XCTAssertTrue(element("phone.overview", in: resetRelaunch).waitForExistence(timeout: 8))
    resetRelaunch.tabBars.buttons["衣橱"].tap()
    XCTAssertTrue(resetRelaunch.staticTexts["当前已装备：基础外观"].waitForExistence(timeout: 5))
  }

  func testFixtureWardrobeSeparatesUnlockedAndLockedEquipStates() {
    let unlocked = launchApp(scenario: "outfit_unlocked")
    XCTAssertTrue(element("phone.wardrobe", in: unlocked).waitForExistence(timeout: 8))
    XCTAssertTrue(unlocked.staticTexts["正在预览：球场围巾"].exists)
    let unlockedEquip = unlocked.buttons["phone.wardrobe.equip"]
    scrollToElement(unlockedEquip, in: unlocked)
    XCTAssertTrue(unlockedEquip.isEnabled)
    unlockedEquip.tap()
    XCTAssertTrue(unlocked.staticTexts["当前已装备：球场围巾"].waitForExistence(timeout: 5))
    unlocked.terminate()

    let locked = launchApp(scenario: "outfit_locked")
    XCTAssertTrue(element("phone.wardrobe", in: locked).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.wardrobe.locked-reason", in: locked).exists)
    XCTAssertFalse(locked.buttons["phone.wardrobe.equip"].exists)
    XCTAssertTrue(locked.staticTexts["正在预览：球场围巾"].exists)
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

    XCTAssertTrue(
      element("phone.notification.recoveryMessage", in: app).waitForExistence(timeout: 8)
    )
    XCTAssertTrue(app.staticTexts["打开来信只负责导航"].exists)
    app.buttons["phone.notification.dismiss"].tap()
    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["已打开 Mori 的恢复来信；不会自动完成任务或领取奖励"].exists)
  }

  private func launchApp(scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-UITesting", "--mock-scenario=\(scenario)"]
    app.launch()
    return app
  }

  private func launchLiveApp(storageID: String, reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITesting", "--e2e-storage-id=\(storageID)", "--e2e-offline-runtime",
    ]
    if reset {
      app.launchArguments.append("--reset-e2e-storage")
    }
    app.launch()
    return app
  }

  private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
    let scrollView = app.scrollViews.firstMatch
    for _ in 0..<8 {
      let visibleFrame = scrollView.frame.insetBy(dx: 0, dy: 8)
      if element.exists,
        element.frame.minY >= visibleFrame.minY,
        element.frame.maxY <= visibleFrame.maxY
      {
        return
      }
      if element.exists && element.frame.maxY < visibleFrame.minY {
        scrollView.swipeDown()
      } else {
        scrollView.swipeUp()
      }
    }
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
}
