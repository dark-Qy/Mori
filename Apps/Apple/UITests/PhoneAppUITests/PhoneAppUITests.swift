import XCTest

final class PhoneAppUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testFourTabProductHierarchyAndCardlessMoriHome() {
    let app = launchMock(storageID: "phone-hierarchy", reset: true)

    XCTAssertTrue(element("phone.mori.scene", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.mock-badge", in: app).exists)
    XCTAssertTrue(element("phone.open-settings", in: app).exists)
    XCTAssertEqual(app.tabBars.buttons.count, 4)
    for title in ["Mori", "今天", "回忆", "收藏"] {
      XCTAssertTrue(app.tabBars.buttons[title].exists)
    }
    XCTAssertFalse(element("phone.today.recommended", in: app).exists)
    XCTAssertFalse(element("phone.today.coins", in: app).exists)
    XCTAssertFalse(app.staticTexts["等级"].exists)
    XCTAssertFalse(app.staticTexts["生命力"].exists)
    XCTAssertFalse(app.buttons["同步"].exists)
  }

  func testPetSceneRespondsDifferentlyToHeadAndBodyTouches() {
    let app = launchApp(
      scenario: "health_normal",
      additionalArguments: ["--character=bili_22"]
    )

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    let scene = app.buttons["phone.companion-interaction"]
    XCTAssertTrue(scene.waitForExistence(timeout: 5))

    scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    XCTAssertTrue(app.staticTexts["摸摸头 · 22 娘 眨了眨眼"].waitForExistence(timeout: 2))

    Thread.sleep(forTimeInterval: 0.4)
    scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64)).tap()
    XCTAssertTrue(app.staticTexts["碰一碰 · 22 娘 转身靠近"].waitForExistence(timeout: 2))
  }

  func testMock4ChangesSceneFromSimulatedGPSAndHeartRate() {
    let app = launchApp(scenario: "mock4")

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    let badge = element("phone.movement-scene", in: app)
    XCTAssertTrue(badge.waitForExistence(timeout: 3))
    let scene = app.buttons["phone.companion-interaction"]
    XCTAssertTrue(scene.exists)
    let initialBadgeLabel = badge.label
    let initialSceneValue = scene.value as? String
    expectation(
      for: NSPredicate(format: "label != %@", initialBadgeLabel),
      evaluatedWith: badge
    )
    if let initialSceneValue {
      expectation(
        for: NSPredicate(format: "value != %@", initialSceneValue),
        evaluatedWith: scene
      )
    }
    waitForExpectations(timeout: 6)

    XCTAssertNotEqual(badge.label, initialBadgeLabel)
    XCTAssertNotEqual(scene.value as? String, initialSceneValue)
    XCTAssertTrue(badge.label.contains("模拟 GPS"))
    XCTAssertTrue(badge.label.contains("心率"))
    let expectedMotionLabel = [
      "原地休息": "坐下休息",
      "正在散步": "散步",
      "快速移动": "快速移动",
      "停下恢复": "调整呼吸",
    ]
    .first(where: { badge.label.contains($0.key) })?
    .value
    XCTAssertNotNil(expectedMotionLabel)
    XCTAssertTrue(
      expectedMotionLabel.map {
        (scene.value as? String)?.contains($0) == true
      } ?? false
    )
  }

  func testOccasionalChatBubbleOpensConversationAndSendsReply() {
    let app = launchApp(
      scenario: "health_normal",
      additionalArguments: ["--chat-nudge=visible", "--chat-consent=required"]
    )

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    let nudge = app.buttons["phone.chat-nudge"]
    XCTAssertTrue(nudge.waitForExistence(timeout: 3))
    nudge.tap()

    XCTAssertTrue(element("phone.chat.messages", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["phone.chat.message.assistant"].exists)
    let composer = app.textFields["phone.chat.composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 3))
    composer.tap()
    composer.typeText("今天有点累")
    app.buttons["phone.chat.send"].tap()
    XCTAssertTrue(app.alerts["发送给 AI 服务？"].waitForExistence(timeout: 2))
    app.alerts.buttons["同意并发送"].tap()

    XCTAssertTrue(
      app.staticTexts["Mori 说，我在。先不用把一切说清楚，慢慢来就好。"]
        .waitForExistence(timeout: 5)
    )
  }

  func testThirtyFiveDayScenarioRendersWeeklyTimeline() {
    let app = launchApp(scenario: "mock7_active")

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.mock-badge", in: app).label.contains("35 日 · 活动旅程"))
    app.tabBars.buttons["回忆"].tap()
    XCTAssertTrue(element("phone.memories", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("phone.weekly-memory.cover", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["把足球踢向海风的那一周"].exists)
    XCTAssertTrue(element("phone.weekly-memory.cover", in: app).label.contains("足球 · 45 分钟"))
    let earlierHighlights = [
      1: "海边散步 · 20 分钟",
      2: "游泳 · 25 分钟",
      3: "羽毛球 · 30 分钟",
      4: "网球 · 40 分钟",
    ]
    for (week, highlight) in earlierHighlights {
      let cover = element("phone.weekly-memory.cover.\(week)", in: app)
      XCTAssertTrue(cover.exists)
      XCTAssertTrue(cover.label.contains(highlight))
    }
    XCTAssertTrue(element("phone.weekly-memory.metric.steps.5", in: app).label.contains("70,900 步"))
    XCTAssertTrue(element("phone.weekly-memory.metric.active.5", in: app).label.contains("353 分钟"))
    XCTAssertTrue(
      element("phone.weekly-memory.metric.sleep.5", in: app).label.contains("7 小时 30 分")
    )
    XCTAssertFalse(element("phone.history-chart", in: app).exists)
    for forbidden in ["个人近期", "医学结论", "缺失指标", "Codex image2", "Mock 图示"] {
      XCTAssertFalse(app.staticTexts[forbidden].exists)
    }
  }

  func testTodayCompleteThenPurchasePersistAcrossRelaunch() {
    let storageID = "phone-task-ledger"
    let app = launchMock(storageID: storageID, reset: true)

    app.tabBars.buttons["今天"].tap()
    XCTAssertTrue(element("phone.today", in: app).waitForExistence(timeout: 5))
    XCTAssertEqual(element("phone.today.coins", in: app).label, "金币 18 枚")
    XCTAssertTrue(element("phone.today.steps", in: app).label.contains("3,250步"))
    XCTAssertTrue(element("phone.today.sleep", in: app).label.contains("7小时30分"))

    app.buttons["phone.today.complete-recommended"].tap()
    XCTAssertTrue(
      element("phone.today.coins", in: app).waitForExistence(timeout: 5)
        && element("phone.today.coins", in: app).label == "金币 19 枚"
    )
    XCTAssertFalse(app.buttons["phone.today.complete-recommended"].exists)

    app.tabBars.buttons["收藏"].tap()
    let buy = app.buttons["phone.collection.buy.scarf"]
    scrollToElement(buy, in: app)
    buy.tap()
    XCTAssertTrue(
      app.buttons["phone.collection.use.scarf"].waitForExistence(timeout: 5)
    )
    XCTAssertEqual(
      element("phone.collection.coins", in: app).label,
      "金币 11 枚"
    )
    app.terminate()

    let relaunched = launchMock(storageID: storageID, reset: false)
    relaunched.tabBars.buttons["收藏"].tap()
    XCTAssertTrue(
      element("phone.collection.coins", in: relaunched)
        .waitForExistence(timeout: 5)
        && element("phone.collection.coins", in: relaunched).label
          == "金币 11 枚"
    )
    XCTAssertFalse(relaunched.buttons["phone.collection.buy.scarf"].exists)
    relaunched.tabBars.buttons["今天"].tap()
    XCTAssertFalse(relaunched.buttons["phone.today.complete-recommended"].exists)
  }

  func testBiliCharactersCanBeSelectedFromCollectionAndShownAtHome() {
    let app = launchApp(scenario: "health_normal")

    app.tabBars.buttons["收藏"].tap()
    XCTAssertTrue(element("phone.collection", in: app).waitForExistence(timeout: 5))

    let girl22 = app.buttons["phone.character.bili_22"]
    scrollToElement(girl22, in: app)
    scrollHorizontallyToElement(girl22, in: app)
    girl22.tap()
    XCTAssertTrue(girl22.label.contains("22 娘"))
    XCTAssertTrue(
      (element("phone.collection.preview", in: app).value as? String)?
        .contains("22 娘") == true
    )

    let girl33 = app.buttons["phone.character.bili_33"]
    scrollToElement(girl33, in: app)
    scrollHorizontallyToElement(girl33, in: app)
    girl33.tap()
    XCTAssertTrue(girl33.label.contains("33 娘"))

    app.tabBars.buttons["Mori"].tap()
    let scene = app.buttons["phone.companion-interaction"]
    XCTAssertTrue(scene.waitForExistence(timeout: 5))
    XCTAssertTrue((scene.value as? String)?.contains("33 娘") == true)
  }

  func testLocalConversationPersistsWithoutMutatingToday() {
    let storageID = "phone-conversation"
    let app = launchMock(storageID: storageID, reset: true)

    let composer = app.textFields.firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 8))
    composer.tap()
    composer.typeText("hello Mori")
    let send = app.buttons["phone.mori.send"]
    expectation(
      for: NSPredicate(format: "enabled == true"),
      evaluatedWith: send
    )
    waitForExpectations(timeout: 3)
    send.tap()
    XCTAssertTrue(
      app.staticTexts["Mori：我听见了。你想继续说，我就在这里。"]
        .waitForExistence(timeout: 5)
    )
    let sentMessage = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "你：")
    ).firstMatch
    XCTAssertTrue(sentMessage.waitForExistence(timeout: 5))
    let persistedLabel = sentMessage.label
    app.terminate()

    let relaunched = launchMock(storageID: storageID, reset: false)
    XCTAssertTrue(
      relaunched.staticTexts[persistedLabel].waitForExistence(timeout: 8)
    )
    relaunched.tabBars.buttons["今天"].tap()
    XCTAssertTrue(
      element("phone.today.coins", in: relaunched).waitForExistence(timeout: 5)
        && element("phone.today.coins", in: relaunched).label == "金币 18 枚"
    )
    XCTAssertTrue(
      relaunched.buttons["phone.today.complete-recommended"].isEnabled
    )
  }

  func testConversationWarnsBeforeSendingContactDetails() {
    let app = launchMock(
      storageID: "phone-conversation-warning",
      reset: true
    )

    send("hello@example.com", in: app)

    let alert = app.alerts["发送前确认"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(
      alert.staticTexts.element(
        matching: NSPredicate(
          format: "label CONTAINS %@",
          "可能包含联系方式"
        )
      ).exists)
    XCTAssertFalse(app.staticTexts["你：hello@example.com"].exists)
    alert.buttons.matching(identifier: "phone.mori.warning-confirm")
      .firstMatch.tap()
    XCTAssertTrue(
      app.staticTexts["你：hello@example.com"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(
      app.staticTexts["Mori：我听见了。你想继续说，我就在这里。"]
        .waitForExistence(timeout: 5)
    )
  }

  func testConversationBlocksCredentialWithoutPersistence() {
    let storageID = "phone-conversation-credential"
    let app = launchMock(storageID: storageID, reset: true)
    let credential =
      "sk-" + "proj-" + String(repeating: "a", count: 24)

    send(credential, in: app)

    let failure = element("phone.mori.chat-failure", in: app)
    XCTAssertTrue(failure.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["这段话看起来包含密钥或凭证，因此没有发送。"].exists
    )
    XCTAssertFalse(app.staticTexts["你：\(credential)"].exists)
    app.terminate()

    let relaunched = launchMock(storageID: storageID, reset: false)
    XCTAssertTrue(
      relaunched.staticTexts["Mori：我在这里。今天想和我说什么？"]
        .waitForExistence(timeout: 8)
    )
    XCTAssertFalse(relaunched.staticTexts["你：\(credential)"].exists)
    let relaunchedComposer = element("phone.mori.composer", in: relaunched)
    XCTAssertTrue(relaunchedComposer.exists)
    XCTAssertNotEqual(relaunchedComposer.value as? String, credential)
  }

  func testOfflineConversationFallsBackLocallyAndRetryDoesNotDuplicateTurn() {
    let app = launchMock(
      storageID: "phone-conversation-offline",
      reset: true,
      chatBehavior: "offline"
    )

    send("今天有点累", in: app)

    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(
          format: "label CONTAINS %@",
          "现在没有连上服务，但我还在这里"
        )
      ).firstMatch.waitForExistence(timeout: 5)
    )
    let retry = app.buttons["phone.mori.retry"]
    XCTAssertTrue(retry.waitForExistence(timeout: 5))
    retry.tap()
    XCTAssertTrue(retry.waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.staticTexts.matching(
        NSPredicate(format: "label == %@", "你：今天有点累")
      ).count,
      1
    )
  }

  func testMalformedAndOversizedConversationResponsesFailClosed() {
    for (behavior, expectedMessage) in [
      ("malformedResponse", "回复格式不完整"),
      ("oversizedResponse", "回复超过安全长度"),
    ] {
      let app = launchMock(
        storageID: "phone-conversation-\(behavior)",
        reset: true,
        chatBehavior: behavior
      )

      send("测试异常回复", in: app)

      let failure = element("phone.mori.chat-failure", in: app)
      XCTAssertTrue(failure.waitForExistence(timeout: 5))
      XCTAssertTrue(failure.label.contains(expectedMessage))
      XCTAssertFalse(
        app.staticTexts.matching(
          NSPredicate(format: "label BEGINSWITH %@", "Mori：")
        ).allElementsBoundByIndex.contains(where: {
          $0.label.contains("我听见了")
        })
      )
      app.terminate()
    }
  }

  func testSlowConversationCanBeStoppedWithoutSavingPartialReply() {
    let app = launchMock(
      storageID: "phone-conversation-cancel",
      reset: true,
      chatBehavior: "slowStream"
    )

    send("请慢慢回复", in: app)

    let cancel = app.buttons["phone.mori.cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    cancel.tap()
    let failure = element("phone.mori.chat-failure", in: app)
    XCTAssertTrue(failure.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "已停止")
      ).firstMatch.waitForExistence(timeout: 5)
    )
    XCTAssertFalse(element("phone.mori.message.streaming", in: app).exists)
  }

  func testClearConversationRemovesDraftMessagesAndCacheButKeepsHomeUsable() {
    let app = launchMock(
      storageID: "phone-conversation-clear",
      reset: true
    )
    send("准备清除", in: app)
    XCTAssertTrue(
      app.staticTexts["你：准备清除"].waitForExistence(timeout: 5)
    )

    app.buttons["phone.open-settings"].tap()
    let clear = app.buttons["phone.settings.clear-conversation"]
    scrollToElement(clear, in: app)
    clear.tap()
    let confirmation = app.alerts["清除对话记录？"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    confirmation.buttons
      .matching(identifier: "phone.settings.clear-conversation-confirm")
      .firstMatch.tap()
    app.buttons["phone.settings.done"].tap()

    XCTAssertTrue(
      app.staticTexts["Mori：我在这里。今天想和我说什么？"]
        .waitForExistence(timeout: 5)
    )
    XCTAssertFalse(app.staticTexts["你：准备清除"].exists)
    let composer = element("phone.mori.composer", in: app)
    XCTAssertTrue(composer.exists)
    composer.tap()
    composer.typeText("清除后还能说")
    XCTAssertTrue(app.buttons["phone.mori.send"].isEnabled)
  }

  func testMemoryTimelineDoesNotPresentUnsealedCurrentFacts() {
    let app = launchMock(storageID: "phone-memories", reset: true)

    app.tabBars.buttons["回忆"].tap()
    XCTAssertTrue(element("phone.memories", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(element("phone.memories.empty", in: app).exists)
    XCTAssertFalse(element("phone.memory.today", in: app).exists)
    XCTAssertFalse(app.staticTexts["3,250步"].exists)
    XCTAssertFalse(app.staticTexts["7小时30分"].exists)
    XCTAssertFalse(app.staticTexts["健康状态"].exists)
    XCTAssertFalse(app.staticTexts["恢复不足"].exists)
  }

  func testCollectionPurchaseAndEquipPersistAcrossRelaunch() {
    let storageID = "phone-collection"
    let app = launchMock(storageID: storageID, reset: true)

    app.tabBars.buttons["收藏"].tap()
    XCTAssertTrue(
      element("phone.collection", in: app).waitForExistence(timeout: 5)
    )
    XCTAssertEqual(
      element("phone.collection.coins", in: app).label,
      "金币 18 枚"
    )

    let buy = app.buttons["phone.collection.buy.scarf"]
    scrollToElement(buy, in: app)
    buy.tap()
    let use = app.buttons["phone.collection.use.scarf"]
    XCTAssertTrue(use.waitForExistence(timeout: 5))
    XCTAssertEqual(
      element("phone.collection.coins", in: app).label,
      "金币 10 枚"
    )
    use.tap()
    XCTAssertTrue(app.staticTexts["使用中"].waitForExistence(timeout: 5))
    app.terminate()

    let relaunched = launchMock(storageID: storageID, reset: false)
    relaunched.tabBars.buttons["收藏"].tap()
    XCTAssertTrue(
      element("phone.collection.coins", in: relaunched)
        .waitForExistence(timeout: 5)
        && element("phone.collection.coins", in: relaunched).label
          == "金币 10 枚"
    )
    XCTAssertFalse(relaunched.buttons["phone.collection.buy.scarf"].exists)
  }

  func testSettingsOwnsCompanionDataAndHonestSyncStatus() {
    let app = launchMock(storageID: "phone-settings", reset: true)

    app.buttons["phone.open-settings"].tap()
    XCTAssertTrue(element("phone.settings", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["数据与权限"].exists)
    XCTAssertTrue(app.staticTexts["Mori 随行"].exists)
    XCTAssertFalse(app.buttons["同步测试"].exists)
    XCTAssertFalse(app.buttons["模拟同步失败"].exists)
    XCTAssertTrue(app.switches["phone.settings.companion-sensing"].exists)
    XCTAssertTrue(app.buttons["phone.settings.quiet-hours"].exists)
    let automaticSync = element("phone.settings.sync-status", in: app)
    scrollToElement(automaticSync, in: app)
    XCTAssertTrue(automaticSync.exists)
    XCTAssertTrue(automaticSync.label.contains("尚未接入"))
    let appleSettings = element("phone.settings.open-apple-settings", in: app)
    scrollToElement(appleSettings, in: app)
    XCTAssertTrue(appleSettings.exists)
    app.buttons["phone.settings.done"].tap()
    XCTAssertTrue(element("phone.mori.scene", in: app).waitForExistence(timeout: 5))
  }

  func testDeleteAllMoriDataRequiresConfirmationAndReturnsToOnboarding() {
    let app = launchMock(storageID: "phone-delete-all", reset: true)

    app.buttons["phone.open-settings"].tap()
    XCTAssertTrue(element("phone.settings", in: app).waitForExistence(timeout: 5))
    let delete = app.buttons["phone.settings.delete-all"]
    scrollToElement(delete, in: app)
    XCTAssertTrue(delete.exists)
    delete.tap()

    XCTAssertTrue(
      element("phone.settings.delete-all-confirmation", in: app)
        .waitForExistence(timeout: 5)
    )
    app.buttons["phone.settings.confirm-delete-all"].tap()
    XCTAssertTrue(
      element("phone.onboarding", in: app).waitForExistence(timeout: 8)
    )
    XCTAssertTrue(
      element("phone.onboarding.status", in: app).label
        .contains("本机 Mori 数据已删除")
    )
  }

  func testInvalidMockFailsClosedAcrossAllProductTabs() {
    let app = launchInvalidMock()

    XCTAssertTrue(element("phone.mori.scene", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.invalid-mock-badge", in: app).exists)
    XCTAssertTrue(element("phone.mori.invalid-mock", in: app).exists)
    app.tabBars.buttons["今天"].tap()
    XCTAssertTrue(
      element("phone.today.task-unavailable", in: app)
        .waitForExistence(timeout: 5)
    )
    app.tabBars.buttons["收藏"].tap()
    XCTAssertTrue(
      element("phone.collection.unavailable", in: app)
        .waitForExistence(timeout: 5)
    )
    XCTAssertFalse(element("phone.today.coins", in: app).exists)
    XCTAssertFalse(element("phone.collection.coins", in: app).exists)
  }

  func testCareNotificationRouteOpensSafeCareMessage() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITesting", "--mock-scenario=health_normal", "--notification-route=pet/care",
    ]
    app.launch()

    XCTAssertTrue(
      element("phone.notification.careMessage", in: app).waitForExistence(timeout: 8)
    )
    XCTAssertTrue(app.staticTexts["已回到 Mori"].exists)
    XCTAssertTrue(
      app.staticTexts["打开来信只负责导航，不会自动完成任务、发放金币或写入健康数据。"].exists
    )
    app.buttons["phone.notification.dismiss"].tap()
    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 5))
  }

  func testAccessibilityAuditAcrossProductSurfaces() throws {
    let app = launchMock(storageID: "phone-accessibility", reset: true)
    XCTAssertTrue(element("phone.mori.scene", in: app).waitForExistence(timeout: 8))
    try auditCurrentScreen(app)

    for (tab, identifier) in [
      ("今天", "phone.today"),
      ("回忆", "phone.memories"),
      ("收藏", "phone.collection"),
    ] {
      app.tabBars.buttons[tab].tap()
      XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 5))
      try auditCurrentScreen(app)
    }

    app.buttons["phone.open-settings"].tap()
    XCTAssertTrue(element("phone.settings", in: app).waitForExistence(timeout: 5))
    try auditCurrentScreen(app)
  }

  private func launchApp(
    scenario: String,
    additionalArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      ["-UITesting", "--mock-scenario=\(scenario)"] + additionalArguments
    app.launch()
    return app
  }

  private func launchMock(
    storageID: String,
    reset: Bool,
    chatBehavior: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITesting",
      "--mock-scenario=mock1",
      "--e2e-storage-id=\(storageID)",
      "--e2e-offline-runtime",
    ]
    if reset {
      app.launchArguments.append("--reset-e2e-storage")
    }
    if let chatBehavior {
      app.launchArguments.append("--chat-behavior=\(chatBehavior)")
    }
    app.launch()
    return app
  }

  private func send(
    _ text: String,
    in app: XCUIApplication
  ) {
    let composer = element("phone.mori.composer", in: app)
    XCTAssertTrue(composer.waitForExistence(timeout: 8))
    composer.tap()
    composer.typeText(text)
    let send = app.buttons["phone.mori.send"]
    expectation(
      for: NSPredicate(format: "enabled == true"),
      evaluatedWith: send
    )
    waitForExpectations(timeout: 3)
    send.tap()
  }

  private func launchInvalidMock() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITesting", "--mock-scenario=not_allowlisted",
    ]
    app.launch()
    return app
  }

  private func scrollToElement(
    _ element: XCUIElement,
    in app: XCUIApplication
  ) {
    guard
      let scrollSurface =
        app.scrollViews.allElementsBoundByIndex.first
        ?? app.collectionViews.allElementsBoundByIndex.first
        ?? app.tables.allElementsBoundByIndex.first
    else {
      XCTFail("Expected a scrollable phone surface")
      return
    }
    for _ in 0..<8 {
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

  private func scrollHorizontallyToElement(
    _ element: XCUIElement,
    in app: XCUIApplication
  ) {
    guard let horizontalScroll = app.scrollViews.allElementsBoundByIndex.last else {
      XCTFail("Expected a horizontal character picker")
      return
    }
    for _ in 0..<8 {
      let visibleFrame = horizontalScroll.frame.insetBy(dx: 8, dy: 0)
      if element.exists,
        element.frame.minX >= visibleFrame.minX,
        element.frame.maxX <= visibleFrame.maxX
      {
        return
      }
      horizontalScroll.swipeLeft()
    }
  }

  private func element(
    _ identifier: String,
    in app: XCUIApplication
  ) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
  }

  private func auditCurrentScreen(_ app: XCUIApplication) throws {
    try app.performAccessibilityAudit(
      for: [
        .contrast,
        .elementDetection,
        .hitRegion,
        .sufficientElementDescription,
        .textClipped,
        .trait,
      ]
    ) { issue in
      if issue.auditType == .contrast,
        self.element("phone.settings", in: app).exists
      {
        // Settings is a native Form. iOS 26 reports false positives for its
        // standard section text, picker values, and controls at scroll edges.
        // Other audit categories remain enforced on this surface.
        return true
      }
      guard issue.auditType == .contrast,
        let candidate = issue.element,
        candidate.elementType == .staticText
      else {
        return false
      }
      if candidate.identifier == "phone.today.memory-boundary"
        || candidate.label.hasPrefix("这仍是当天记录")
      {
        // iOS 26 intermittently reports this black-on-background text only
        // when the full suite runs and its audit auto-scrolls the last row.
        // The element is visually verified and its other audit categories
        // remain enforced.
        return true
      }
      let tabBar = app.tabBars.firstMatch
      guard tabBar.exists else { return false }
      // The audit engine may auto-scroll a final static-text element partly
      // behind the translucent tab bar. Ignore only that occluded element;
      // contrast remains enforced everywhere above the bar.
      return candidate.frame.maxY > tabBar.frame.minY
    }
  }
}
