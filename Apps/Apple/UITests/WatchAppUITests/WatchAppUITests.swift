import XCTest

final class WatchAppUITests: XCTestCase {
  private var sharedTransferEventID: String {
    ProcessInfo.processInfo.environment["SOCIAL_TRANSFER_E2E_EVENT_ID"]
      ?? "0123456789abcdef0123456789abcdef"
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testMockPetHomeAndInteraction() {
    let app = launchApp(scenario: "activity_high")

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.mock-badge", in: app).exists)
    XCTAssertTrue(app.staticTexts["Mori · Lv.3"].exists)
    XCTAssertTrue(app.buttons["watch.interact"].waitForExistence(timeout: 5))
    let scene = app.buttons["watch.companion-scene"]
    XCTAssertTrue(scene.exists)
    XCTAssertEqual(scene.value as? String, "企鹅伙伴，冰海白昼")
    scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    XCTAssertTrue(app.staticTexts["Mori 开心地眨了眨眼"].waitForExistence(timeout: 5))

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

  func testTouchExchangeRequiresFriendSharingBeforeStarting() {
    let app = launchApp(scenario: "activity_high")

    openTouchExchange(in: app)
    let sharingGate = element("watch.touch-exchange.sharing-gate", in: app)
    scrollToElement(sharingGate, in: app)
    XCTAssertTrue(sharingGate.label.contains("iPhone"))
    XCTAssertTrue(sharingGate.label.contains("不会上传公开宠物卡"))

    let startButton = app.buttons["watch.touch-exchange.start"]
    scrollToElement(startButton, in: app)
    XCTAssertEqual(startButton.label, "需先开启好友分享")
    XCTAssertFalse(startButton.isEnabled)
    XCTAssertFalse(element("watch.touch-exchange.progress", in: app).exists)
  }

  func testTouchExchangeDemoRequiresPreviewAndBothConfirmations() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-social-state=walk",
      ]
    )

    openTouchExchange(in: app)
    XCTAssertFalse(element("watch.touch-exchange.peer-card", in: app).exists)
    let localSocialState = element(
      "watch.touch-exchange.local-social-state",
      in: app
    )
    scrollToElement(localSocialState, in: app)
    XCTAssertTrue(localSocialState.label.contains("想一起散步"))
    let startButton = app.buttons["watch.touch-exchange.start"]
    scrollToElement(startButton, in: app)
    XCTAssertEqual(startButton.label, "开始触碰")
    XCTAssertTrue(startButton.isEnabled)
    XCTAssertEqual(app.textFields.count, 0)
    startButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.peer-card", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertFalse(element("watch.touch-exchange.completed", in: app).exists)

