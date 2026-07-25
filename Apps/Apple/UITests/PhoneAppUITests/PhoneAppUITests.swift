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

    app.tabBars.buttons["回忆"].tap()
    XCTAssertTrue(element("phone.history", in: app).waitForExistence(timeout: 5))
    XCTAssertFalse(element("phone.weekly-memory.hero", in: app).exists)
    XCTAssertTrue(element("phone.weekly-memory.empty", in: app).exists)
    XCTAssertFalse(app.staticTexts["个人近期"].exists)
    XCTAssertFalse(app.staticTexts["缺失指标未按零计算"].exists)
    app.buttons["phone.weekly-memory.manage"].tap()
    XCTAssertTrue(element("phone.weekly-memory.manager", in: app).waitForExistence(timeout: 5))
    XCTAssertFalse(app.switches["phone.weekly-memory.ai-toggle"].exists)
    XCTAssertTrue(app.staticTexts["还没有回忆"].exists)
    app.buttons["完成"].tap()

    app.tabBars.buttons["衣橱"].tap()
    XCTAssertTrue(element("phone.wardrobe", in: app).waitForExistence(timeout: 5))
    let leaf = app.buttons["phone.wardrobe.preview.leaf"]
    scrollToElement(leaf, in: app)
    XCTAssertTrue(leaf.exists)
    leaf.tap()
    XCTAssertTrue(element("phone.wardrobe.locked-reason", in: app).exists)

    app.tabBars.buttons["隐私"].tap()
    XCTAssertTrue(element("phone.privacy", in: app).waitForExistence(timeout: 5))
    let socialSharing = app.switches["phone.privacy.social-sharing"]
    XCTAssertTrue(socialSharing.exists)
    XCTAssertEqual(socialSharing.value as? String, "1")
    XCTAssertFalse(element("phone.privacy.social-state-locked", in: app).exists)
    XCTAssertTrue(element("phone.privacy.sharing-scope", in: app).exists)
    XCTAssertTrue(element("phone.privacy.health-sharing-unavailable", in: app).exists)
    XCTAssertFalse(element("phone.privacy.sharing-scope-picker", in: app).exists)

    socialSharing.tap()
    XCTAssertEqual(socialSharing.value as? String, "0")
    XCTAssertTrue(
      element("phone.privacy.social-state-locked", in: app)
        .waitForExistence(timeout: 5)
    )
    socialSharing.tap()
    XCTAssertEqual(socialSharing.value as? String, "1")

    let socialStatePicker = element("phone.privacy.social-state-picker", in: app)
    scrollToElement(socialStatePicker, in: app)
    XCTAssertTrue(socialStatePicker.waitForExistence(timeout: 5))
    XCTAssertFalse(element("phone.privacy.social-state-locked", in: app).exists)
    socialStatePicker.tap()
    let walkState = app.buttons["想一起散步"]
    XCTAssertTrue(walkState.waitForExistence(timeout: 5))
    walkState.tap()
    let socialStateSummary = element(
      "phone.privacy.social-state-summary",
      in: app
    )
    scrollToElement(socialStateSummary, in: app)
    XCTAssertTrue(
      socialStateSummary.waitForExistence(timeout: 5)
        && socialStateSummary.label.contains("想一起散步")
    )

    let healthSharingUnavailable = element("phone.privacy.health-sharing-unavailable", in: app)
    scrollToElement(healthSharingUnavailable, in: app)
    XCTAssertTrue(healthSharingUnavailable.waitForExistence(timeout: 5))
  }

  func testPetSceneRespondsDifferentlyToHeadAndBodyTouches() {
    let app = launchApp(scenario: "health_normal")

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    let scene = app.buttons["phone.companion-interaction"]
    XCTAssertTrue(scene.waitForExistence(timeout: 5))

    scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    XCTAssertTrue(app.staticTexts["Mori 开心地眨了眨眼"].waitForExistence(timeout: 2))

    Thread.sleep(forTimeInterval: 0.4)
    scene.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64)).tap()
    XCTAssertTrue(app.staticTexts["Mori 转过身回应了你"].waitForExistence(timeout: 2))
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
    XCTAssertTrue(element("phone.history", in: app).waitForExistence(timeout: 5))
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

  func testCharacterAndSharedBackgroundSelectionUpdateThePreview() {
    let app = launchApp(scenario: "health_normal")

    app.tabBars.buttons["衣橱"].tap()
    XCTAssertTrue(element("phone.wardrobe", in: app).waitForExistence(timeout: 5))
    let polarBear = app.buttons["phone.character.polar_bear"]
    scrollToElement(polarBear, in: app)
    polarBear.tap()
    XCTAssertTrue(polarBear.label.contains("白熊伙伴"))

    let firstBackground = app.buttons["phone.background.ice_ocean_day"]
    scrollToElement(firstBackground, in: app)
    let aurora = app.buttons["phone.background.aurora_observatory"]
    scrollHorizontallyToElement(aurora, in: app)
    aurora.tap()
    XCTAssertTrue(app.staticTexts["背景已更新；Mock 模拟手表可达"].waitForExistence(timeout: 5))
    let preview = element("phone.companion-preview", in: app)
    XCTAssertTrue(preview.exists)
    XCTAssertEqual(preview.value as? String, "白熊伙伴，极光观星台")
  }

  func testPartialHealthUsesKnownMetricsAndKeepsMissingValuesNeutral() {
    let app = launchApp(scenario: "health_partial")

    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.metric.recovery", in: app).label.contains("恢复，暂无睡眠数据"))
    let activityLabel = element("phone.metric.activity", in: app).label
    XCTAssertTrue(activityLabel.contains("活动"), "Actual activity label: \(activityLabel)")
    XCTAssertTrue(activityLabel.contains("2180"), "Actual activity label: \(activityLabel)")
    XCTAssertTrue(activityLabel.contains("步"), "Actual activity label: \(activityLabel)")
    XCTAssertTrue(element("phone.metric.rhythm", in: app).label.contains("节律，暂无节律数据"))
    XCTAssertTrue(
      element("phone.data-explanation.detail", in: app).label.contains("仅使用场景中已知的指标")
    )
    XCTAssertFalse(app.staticTexts["0h0m"].exists)
  }

  func testDefaultLaunchStartsWithMock1AndRemembersDemoSelection() {
    let storageID = "phone-default-demo"
    let app = launchDefaultApp(storageID: storageID, reset: true)

    XCTAssertTrue(element("phone.onboarding", in: app).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.mock-badge", in: app).label.contains("Mock 1"))
    XCTAssertFalse(element("phone.live-badge", in: app).exists)
    app.buttons["phone.onboarding.complete"].tap()
    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    let dataSource = app.buttons["phone.connect-health"]
    scrollToElement(dataSource, in: app)
    dataSource.tap()
    XCTAssertTrue(element("phone.data-source-picker", in: app).waitForExistence(timeout: 5))
    app.buttons["phone.data-source.option.mock2"].tap()
    XCTAssertTrue(
      element("phone.mock-badge", in: app).waitForExistence(timeout: 5)
        && element("phone.mock-badge", in: app).label.contains("Mock 2")
    )
    app.terminate()

    let relaunched = launchDefaultApp(storageID: storageID, reset: false)
    XCTAssertTrue(element("phone.overview", in: relaunched).waitForExistence(timeout: 8))
    XCTAssertTrue(element("phone.mock-badge", in: relaunched).label.contains("Mock 2"))
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

  func testCareNotificationRouteOpensSafeCareMessage() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UITesting", "--mock-scenario=health_normal", "--notification-route=pet/care",
    ]
    app.launch()

    XCTAssertTrue(
      element("phone.notification.careMessage", in: app).waitForExistence(timeout: 8)
    )
    XCTAssertTrue(app.staticTexts["Mori 的陪伴来信"].exists)
    XCTAssertTrue(app.staticTexts["打开来信只负责导航"].exists)
    app.buttons["phone.notification.dismiss"].tap()
    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["已打开 Mori 的陪伴来信；不需要解释，也不用立刻回应"].exists)
  }

  func testAccessibilityAuditAcrossManagementSurfaces() throws {
    let app = launchApp(scenario: "health_partial")
    XCTAssertTrue(element("phone.overview", in: app).waitForExistence(timeout: 8))
    try auditCurrentScreen(app)

    for (tab, identifier) in [
      ("回忆", "phone.history"),
      ("衣橱", "phone.wardrobe"),
      ("隐私", "phone.privacy"),
    ] {
      app.tabBars.buttons[tab].tap()
      XCTAssertTrue(element(identifier, in: app).waitForExistence(timeout: 5))
      try auditCurrentScreen(app)
    }
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

  private func launchLiveApp(storageID: String, reset: Bool) -> XCUIApplication {
    launchDefaultApp(
      storageID: storageID,
      reset: reset,
      additionalArguments: ["--e2e-data-source=healthKit"]
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
      XCTFail("Expected a horizontal background picker")
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
      ]
    ) { issue in
      let reviewedSystemEdgeIdentifiers: Set<String> = [
        "phone.pet-vitality-label",
        "phone.today-quest",
      ]
      let reviewedSystemEdgeLabels: Set<String> = ["本机计算"]
      if issue.auditType == .contrast,
        let candidate = issue.element,
        candidate.label.contains("生命力")
      {
        XCTFail(
          "VITALITY_CONTRAST_CANDIDATE type=\(candidate.elementType.rawValue) "
            + "identifier=\(candidate.identifier.debugDescription) "
            + "label=\(candidate.label.debugDescription) frame=\(candidate.frame)"
        )
      }
      guard issue.auditType == .contrast,
        let element = issue.element,
        element.elementType == .staticText
      else {
        return false
      }

      let tabBar = app.tabBars.firstMatch
      guard tabBar.exists else { return false }

      let elementFrame = element.frame
      let tabBarFrame = tabBar.frame
      guard elementFrame.width > 0, elementFrame.height > 0 else { return false }

      // Static text beginning at or below the measured system tab bar is outside the visible app
      // viewport, including content that continues below the physical screen edge.
      if elementFrame.minY >= tabBarFrame.minY {
        return true
      }

      let isReviewedPartialOverlap =
        reviewedSystemEdgeIdentifiers.contains(element.identifier)
        || reviewedSystemEdgeLabels.contains(element.label)
      guard isReviewedPartialOverlap else { return false }

      let systemEdgeFrame = tabBarFrame.insetBy(dx: 0, dy: -8)
      let overlap = elementFrame.intersection(systemEdgeFrame)
      guard !overlap.isNull, overlap.height > 0 else {
        return false
      }

      // iOS 26 intentionally renders scrolling text beneath the system tab bar's hard edge effect.
      // XCTest reports the reviewed detail as its card container. Accept only the calibrated
      // partial-overlap band: a tiny edge intersection or a materially covered card still fails.
      let overlapRatio = overlap.height / elementFrame.height
      return overlap.height >= 2 && overlapRatio <= 0.5
    }
  }
}
