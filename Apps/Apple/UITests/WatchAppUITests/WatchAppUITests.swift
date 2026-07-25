import XCTest

final class WatchAppUITests: XCTestCase {
  private var sharedTransferEventID: String {
    ProcessInfo.processInfo.environment["SOCIAL_TRANSFER_E2E_EVENT_ID"]
      ?? "0123456789abcdef0123456789abcdef"
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testHomeIsAnImmersiveCompanionSurface() {
    let app = launchApp(scenario: "mock1")

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.home.sleep", in: app).label.contains("7小时30分"))
    XCTAssertTrue(element("watch.home.steps", in: app).label.contains("3,250步"))
    XCTAssertTrue(app.buttons["watch.open-companion-settings"].exists)
    XCTAssertFalse(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "Lv.")
      ).firstMatch.exists)
    XCTAssertFalse(element("watch.today.recommendation", in: app).exists)

    let scene = app.buttons["watch.pet-home"]
    XCTAssertTrue(scene.exists)
    XCTAssertEqual(scene.value as? String, "企鹅伙伴，春日花溪")
    scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(element("watch.event-bubble", in: app).waitForExistence(timeout: 2))
  }

  func testNewestFreshGlanceReplacesOlderEventAndExpiredEventStaysQuiet() {
    let app = launchApp(
      scenario: "mock1",
      additionalArguments: ["--mock-glance=shared-walk,paused"]
    )
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    let bubble = element("watch.event-bubble", in: app)
    XCTAssertTrue(bubble.waitForExistence(timeout: 3))
    XCTAssertTrue(bubble.label.contains("我也坐了一会儿"))
    XCTAssertFalse(bubble.label.contains("3,250"))
    app.terminate()

    let expired = launchApp(
      scenario: "mock1",
      additionalArguments: [
        "--mock-glance=fast-pace",
        "--mock-glance-age=121",
      ]
    )
    XCTAssertTrue(element("watch.pet-home", in: expired).waitForExistence(timeout: 8))
    XCTAssertFalse(element("watch.event-bubble", in: expired).waitForExistence(timeout: 1))
  }

  func testMockGlanceIsPresentedAtMostOnceAcrossRelaunch() {
    let storageID = "glance-once-\(UUID().uuidString)"
    let arguments = [
      "--mock-scenario=mock1",
      "--mock-glance=shared-walk",
    ]
    let first = launchDefaultApp(
      storageID: storageID,
      reset: true,
      additionalArguments: arguments
    )
    XCTAssertTrue(element("watch.pet-home", in: first).waitForExistence(timeout: 8))
    XCTAssertTrue(
      element("watch.event-bubble", in: first).waitForExistence(timeout: 3)
    )
    first.terminate()

    let relaunched = launchDefaultApp(
      storageID: storageID,
      reset: false,
      additionalArguments: arguments
    )
    XCTAssertTrue(
      element("watch.pet-home", in: relaunched).waitForExistence(timeout: 8)
    )
    XCTAssertFalse(
      element("watch.event-bubble", in: relaunched).waitForExistence(timeout: 1)
    )
  }

  func testReplacedAndExpiredMockGlancesStayTerminalAcrossRelaunch() {
    let replacedStorageID = "glance-replaced-\(UUID().uuidString)"
    let replaced = launchDefaultApp(
      storageID: replacedStorageID,
      reset: true,
      additionalArguments: [
        "--mock-scenario=mock1",
        "--mock-glance=shared-walk,paused",
      ]
    )
    XCTAssertTrue(element("watch.event-bubble", in: replaced).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.event-bubble", in: replaced).label.contains("坐了一会儿"))
    replaced.terminate()

    let oldEvent = launchDefaultApp(
      storageID: replacedStorageID,
      reset: false,
      additionalArguments: [
        "--mock-scenario=mock1",
        "--mock-glance=shared-walk",
      ]
    )
    XCTAssertTrue(element("watch.pet-home", in: oldEvent).waitForExistence(timeout: 8))
    XCTAssertFalse(element("watch.event-bubble", in: oldEvent).waitForExistence(timeout: 1))
    oldEvent.terminate()

    let expiredStorageID = "glance-expired-\(UUID().uuidString)"
    let expired = launchDefaultApp(
      storageID: expiredStorageID,
      reset: true,
      additionalArguments: [
        "--mock-scenario=mock1",
        "--mock-glance=fast-pace",
        "--mock-glance-age=121",
      ]
    )
    XCTAssertTrue(element("watch.pet-home", in: expired).waitForExistence(timeout: 8))
    XCTAssertFalse(element("watch.event-bubble", in: expired).waitForExistence(timeout: 1))
    expired.terminate()

    let revived = launchDefaultApp(
      storageID: expiredStorageID,
      reset: false,
      additionalArguments: [
        "--mock-scenario=mock1",
        "--mock-glance=fast-pace",
      ]
    )
    XCTAssertTrue(element("watch.pet-home", in: revived).waitForExistence(timeout: 8))
    XCTAssertFalse(element("watch.event-bubble", in: revived).waitForExistence(timeout: 1))
  }

  func testRealModeDoesNotClaimCompanionRuntimeIsAvailable() {
    let app = launchLiveApp(
      storageID: "real-companion-boundary-\(UUID().uuidString)",
      reset: true
    )
    XCTAssertTrue(element("watch.onboarding", in: app).waitForExistence(timeout: 8))
    let complete = app.buttons["watch.onboarding.complete"]
    scrollToElement(complete, in: app)
    complete.tap()
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(
      app.buttons["watch.open-companion-settings"].label.contains("待连接")
    )
    app.buttons["watch.open-companion-settings"].tap()
    XCTAssertTrue(
      element("watch.companion-settings", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.staticTexts["真实随行感知尚未连接"].exists)
    XCTAssertFalse(element("watch.companion.sensing", in: app).exists)
  }

  func testCompanionSettingsExplainReminderBehavior() {
    let app = launchApp(scenario: "mock1")
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    app.buttons["watch.open-companion-settings"].tap()

    XCTAssertTrue(
      element("watch.companion-settings", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertTrue(element("watch.companion.sensing", in: app).exists)
    XCTAssertTrue(element("watch.companion.reminder.wristRaise", in: app).exists)
    let gentleHaptic = element("watch.companion.reminder.gentleHaptic", in: app)
    scrollToElement(gentleHaptic, in: app)
    XCTAssertTrue(gentleHaptic.exists)
    gentleHaptic.tap()
    XCTAssertTrue(
      gentleHaptic.isSelected
    )
  }

  func testCompanionPreferencesPersistAcrossRelaunch() {
    let storageID = "companion-preferences-\(UUID().uuidString)"
    let first = launchDefaultApp(storageID: storageID, reset: true)
    XCTAssertTrue(element("watch.onboarding", in: first).waitForExistence(timeout: 8))
    let onboarding = first.buttons["watch.onboarding.complete"]
    scrollToElement(onboarding, in: first)
    onboarding.tap()
    XCTAssertTrue(element("watch.pet-home", in: first).waitForExistence(timeout: 8))
    first.buttons["watch.open-companion-settings"].tap()

    let sensing = element("watch.companion.sensing", in: first)
    XCTAssertTrue(sensing.waitForExistence(timeout: 5))
    sensing.tap()
    let gentle = element("watch.companion.reminder.gentleHaptic", in: first)
    scrollToElement(gentle, in: first)
    gentle.tap()
    XCTAssertTrue(
      waitForValue(
        "已保存",
        on: element("watch.companion-settings", in: first),
        timeout: 3
      )
    )
    first.terminate()

    let relaunched = launchDefaultApp(storageID: storageID, reset: false)
    XCTAssertTrue(
      element("watch.pet-home", in: relaunched).waitForExistence(timeout: 8)
    )
    XCTAssertTrue(
      relaunched.buttons["watch.open-companion-settings"].label.contains("已关闭")
    )
    relaunched.buttons["watch.open-companion-settings"].tap()
    let persistedGentle = element(
      "watch.companion.reminder.gentleHaptic",
      in: relaunched
    )
    scrollToElement(persistedGentle, in: relaunched)
    XCTAssertTrue(persistedGentle.isSelected)
  }

  func testTodayHighlightsOneControllableRecommendationWithoutRewardingHealth() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: ["--watch-route=today"]
    )
    XCTAssertTrue(element("watch.today", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.today.recommendation", in: app).exists)
    XCTAssertEqual(element("watch.today.reward", in: app).label, "奖励 1 枚金币")
    XCTAssertEqual(
      element("watch.today.balance", in: app).label,
      "金币余额 18"
    )
    XCTAssertFalse(
      element("watch.today.detected-walk", in: app).label.contains("奖励")
    )
    let complete = app.buttons["watch.today.complete-recommendation"]
    XCTAssertTrue(complete.exists)
    complete.tap()
    XCTAssertTrue(waitForLabel("已经记下", on: complete, timeout: 3))
    XCTAssertEqual(
      element("watch.today.balance", in: app).label,
      "金币余额 19"
    )
  }

  func testMockTaskRewardSettlesOnceAcrossRelaunch() {
    let storageID = "task-once-\(UUID().uuidString)"
    let arguments = [
      "--mock-scenario=activity_high",
      "--watch-route=today",
    ]
    let first = launchDefaultApp(
      storageID: storageID,
      reset: true,
      additionalArguments: arguments
    )
    let complete = first.buttons["watch.today.complete-recommendation"]
    XCTAssertTrue(complete.waitForExistence(timeout: 8))
    complete.tap()
    XCTAssertTrue(waitForLabel("已经记下", on: complete, timeout: 3))
    first.terminate()

    let relaunched = launchDefaultApp(
      storageID: storageID,
      reset: false,
      additionalArguments: arguments
    )
    let settled = relaunched.buttons["watch.today.complete-recommendation"]
    XCTAssertTrue(settled.waitForExistence(timeout: 8))
    XCTAssertEqual(settled.label, "已经记下")
    XCTAssertFalse(settled.isEnabled)
    XCTAssertEqual(
      element("watch.today.balance", in: relaunched).label,
      "金币余额 19"
    )
  }

  func testResetMockCreatesFreshTaskAndCoinNamespace() {
    let storageID = "task-reset-\(UUID().uuidString)"
    let first = launchDefaultApp(
      storageID: storageID,
      reset: true,
      additionalArguments: [
        "--e2e-data-source=mock3",
        "--watch-route=today",
      ]
    )
    let complete = first.buttons[
      "watch.today.complete-recommendation"
    ]
    if element("watch.onboarding", in: first)
      .waitForExistence(timeout: 3)
    {
      let onboarding = first.buttons["watch.onboarding.complete"]
      scrollToElement(onboarding, in: first)
      onboarding.tap()
    }
    XCTAssertTrue(complete.waitForExistence(timeout: 8))
    complete.tap()
    XCTAssertTrue(waitForLabel("已经记下", on: complete, timeout: 3))
    XCTAssertEqual(
      element("watch.today.balance", in: first).label,
      "金币余额 19"
    )
    first.terminate()

    let settings = launchDefaultApp(
      storageID: storageID,
      reset: false,
      additionalArguments: ["--watch-route=settings"]
    )
    XCTAssertTrue(
      element("watch.settings", in: settings)
        .waitForExistence(timeout: 8)
    )
    let reset = settings.buttons["watch.settings.reset-mock"]
    scrollToElement(reset, in: settings)
    XCTAssertTrue(reset.isEnabled)
    reset.tap()
    settings.terminate()

    let fresh = launchDefaultApp(
      storageID: storageID,
      reset: false,
      additionalArguments: ["--watch-route=today"]
    )
    let freshTask = fresh.buttons[
      "watch.today.complete-recommendation"
    ]
    XCTAssertTrue(freshTask.waitForExistence(timeout: 8))
    XCTAssertEqual(freshTask.label, "完成这件事")
    XCTAssertTrue(freshTask.isEnabled)
    XCTAssertEqual(
      element("watch.today.balance", in: fresh).label,
      "金币余额 18"
    )
  }

  func testDailyMemoryUsesStoryCopyAndKnownFacts() {
    let app = launchApp(
      scenario: "mock1",
      additionalArguments: ["--watch-route=dailyMemory"]
    )
    XCTAssertTrue(element("watch.daily-memory", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["今天，我们一起……"].exists)
    XCTAssertTrue(app.staticTexts["Mock 回忆预览"].exists)
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "3,250步")
      ).firstMatch.exists)
  }

  func testSevenDayScenarioRendersTrendChart() {
    let app = launchApp(scenario: "mock7_rhythm")

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("watch.mock-badge", in: app).label.contains("35 日 · 节律旅程"))
    let trendLink = app.buttons["watch.open-trends"]
    scrollToElement(trendLink, in: app)
    trendLink.tap()
    XCTAssertTrue(element("watch.trends", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("watch.trend-chart", in: app).exists)
    XCTAssertFalse(element("watch.trend-empty", in: app).exists)
  }

  func testTouchExchangeAutomaticallyStartsWithoutPhoneSettings() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: ["--touch-exchange-demo"]
    )

    XCTAssertTrue(
      element("watch.touch-exchange", in: app).waitForExistence(timeout: 8)
    )
    XCTAssertFalse(app.buttons["watch.touch-exchange.start"].exists)
    XCTAssertTrue(
      element("watch.touch-exchange.completed", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 9))
  }

  func testTouchExchangeRespectsExplicitSharingOptOut() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: ["--touch-exchange-sharing-disabled"]
    )

    openTouchExchange(in: app)
    let sharingGate = element("watch.touch-exchange.sharing-gate", in: app)
    scrollToElement(sharingGate, in: app)
    XCTAssertTrue(sharingGate.label.contains("好友分享已关闭"))
    XCTAssertTrue(sharingGate.label.contains("不会上传公开宠物卡"))

    let startButton = app.buttons["watch.touch-exchange.start"]
    scrollToElement(startButton, in: app)
    XCTAssertEqual(startButton.label, "好友分享已关闭")
    XCTAssertFalse(startButton.isEnabled)
    XCTAssertFalse(element("watch.touch-exchange.progress", in: app).exists)
  }

  func testTouchExchangeUnavailableCapabilityDoesNotLoopOnCleanup() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: ["--touch-exchange-capability-unavailable"]
    )

    openTouchExchange(in: app)
    let failedState = element("watch.touch-exchange.failed", in: app)
    XCTAssertTrue(failedState.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["这块手表不支持精确近距离测量"].waitForExistence(timeout: 2)
    )
    XCTAssertFalse(element("watch.touch-exchange.cancel-unconfirmed", in: app).exists)

    let retryButton = app.buttons["watch.touch-exchange.retry"]
    scrollToElement(retryButton, in: app)
    retryButton.tap()

    let cancellationLoop = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true"),
      object: element("watch.touch-exchange.cancel-unconfirmed", in: app)
    )
    cancellationLoop.isInverted = true
    XCTAssertEqual(
      XCTWaiter.wait(for: [cancellationLoop], timeout: 1),
      .completed
    )
    XCTAssertTrue(failedState.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["这块手表不支持精确近距离测量"].waitForExistence(timeout: 2)
    )
    XCTAssertFalse(element("watch.touch-exchange.cancel-unconfirmed", in: app).exists)
  }

  func testTouchExchangeDemoAutomaticallyCompletesAfterProximity() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-social-state=walk",
      ]
    )

    openTouchExchange(in: app)
    XCTAssertEqual(app.textFields.count, 0)
    XCTAssertTrue(
      element("watch.touch-exchange.completed", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertFalse(app.buttons["watch.touch-exchange.start"].exists)
    XCTAssertFalse(app.buttons["watch.touch-exchange.confirm"].exists)
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

  func testTouchExchangePeerFirstAutomaticallyConfirmsLocally() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-peer-first",
      ]
    )

    openTouchExchange(in: app)
    XCTAssertTrue(
      element("watch.touch-exchange.completed", in: app)
        .waitForExistence(timeout: 5)
    )
    XCTAssertFalse(app.buttons["watch.touch-exchange.confirm"].exists)
  }

  func testTouchExchangeCancellationIgnoresOldDemoCallbacks() {
    let app = launchApp(
      scenario: "activity_high",
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-manual-confirm",
      ]
    )

    openTouchExchange(in: app)
    let cancelButton = app.buttons["watch.touch-exchange.cancel"]
    scrollToElement(cancelButton, in: app)
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
    cancelButton.tap()

    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 5))
    openTouchExchange(in: app)
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
        "--touch-exchange-direct",
        "--touch-exchange-manual-confirm",
      ]
    )

    openTouchExchange(in: app)
    XCTAssertTrue(
      element("watch.touch-exchange.peer-card", in: app).waitForExistence(timeout: 5)
    )

    let cancelButton = app.buttons["watch.touch-exchange.cancel"]
    scrollToElement(cancelButton, in: app)
    rotateDigitalCrown(delta: 0.2)
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
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
        "--touch-exchange-manual-confirm",
      ]
    )

    openTouchExchange(in: app)
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
      additionalArguments: [
        "--touch-exchange-demo",
        "--touch-exchange-manual-confirm",
      ]
    )

    openTouchExchange(in: app)
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
        "--touch-exchange-manual-confirm",
      ]
    )
    openTouchExchange(in: peerFirstApp)
    XCTAssertTrue(
      element("watch.touch-exchange.peer-first-message", in: peerFirstApp)
        .waitForExistence(timeout: 5)
    )
    try auditCurrentScreen(peerFirstApp)
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
    openSettings(in: app)
    let dataMode = app.buttons["watch.settings.open-data-mode"]
    scrollToElement(dataMode, in: app)
    dataMode.tap()
    XCTAssertTrue(element("watch.data-mode", in: app).waitForExistence(timeout: 5))
    app.buttons["watch.data-mode.mock2"].tap()
    XCTAssertTrue(app.buttons["watch.data-mode.mock2"].isSelected)
    app.terminate()

    let relaunched = launchDefaultApp(storageID: storageID, reset: false)
    XCTAssertTrue(element("watch.pet-home", in: relaunched).waitForExistence(timeout: 8))
    openSettings(in: relaunched)
    let relaunchedDataMode = relaunched.buttons["watch.settings.open-data-mode"]
    scrollToElement(relaunchedDataMode, in: relaunched)
    relaunchedDataMode.tap()
    XCTAssertTrue(element("watch.data-mode", in: relaunched).waitForExistence(timeout: 5))
    XCTAssertTrue(relaunched.buttons["watch.data-mode.mock2"].isSelected)
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
    XCTAssertEqual(element("watch.home.sleep", in: app).label, "睡眠待记录")
    XCTAssertEqual(element("watch.home.steps", in: app).label, "步数待记录")
    let scene = app.buttons["watch.pet-home"]
    scene.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
    ).tap()
    let invalidBubble = element("watch.event-bubble", in: app)
    XCTAssertTrue(invalidBubble.waitForExistence(timeout: 3))
    XCTAssertTrue(invalidBubble.label.contains("Mock 场景无效"))
    app.terminate()

    let today = launchApp(
      scenario: "not_allowlisted",
      additionalArguments: ["--watch-route=today"]
    )
    XCTAssertTrue(
      element("watch.today", in: today).waitForExistence(timeout: 8)
    )
    XCTAssertFalse(
      element("watch.today.recommendation", in: today).exists
    )
    XCTAssertEqual(
      element("watch.today.balance", in: today).label,
      "金币余额 0"
    )
  }

  func testNotificationRouteOpensAQuietMessageAndReturnsHome() {
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
  }

  func testAccessibilityAuditAcrossPrimarySurfaces() throws {
    let app = launchApp(scenario: "mock1")
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    try auditCurrentScreen(app)

    app.buttons["watch.open-companion-settings"].tap()
    XCTAssertTrue(
      element("watch.companion-settings", in: app).waitForExistence(timeout: 5)
    )
    try auditCurrentScreen(app)
    app.navigationBars.buttons.firstMatch.tap()

    let memory = launchApp(
      scenario: "mock1",
      additionalArguments: ["--watch-route=dailyMemory"]
    )
    XCTAssertTrue(element("watch.daily-memory", in: memory).waitForExistence(timeout: 8))
    try auditCurrentScreen(memory)
  }

  func testAccessibilityAuditAcrossTodaySettingsLettersAndLongPressMenu() throws {
    let destinations: [(route: String, identifier: String)] = [
      ("today", "watch.today"),
      ("settings", "watch.settings"),
      ("letters", "watch.messages"),
    ]
    for destination in destinations {
      let app = launchApp(
        scenario: "mock1",
        additionalArguments: ["--watch-route=\(destination.route)"]
      )
      XCTAssertTrue(
        element(destination.identifier, in: app).waitForExistence(timeout: 8)
      )
      try auditCurrentScreen(app)
      app.terminate()
    }

    let menu = launchApp(scenario: "mock1")
    let scene = menu.buttons["watch.pet-home"]
    XCTAssertTrue(scene.waitForExistence(timeout: 8))
    scene.press(forDuration: 0.8)
    XCTAssertTrue(menu.buttons["今天"].waitForExistence(timeout: 3))
    try auditCurrentScreen(menu)
  }

  private func launchApp(
    scenario: String,
    additionalArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    let storageID = "fixture-\(UUID().uuidString)"
    app.launchArguments =
      [
        "-UITesting",
        "--mock-scenario=\(scenario)",
        "--e2e-storage-id=\(storageID)",
        "--e2e-offline-runtime",
        "--reset-e2e-storage",
      ] + additionalArguments
    app.launch()
    return app
  }

  private func openTouchExchange(in app: XCUIApplication) {
    if element("watch.touch-exchange", in: app).waitForExistence(timeout: 1) {
      return
    }
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    let scene = app.buttons["watch.pet-home"]
    XCTAssertTrue(scene.exists)
    scene.press(forDuration: 0.8)
    let exchangeLink = app.buttons["碰一碰"]
    XCTAssertTrue(exchangeLink.waitForExistence(timeout: 3))
    exchangeLink.tap()
    XCTAssertTrue(element("watch.touch-exchange", in: app).waitForExistence(timeout: 5))
  }

  private func completeTouchExchange(in app: XCUIApplication) {
    openTouchExchange(in: app)
    XCTAssertTrue(
      element("watch.touch-exchange.completed", in: app)
        .waitForExistence(timeout: 5)
    )
  }

  private func openSettings(in app: XCUIApplication) {
    XCTAssertTrue(element("watch.pet-home", in: app).waitForExistence(timeout: 8))
    let scene = app.buttons["watch.pet-home"]
    XCTAssertTrue(scene.exists)
    scene.press(forDuration: 0.8)
    let settings = app.buttons["设置"]
    XCTAssertTrue(settings.waitForExistence(timeout: 3))
    settings.tap()
    XCTAssertTrue(element("watch.settings", in: app).waitForExistence(timeout: 5))
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

  private func waitForValue(
    _ expectedValue: String,
    on element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let predicate = NSPredicate(format: "value == %@", expectedValue)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
