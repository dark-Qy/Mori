import XCTest

final class WatchAppUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testMockPetHomeAndInteraction() {
    let app = launchApp(scenario: "activity_high")

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.mock-badge", in: app).exists)
    XCTAssertTrue(app.staticTexts["Mori · Lv.3"].exists)
    XCTAssertTrue(app.buttons["watch.interact"].waitForExistence(timeout: 5))

    app.buttons["watch.interact"].tap()
    XCTAssertTrue(app.staticTexts["watch.interaction-response"].waitForExistence(timeout: 5))
  }

  func testTrendAndMessageNavigation() {
    let app = launchApp(scenario: "health_normal")

    let trendLink = app.buttons["watch.open-trends"]
    scrollToElement(trendLink, in: app)
    XCTAssertTrue(trendLink.exists)
    trendLink.tap()
    XCTAssertTrue(element("watch.trends", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("watch.trend-empty", in: app).exists)

    app.navigationBars.buttons.firstMatch.tap()

    let messageLink = app.buttons["watch.open-messages"]
    scrollToElement(messageLink, in: app)
    XCTAssertTrue(messageLink.exists)
    messageLink.tap()
    XCTAssertTrue(element("watch.messages", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("watch.message.live-activity", in: app).exists)
  }

  func testPartialHealthAndExplanationUseKnownValuesOnly() {
    let app = launchApp(scenario: "health_partial")

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.metric.recovery", in: app).label.contains("尚无可用睡眠"))
    XCTAssertTrue(element("watch.metric.activity", in: app).label.contains("2180 步"))
    XCTAssertTrue(element("watch.metric.rhythm", in: app).label.contains("需要更多睡眠记录"))

    let explanationLink = app.buttons["watch.open-explanation"]
    scrollToElement(explanationLink, in: app)
    explanationLink.tap()
    XCTAssertTrue(element("watch.explanation", in: app).waitForExistence(timeout: 5))
    let explanation = element("watch.explanation.detail", in: app)
    scrollToElement(explanation, in: app)
    XCTAssertTrue(explanation.label.contains("仅使用场景中已知的指标"))
  }

  func testSoccerWorkoutCreatesEligibilityWithoutForcingTheRandomStory() {
    let app = launchApp(scenario: "soccer_workout")

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    let eligibility = element("watch.side-story", in: app)
    scrollToElement(eligibility, in: app)
    XCTAssertEqual(eligibility.label, "已满足足球随机支线资格；本次不保证出现")
    XCTAssertFalse(app.staticTexts["随机支线：失踪的足球"].exists)
  }

  func testAIFailuresUseTheSameLocalFallbackWithoutChangingAuthoritativeState() {
    var fingerprints: [[String]] = []

    for scenario in ["ai_offline", "ai_malformed"] {
      let app = launchApp(scenario: scenario)
      XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
      fingerprints.append(authoritativeFingerprint(in: app))

      let explanationLink = app.buttons["watch.open-explanation"]
      scrollToElement(explanationLink, in: app)
      explanationLink.tap()
      XCTAssertTrue(element("watch.explanation", in: app).waitForExistence(timeout: 5))
      let explanation = element("watch.explanation.detail", in: app)
      scrollToElement(explanation, in: app)
      XCTAssertTrue(explanation.label.contains("当前使用本地表达；规则结果不变"))
      app.terminate()
    }

    XCTAssertEqual(fingerprints.count, 2)
    XCTAssertEqual(fingerprints[0], fingerprints[1])
  }

  func testDefaultLaunchUsesNeutralHealthKitMode() {
    let app = launchLiveApp(storageID: "watch-live-neutral", reset: true)

    XCTAssertTrue(element("watch.onboarding", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.live-badge", in: app).exists)
    XCTAssertFalse(element("watch.mock-badge", in: app).exists)
    let onboardingButton = app.buttons["watch.onboarding.complete"]
    scrollToElement(onboardingButton, in: app)
    onboardingButton.tap()
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    let connectButton = app.buttons["watch.connect-health"]
    scrollToElement(connectButton, in: app)
    XCTAssertTrue(connectButton.exists)
  }

  func testFreshInstallAndPetIntroductionFixturesUseExplicitOneTapEntry() {
    let fresh = launchApp(scenario: "fresh_install")
    XCTAssertTrue(element("watch.onboarding", in: fresh).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.mock-badge", in: fresh).exists)
    XCTAssertFalse(fresh.buttons["watch.connect-health"].exists)
    let freshButton = fresh.buttons["watch.onboarding.complete"]
    scrollToElement(freshButton, in: fresh)
    freshButton.tap()
    XCTAssertTrue(element("watch.pet-home", in: fresh).waitForExistence(timeout: 5))
    fresh.terminate()

    let introduced = launchApp(scenario: "pet_new")
    XCTAssertTrue(element("watch.pet-introduction", in: introduced).waitForExistence(timeout: 8))
    let introductionButton = introduced.buttons["watch.pet-introduction.complete"]
    scrollToElement(introductionButton, in: introduced)
    introductionButton.tap()
    XCTAssertTrue(element("watch.pet-home", in: introduced).waitForExistence(timeout: 5))
  }

  func testInvalidMockFailsClosedAndDisablesInteraction() {
    let app = launchApp(scenario: "not_allowlisted")

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.invalid-mock-badge", in: app).exists)
    XCTAssertFalse(element("watch.mock-badge", in: app).exists)
    XCTAssertFalse(element("watch.live-badge", in: app).exists)

    let interaction = app.buttons["watch.interact"]
    scrollToElement(interaction, in: app)
    XCTAssertTrue(interaction.exists)
    XCTAssertFalse(interaction.isEnabled)
    XCTAssertFalse(app.buttons["watch.connect-health"].exists)
  }

  func testNotificationRouteNavigatesWithoutSettlingStoryOrHabit() {
    let app = launchLiveApp(
      storageID: "notification-nonsettling",
      reset: true,
      additionalArguments: ["--notification-route=pet/recovery"]
    )

    XCTAssertTrue(element("watch.onboarding", in: app).waitForExistence(timeout: 8))
    let onboardingButton = app.buttons["watch.onboarding.complete"]
    scrollToElement(onboardingButton, in: app)
    onboardingButton.tap()
    XCTAssertTrue(
      element("watch.notification.recoveryMessage", in: app).waitForExistence(timeout: 8)
    )
    XCTAssertTrue(app.staticTexts["打开来信不会领取奖励"].exists)
    let dismissButton = app.buttons["watch.notification.dismiss"]
    scrollToElement(dismissButton, in: app)
    dismissButton.tap()
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 5))

    let storyButton = app.buttons["watch.advance-story"]
    scrollToElement(storyButton, in: app)
    storyButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(
      app.staticTexts["今日主线已推进，获得 10 点世界经验"].waitForExistence(timeout: 5)
    )

    let habitButton = app.buttons["watch.interact"]
    scrollToElement(habitButton, in: app)
    habitButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(
      app.staticTexts["今天的小行动已记下；奖励只结算一次"].waitForExistence(timeout: 5)
    )
  }

  func testLiveMainStoryAndHabitPersistWithoutHealthData() {
    let storageID = "phase-one-progression"
    let app = launchLiveApp(storageID: storageID, reset: true)

    XCTAssertTrue(element("watch.onboarding", in: app).waitForExistence(timeout: 8))
    let onboardingButton = app.buttons["watch.onboarding.complete"]
    scrollToElement(onboardingButton, in: app)
    onboardingButton.tap()
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.status-message", in: app).waitForExistence(timeout: 8))
    let storyButton = app.buttons["watch.advance-story"]
    scrollToElement(storyButton, in: app)
    XCTAssertTrue(storyButton.exists)
    storyButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(
      app.staticTexts["今日主线已推进，获得 10 点世界经验"].waitForExistence(timeout: 5))

    let habitButton = app.buttons["watch.interact"]
    scrollToElement(habitButton, in: app)
    XCTAssertTrue(habitButton.exists)
    habitButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(
      app.staticTexts["今天的小行动已记下；奖励只结算一次"].waitForExistence(timeout: 5))
    app.terminate()

    let relaunched = launchLiveApp(storageID: storageID, reset: false)
    XCTAssertTrue(element("watch.pet-home", in: relaunched).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.status-message", in: relaunched).waitForExistence(timeout: 8))
    let repeatedStoryButton = relaunched.buttons["watch.advance-story"]
    scrollToElement(repeatedStoryButton, in: relaunched)
    repeatedStoryButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(
      relaunched.staticTexts["今天的主线已经完成，明天继续"].waitForExistence(timeout: 5))

    let repeatedHabitButton = relaunched.buttons["watch.interact"]
    scrollToElement(repeatedHabitButton, in: relaunched)
    XCTAssertTrue(repeatedHabitButton.exists)
    XCTAssertFalse(repeatedHabitButton.isEnabled)
  }

  func testAccessibilityAuditAcrossPrimarySurfaces() throws {
    let app = launchApp(scenario: "health_partial")
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    try auditCurrentScreen(app)

    for (buttonID, screenID) in [
      ("watch.open-trends", "watch.trends"),
      ("watch.open-messages", "watch.messages"),
      ("watch.open-explanation", "watch.explanation"),
    ] {
      let button = app.buttons[buttonID]
      scrollToElement(button, in: app)
      button.tap()
      XCTAssertTrue(element(screenID, in: app).waitForExistence(timeout: 5))
      try auditCurrentScreen(app)
      app.navigationBars.buttons.firstMatch.tap()
      XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 5))
    }
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

  private func launchLiveApp(
    storageID: String,
    reset: Bool,
    additionalArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      [
        "-UITesting", "--e2e-storage-id=\(storageID)", "--e2e-offline-runtime",
      ] + additionalArguments
    if reset {
      app.launchArguments.append("--reset-e2e-storage")
    }
    app.launch()
    return app
  }

  private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) {
    let scrollView = app.scrollViews.firstMatch

    for _ in 0..<8 {
      let scrollSurface = scrollView.exists ? scrollView : app
      let visibleFrame = scrollSurface.frame.insetBy(dx: 0, dy: 8)
      if element.exists,
        element.frame.minY >= visibleFrame.minY,
        element.frame.maxY <= visibleFrame.maxY
      {
        return
      }
      if element.exists && element.frame.maxY < visibleFrame.minY {
        scrollSurface.swipeDown()
      } else {
        scrollSurface.swipeUp()
      }
    }
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func authoritativeFingerprint(in app: XCUIApplication) -> [String] {
    let level = element("watch.pet-level", in: app)
    let vitality = element("watch.vitality-progress", in: app)
    let quest = element("watch.quest-title", in: app)
    scrollToElement(level, in: app)
    return [level.label, String(describing: vitality.value), quest.label]
  }

  private func auditCurrentScreen(_ app: XCUIApplication) throws {
    try app.performAccessibilityAudit(
      for: [
        .contrast,
        .dynamicType,
        .elementDetection,
        .hitRegion,
        .sufficientElementDescription,
        .textClipped,
        .trait,
      ])
  }
}