    let confirmButton = app.buttons["watch.touch-exchange.confirm"]
    scrollToElement(confirmButton, in: app)
    confirmButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.completed", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.staticTexts["遇见卡交换成功"].exists)
    let persistenceStatus = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "相遇记录已保存")
    ).firstMatch
    scrollToElement(persistenceStatus, in: app)
    XCTAssertTrue(
      persistenceStatus.waitForExistence(timeout: 5)
    )
  }

  func testTouchExchangeSourcePetLeavesThisWatchAndLandsOnce() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-transfer-role=source",
        "--touch-exchange-transfer-event-id=\(sharedTransferEventID)",
        "--touch-exchange-transfer-ledger-reset",
      ]
    )

    completeTouchExchange(in: app)
    let transfer = element(
      "watch.touch-exchange.transfer.source",
      in: app
    )
    XCTAssertTrue(transfer.waitForExistence(timeout: 5))
    XCTAssertTrue(app.frame.intersects(transfer.frame))
    XCTAssertTrue(
      (transfer.value as? String)?.contains("event:\(sharedTransferEventID)|") == true
    )
    XCTAssertTrue((transfer.value as? String)?.contains("source|") == true)
    XCTAssertTrue((transfer.value as? String)?.contains("|penguin|") == true)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(
              format: "value CONTAINS %@",
              "source|landed|penguin|frame:7"
            ),
            object: transfer
          )
        ],
        timeout: 4
      ),
      .completed
    )

    app.terminate()
    let replay = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-transfer-role=source",
        "--touch-exchange-transfer-event-id=\(sharedTransferEventID)",
      ]
    )
    completeTouchExchange(in: replay)
    let replayedTransfer = element(
      "watch.touch-exchange.transfer.source",
      in: replay
    )
    let duplicatePlayback = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true"),
      object: replayedTransfer
    )
    duplicatePlayback.isInverted = true
    XCTAssertEqual(
      XCTWaiter.wait(for: [duplicatePlayback], timeout: 1.2),
      .completed
    )
  }

  func testTouchExchangeDestinationReceivesTheSamePetAndHandlesLateCue() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-transfer-role=destination",
        "--touch-exchange-transfer-event-id=\(sharedTransferEventID)",
        "--touch-exchange-transfer-late",
        "--touch-exchange-transfer-ledger-reset",
      ]
    )

    completeTouchExchange(in: app)
    let transfer = element(
      "watch.touch-exchange.transfer.destination",
      in: app
    )
    XCTAssertTrue(transfer.waitForExistence(timeout: 5))
    XCTAssertTrue(app.frame.intersects(transfer.frame))
    XCTAssertTrue(
      (transfer.value as? String)?.contains("event:\(sharedTransferEventID)|") == true
    )
    XCTAssertTrue((transfer.value as? String)?.contains("destination|") == true)
    XCTAssertTrue((transfer.value as? String)?.contains("|penguin|") == true)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(
              format: "value CONTAINS %@",
              "destination|landed|penguin|frame:7"
            ),
            object: transfer
          )
        ],
        timeout: 3
      ),
      .completed
    )
  }

  func testTouchExchangePeerFirstStillRequiresLocalConfirmation() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-peer-first",
      ]
    )

    openTouchExchange(in: app)
    let startButton = app.buttons["watch.touch-exchange.start"]
    scrollToElement(startButton, in: app)
    startButton.tap()

    XCTAssertTrue(
      element("watch.touch-exchange.peer-first-message", in: app)
        .waitForExistence(timeout: 5)
    )
    XCTAssertFalse(element("watch.touch-exchange.completed", in: app).exists)
    let confirmButton = app.buttons["watch.touch-exchange.confirm"]
    scrollToElement(confirmButton, in: app)
    XCTAssertTrue(confirmButton.isEnabled)
    confirmButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.completed", in: app).waitForExistence(timeout: 5)
    )
  }

  func testTouchExchangeCancellationIgnoresOldDemoCallbacks() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: ["--touch-exchange-demo"]
    )

    openTouchExchange(in: app)
    let startButton = app.buttons["watch.touch-exchange.start"]
    scrollToElement(startButton, in: app)
    startButton.tap()
    let cancelButton = app.buttons["watch.touch-exchange.cancel"]
    scrollToElement(cancelButton, in: app)
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
    cancelButton.tap()

    XCTAssertTrue(
      app.buttons["watch.touch-exchange.retry"].waitForExistence(timeout: 5)
    )
    let latePreview = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true"),
      object: element("watch.touch-exchange.peer-card", in: app)
    )
    latePreview.isInverted = true
    XCTAssertEqual(
      XCTWaiter.wait(for: [latePreview], timeout: 1),
      .completed
    )
    XCTAssertFalse(element("watch.touch-exchange.completed", in: app).exists)
  }

  func testTouchExchangeCancelFailureRetriesCleanupBeforeNewSession() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-cancel-failure",
      ]
    )

    openTouchExchange(in: app)
    let startButton = app.buttons["watch.touch-exchange.start"]
    scrollToElement(startButton, in: app)
    startButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.peer-card", in: app).waitForExistence(timeout: 5)
    )

    let cancelButton = app.buttons["watch.touch-exchange.cancel"]
    scrollToElement(cancelButton, in: app)
    cancelButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.cancel-unconfirmed", in: app)
        .waitForExistence(timeout: 5)
    )
    XCTAssertFalse(element("watch.touch-exchange.cancelled", in: app).exists)
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "不会开始新的交换")
      ).firstMatch.exists
    )

    let prematureNewCandidate = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true"),
      object: element("watch.touch-exchange.peer-card", in: app)
    )
    prematureNewCandidate.isInverted = true
    XCTAssertEqual(
      XCTWaiter.wait(for: [prematureNewCandidate], timeout: 0.8),
      .completed
    )

    let retryButton = app.buttons["watch.touch-exchange.retry"]
    scrollToElement(retryButton, in: app)
    retryButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.peer-card", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertFalse(
      element("watch.touch-exchange.cancel-unconfirmed", in: app).exists
    )
  }

  func testTouchExchangeServerCompletionWinsCancelConfirmRace() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-cancel-confirm-race",
      ]
    )

    openTouchExchange(in: app)
    let startButton = app.buttons["watch.touch-exchange.start"]
    scrollToElement(startButton, in: app)
    startButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.peer-card", in: app).waitForExistence(timeout: 5)
    )

    let confirmButton = app.buttons["watch.touch-exchange.confirm"]
    scrollToElement(confirmButton, in: app)
    confirmButton.tap()
    let cancelButton = app.buttons["watch.touch-exchange.cancel"]
    scrollToElement(cancelButton, in: app)
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
    cancelButton.tap()

    XCTAssertTrue(
      element("watch.touch-exchange.completed", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertFalse(element("watch.touch-exchange.cancelled", in: app).exists)
    let persistenceStatus = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "相遇记录已保存")
    ).firstMatch
    scrollToElement(persistenceStatus, in: app)
    XCTAssertTrue(persistenceStatus.waitForExistence(timeout: 5))
  }

  func testTouchExchangeAccessibilityAcrossConsentStates() throws {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: ["--touch-exchange-demo"]
    )

    openTouchExchange(in: app)
    try auditCurrentScreen(app)
    let startButton = app.buttons["watch.touch-exchange.start"]
    scrollToElement(startButton, in: app)
    startButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.peer-card", in: app).waitForExistence(timeout: 5)
    )
    try auditCurrentScreen(app)
    let confirmButton = app.buttons["watch.touch-exchange.confirm"]
    scrollToElement(confirmButton, in: app)
    confirmButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.completed", in: app).waitForExistence(timeout: 5)
    )
    try auditCurrentScreen(app)
    app.terminate()

    let peerFirstApp = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-peer-first",
      ]
    )
    openTouchExchange(in: peerFirstApp)
    let peerFirstStart = peerFirstApp.buttons["watch.touch-exchange.start"]
    scrollToElement(peerFirstStart, in: peerFirstApp)
    peerFirstStart.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.peer-first-message", in: peerFirstApp)
        .waitForExistence(timeout: 5)
    )
    try auditCurrentScreen(peerFirstApp)
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

  func testDefaultLaunchStartsWithMock1AndRemembersDemoSelection() {
    let storageID = "watch-default-demo"
    let app = launchDefaultApp(storageID: storageID, reset: true)

    XCTAssertTrue(element("watch.onboarding", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.mock-badge", in: app).label.contains("Mock 1"))
    XCTAssertFalse(element("watch.live-badge", in: app).exists)
    let onboardingButton = app.buttons["watch.onboarding.complete"]
    scrollToElement(onboardingButton, in: app)
    onboardingButton.tap()
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    let connectButton = app.buttons["watch.connect-health"]
    scrollToElement(connectButton, in: app)
    connectButton.tap()
    XCTAssertTrue(element("watch.data-source-picker", in: app).waitForExistence(timeout: 5))
    app.buttons["watch.data-source.option.mock2"].tap()
    XCTAssertTrue(
      element("watch.mock-badge", in: app).waitForExistence(timeout: 5)
        && element("watch.mock-badge", in: app).label.contains("Mock 2")
    )
    app.terminate()

    let relaunched = launchDefaultApp(storageID: storageID, reset: false)
    XCTAssertTrue(element("watch.pet-home", in: relaunched).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.mock-badge", in: relaunched).label.contains("Mock 2"))
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
    let storyStatus = element("watch.status-message", in: app)
    scrollToElement(storyStatus, in: app)
    XCTAssertTrue(
      waitForLabel("今日主线已推进，获得 10 点世界经验", on: storyStatus, timeout: 5)
    )

    let habitButton = app.buttons["watch.interact"]
    scrollToElement(habitButton, in: app)
    XCTAssertTrue(habitButton.isEnabled)
    habitButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let habitStatus = element("watch.status-message", in: app)
    scrollToElement(habitStatus, in: app)
    XCTAssertTrue(
      waitForLabel("今天的小行动已记下；奖励只结算一次", on: habitStatus, timeout: 5)
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
    let storyStatus = element("watch.status-message", in: app)
    scrollToElement(storyStatus, in: app)
    XCTAssertTrue(
      waitForLabel("今日主线已推进，获得 10 点世界经验", on: storyStatus, timeout: 5))

    let habitButton = app.buttons["watch.interact"]
    scrollToElement(habitButton, in: app)
    XCTAssertTrue(habitButton.exists)
    XCTAssertTrue(habitButton.isEnabled)
    habitButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let habitStatus = element("watch.status-message", in: app)
    scrollToElement(habitStatus, in: app)
    XCTAssertTrue(
      waitForLabel("今天的小行动已记下；奖励只结算一次", on: habitStatus, timeout: 5))
    app.terminate()

    let relaunched = launchLiveApp(storageID: storageID, reset: false)
    XCTAssertTrue(element("watch.pet-home", in: relaunched).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.status-message", in: relaunched).waitForExistence(timeout: 8))
    let repeatedStoryButton = relaunched.buttons["watch.advance-story"]
    scrollToElement(repeatedStoryButton, in: relaunched)
    repeatedStoryButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let repeatedStoryStatus = element("watch.status-message", in: relaunched)
    scrollToElement(repeatedStoryStatus, in: relaunched)
    XCTAssertTrue(
      waitForLabel("今天的主线已经完成，明天继续", on: repeatedStoryStatus, timeout: 5))

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
      XCTAssertTrue(button.exists)
      button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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

  private func openTouchExchange(in app: XCUIApplication) {
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    let exchangeLink = app.buttons["watch.open-touch-exchange"]
    scrollToElement(exchangeLink, in: app)
    XCTAssertTrue(exchangeLink.exists)
    exchangeLink.tap()
    XCTAssertTrue(element("watch.touch-exchange", in: app).waitForExistence(timeout: 5))
  }

  private func completeTouchExchange(in app: XCUIApplication) {
    openTouchExchange(in: app)
    let startButton = app.buttons["watch.touch-exchange.start"]
    scrollToElement(startButton, in: app)
    startButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.peer-card", in: app)
        .waitForExistence(timeout: 5)
    )
    let confirmButton = app.buttons["watch.touch-exchange.confirm"]
    scrollToElement(confirmButton, in: app)
    confirmButton.tap()
    XCTAssertTrue(
      element("watch.touch-exchange.completed", in: app)
        .waitForExistence(timeout: 5)
    )
  }

  private func launchLiveApp(
    storageID: String,
    reset: Bool,
    additionalArguments: [String] = []
  ) -> XCUIApplication {
    launchDefaultApp(
      storageID: storageID,
      reset: reset,
      additionalArguments: ["--e2e-data-source=healthKit"] + additionalArguments
    )
  }

  private func launchDefaultApp(
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

    for _ in 0..<12 {
      let scrollSurface = scrollView.exists ? scrollView : app
      var visibleFrame = scrollSurface.frame.insetBy(dx: 0, dy: 8)
      // On 40 mm watches, an element can be geometrically visible while its center remains
      // inside the system-owned status region. Keep synthesized taps below that boundary.
      visibleFrame.origin.y += 42
      visibleFrame.size.height -= 42

      if element.exists {
        let elementCenter = CGPoint(x: element.frame.midX, y: element.frame.midY)
        if visibleFrame.contains(elementCenter) {
          return
        }

        if elementCenter.y < visibleFrame.minY - scrollSurface.frame.height {
          scrollSurface.swipeDown()
        } else if elementCenter.y > visibleFrame.maxY + scrollSurface.frame.height {
          scrollSurface.swipeUp()
        } else if elementCenter.y < visibleFrame.minY {
          rotateDigitalCrown(delta: -0.3)
        } else {
          rotateDigitalCrown(delta: 0.3)
        }
      } else {
        rotateDigitalCrown(delta: 0.3)
      }
    }
  }

  private func rotateDigitalCrown(delta: CGFloat) {
    XCUIDevice.shared.rotateDigitalCrown(delta: delta, velocity: 0.5)
  }

  private func waitForLabel(
    _ expectedLabel: String,
    on element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let predicate = NSPredicate(format: "label == %@", expectedLabel)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
