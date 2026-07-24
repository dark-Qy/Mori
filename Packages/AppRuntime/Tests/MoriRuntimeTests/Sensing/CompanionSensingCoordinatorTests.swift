import AppleAdapters
import Foundation
import MoriDomain
import Testing

@testable import MoriRuntime

@Suite("Companion sensing lifecycle")
struct CompanionSensingCoordinatorTests {
  @Test("Disabling stops adapters, invalidates callbacks, and clears pending work")
  func disableIsPrivacyImmediate() async throws {
    let fixture = try await makeFixture()
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let enabledEpoch = SensingEpoch(
      LamportRevision(counter: 2, originDeviceID: "phone")
    )
    let disabledEpoch = SensingEpoch(
      LamportRevision(counter: 3, originDeviceID: "phone")
    )

    let enabled = try await fixture.coordinator.setEnabled(
      true,
      profile: fixture.profile,
      sensingEpoch: enabledEpoch,
      effectiveAt: startedAt
    )
    guard case .applied(let token?) = enabled else {
      Issue.record("Expected an active sensing session")
      return
    }
    #expect(
      await fixture.coordinator.admission(
        for: token,
        observedAt: startedAt.addingTimeInterval(1)
      )
        == .companion(enabledEpoch, activeSince: startedAt)
    )

    let disabled = try await fixture.coordinator.setEnabled(
      false,
      profile: fixture.profile,
      sensingEpoch: disabledEpoch,
      effectiveAt: startedAt.addingTimeInterval(10)
    )

    #expect(disabled == .applied(nil))
    #expect(await fixture.adapter.stopCount() == 1)
    #expect(await fixture.pending.count() == 1)
    #expect(await fixture.store.configurations().map(\.enabled) == [true, false])
    #expect(
      await fixture.coordinator.admission(
        for: token,
        observedAt: startedAt.addingTimeInterval(11)
      ) == .displayOnly
    )

    let normalizer = MoriEvidenceNormalizer()
    let staleCallbackFact = normalizer.normalizeMotion(
      BroadMotionObservation(
        activity: .walking,
        confidence: .high,
        observedAt: startedAt.addingTimeInterval(11)
      ),
      profile: fixture.profile,
      admission: await fixture.coordinator.admission(
        for: token,
        observedAt: startedAt.addingTimeInterval(11)
      )
    )
    #expect(staleCallbackFact?.authorization == .displayOnly)
  }

  @Test("Re-enable never authorizes evidence from the disabled interval")
  func reenableDoesNotBackfill() async throws {
    let fixture = try await makeFixture()
    let enabledAt = Date(timeIntervalSince1970: 2_000)
    let firstEpoch = SensingEpoch(
      LamportRevision(counter: 2, originDeviceID: "watch")
    )
    let disabledEpoch = SensingEpoch(
      LamportRevision(counter: 3, originDeviceID: "watch")
    )
    let secondEpoch = SensingEpoch(
      LamportRevision(counter: 4, originDeviceID: "watch")
    )
    guard
      case .applied(let firstToken?) = try await fixture.coordinator.setEnabled(
        true,
        profile: fixture.profile,
        sensingEpoch: firstEpoch,
        effectiveAt: enabledAt
      )
    else {
      Issue.record("Expected first session")
      return
    }
    _ = try await fixture.coordinator.setEnabled(
      false,
      profile: fixture.profile,
      sensingEpoch: disabledEpoch,
      effectiveAt: enabledAt.addingTimeInterval(10)
    )
    guard
      case .applied(let secondToken?) = try await fixture.coordinator.setEnabled(
        true,
        profile: fixture.profile,
        sensingEpoch: secondEpoch,
        effectiveAt: enabledAt.addingTimeInterval(20)
      )
    else {
      Issue.record("Expected second session")
      return
    }

    #expect(
      await fixture.coordinator.admission(
        for: firstToken,
        observedAt: enabledAt.addingTimeInterval(21)
      ) == .displayOnly
    )
    #expect(
      await fixture.coordinator.admission(
        for: secondToken,
        observedAt: enabledAt.addingTimeInterval(15)
      ) == .displayOnly
    )
    #expect(
      await fixture.coordinator.admission(
        for: secondToken,
        observedAt: enabledAt.addingTimeInterval(21)
      )
        == .companion(
          secondEpoch,
          activeSince: enabledAt.addingTimeInterval(20)
        )
    )
  }

  @Test("Losing profile and non-advancing epochs fail without starting adapters")
  func staleAuthorityFailsClosed() async throws {
    let fixture = try await makeFixture()
    let now = Date(timeIntervalSince1970: 3_000)
    let epoch = SensingEpoch(
      LamportRevision(counter: 2, originDeviceID: "phone")
    )
    let other = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("other"),
      revision: LamportRevision(counter: 10, originDeviceID: "phone")
    )

    await #expect(
      throws: CompanionSensingCoordinatorError.profileNotSelected
    ) {
      try await fixture.coordinator.setEnabled(
        true,
        profile: other.profile,
        sensingEpoch: epoch,
        effectiveAt: now
      )
    }
    _ = try await fixture.coordinator.setEnabled(
      true,
      profile: fixture.profile,
      sensingEpoch: epoch,
      effectiveAt: now
    )
    await #expect(
      throws: CompanionSensingCoordinatorError.nonAdvancingSensingEpoch
    ) {
      try await fixture.coordinator.setEnabled(
        false,
        profile: fixture.profile,
        sensingEpoch: epoch,
        effectiveAt: now.addingTimeInterval(1)
      )
    }
    #expect(await fixture.adapter.startCount() == 1)
    #expect(await fixture.store.configurations().count == 1)
  }

  @Test("A partial adapter start failure leaves no authorized callback session")
  func adapterFailureFailsClosed() async throws {
    let fixture = try await makeFixture(adapterFailsToStart: true)
    let now = Date(timeIntervalSince1970: 4_000)
    let epoch = SensingEpoch(
      LamportRevision(counter: 2, originDeviceID: "phone")
    )
    let token = CompanionSensingSessionToken(
      profile: fixture.profile,
      sensingEpoch: epoch,
      generation: 1,
      activeSince: now
    )

    await #expect(
      throws: CompanionSensingCoordinatorError.adapterStartFailed
    ) {
      try await fixture.coordinator.setEnabled(
        true,
        profile: fixture.profile,
        sensingEpoch: epoch,
        effectiveAt: now
      )
    }

    #expect(await fixture.coordinator.currentSession() == nil)
    #expect(await fixture.adapter.stopCount() == 1)
    #expect(
      await fixture.coordinator.admission(
        for: token,
        observedAt: now.addingTimeInterval(1)
      ) == .displayOnly
    )
  }

  @Test("Callbacks remain display-only until every adapter finishes starting")
  func callbacksDuringStartFailClosed() async throws {
    let revision = LamportRevision(counter: 1, originDeviceID: "phone")
    let profile = realProfile(revision: revision)
    let authority = try ProfileSelectionAuthority(
      initial: ProfileSelectionRecord.real(
        profile: profile,
        selectionRevision: revision
      )
    )
    let adapter = PausingSensingAdapter()
    let coordinator = try CompanionSensingCoordinator(
      selectionAuthority: authority,
      stateStore: RecordingSensingStateStore(),
      adapters: [adapter],
      pendingWork: RecordingPendingWork()
    )
    let now = Date(timeIntervalSince1970: 5_000)
    let epoch = SensingEpoch(
      LamportRevision(counter: 2, originDeviceID: "phone")
    )
    let transition = Task {
      try await coordinator.setEnabled(
        true,
        profile: profile,
        sensingEpoch: epoch,
        effectiveAt: now
      )
    }

    let token = await adapter.waitUntilStarted()
    #expect(
      await coordinator.admission(
        for: token,
        observedAt: now.addingTimeInterval(1)
      ) == .displayOnly
    )
    #expect(
      try await coordinator.setEnabled(
        true,
        profile: profile,
        sensingEpoch: epoch,
        effectiveAt: now
      ) == .duplicate(nil)
    )

    await adapter.release()
    _ = try await transition.value
    #expect(
      await coordinator.admission(
        for: token,
        observedAt: now.addingTimeInterval(1)
      ) == .companion(epoch, activeSince: now)
    )
  }

  @Test("A superseded startup cannot authorize or stop the newer session")
  func supersededStartupCannotAffectNewSession() async throws {
    let revision = LamportRevision(counter: 1, originDeviceID: "phone")
    let profile = realProfile(revision: revision)
    let authority = try ProfileSelectionAuthority(
      initial: ProfileSelectionRecord.real(
        profile: profile,
        selectionRevision: revision
      )
    )
    let adapter = PausingSensingAdapter()
    let coordinator = try CompanionSensingCoordinator(
      selectionAuthority: authority,
      stateStore: RecordingSensingStateStore(),
      adapters: [adapter],
      pendingWork: RecordingPendingWork()
    )
    let now = Date(timeIntervalSince1970: 6_000)
    let firstEpoch = SensingEpoch(
      LamportRevision(counter: 2, originDeviceID: "phone")
    )
    let secondEpoch = SensingEpoch(
      LamportRevision(counter: 3, originDeviceID: "phone")
    )
    let first = Task {
      try await coordinator.setEnabled(
        true,
        profile: profile,
        sensingEpoch: firstEpoch,
        effectiveAt: now
      )
    }
    let firstToken = await adapter.waitUntilStarted()

    let second = try await coordinator.setEnabled(
      true,
      profile: profile,
      sensingEpoch: secondEpoch,
      effectiveAt: now.addingTimeInterval(1)
    )

    await #expect(
      throws: CompanionSensingCoordinatorError.transitionSuperseded
    ) {
      try await first.value
    }
    guard case .applied(let secondToken?) = second else {
      Issue.record("Expected the newer session to be active")
      return
    }
    #expect(firstToken != secondToken)
    #expect(await adapter.stopCount() == 1)
    #expect(await coordinator.currentSession() == secondToken)
    #expect(
      await coordinator.admission(
        for: firstToken,
        observedAt: now.addingTimeInterval(2)
      ) == .displayOnly
    )
    #expect(
      await coordinator.admission(
        for: secondToken,
        observedAt: now.addingTimeInterval(2)
      )
        == .companion(
          secondEpoch,
          activeSince: now.addingTimeInterval(1)
        )
    )
  }

  @Test("A delayed lower epoch cannot supersede a reserved higher epoch")
  func highestRequestedEpochIsMonotonic() async throws {
    let revision = LamportRevision(counter: 1, originDeviceID: "phone")
    let profile = realProfile(revision: revision)
    let authority = PausingProfileSelectionAuthority(profile: profile)
    let adapter = RecordingSensingAdapter(failsToStart: false)
    let store = RecordingSensingStateStore()
    let coordinator = try CompanionSensingCoordinator(
      selectionAuthority: authority,
      stateStore: store,
      adapters: [adapter],
      pendingWork: RecordingPendingWork()
    )
    let now = Date(timeIntervalSince1970: 7_000)
    let lowerEpoch = SensingEpoch(
      LamportRevision(counter: 2, originDeviceID: "phone")
    )
    let higherEpoch = SensingEpoch(
      LamportRevision(counter: 3, originDeviceID: "phone")
    )
    let lower = Task {
      try await coordinator.setEnabled(
        true,
        profile: profile,
        sensingEpoch: lowerEpoch,
        effectiveAt: now
      )
    }
    await authority.waitUntilFirstAuthorizationIsPaused()

    let higher = try await coordinator.setEnabled(
      true,
      profile: profile,
      sensingEpoch: higherEpoch,
      effectiveAt: now.addingTimeInterval(1)
    )
    await authority.releaseFirstAuthorization()

    guard case .applied(let higherToken?) = higher else {
      Issue.record("Expected the higher epoch to become authoritative")
      return
    }
    await #expect(
      throws: CompanionSensingCoordinatorError.transitionSuperseded
    ) {
      try await lower.value
    }
    #expect(higherToken.sensingEpoch == higherEpoch)
    #expect(await coordinator.currentSession() == higherToken)
    #expect(await adapter.startCount() == 1)
    #expect(
      await store.configurations().map(\.sensingEpoch) == [higherEpoch]
    )
  }

  @Test("A stale profile request cannot stop the selected Mock session")
  func staleProfileRequestCannotAffectSelectedSession() async throws {
    let firstSelection = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("first-profile"),
      revision: LamportRevision(counter: 1, originDeviceID: "phone")
    )
    let secondSelection = try MockProfileDerivation.selection(
      scenarioID: MockScenarioID("second-profile"),
      revision: LamportRevision(counter: 2, originDeviceID: "phone")
    )
    let authority = SwitchingPausingProfileSelectionAuthority(
      selectedProfile: firstSelection.profile,
      pausedProfile: firstSelection.profile
    )
    let adapter = RecordingSensingAdapter(failsToStart: false)
    let store = RecordingSensingStateStore()
    let pending = RecordingPendingWork()
    let coordinator = try CompanionSensingCoordinator(
      selectionAuthority: authority,
      stateStore: store,
      adapters: [adapter],
      pendingWork: pending
    )
    let now = Date(timeIntervalSince1970: 8_000)
    let firstEpoch = SensingEpoch(
      LamportRevision(counter: 2, originDeviceID: "phone")
    )
    let secondEpoch = SensingEpoch(
      LamportRevision(counter: 3, originDeviceID: "phone")
    )
    let staleRequest = Task {
      try await coordinator.setEnabled(
        true,
        profile: firstSelection.profile,
        sensingEpoch: firstEpoch,
        effectiveAt: now
      )
    }
    await authority.waitUntilAuthorizationIsPaused()

    await authority.select(secondSelection.profile)
    let selectedResult = try await coordinator.setEnabled(
      true,
      profile: secondSelection.profile,
      sensingEpoch: secondEpoch,
      effectiveAt: now.addingTimeInterval(1)
    )
    await authority.releasePausedAuthorization()

    guard case .applied(let selectedToken?) = selectedResult else {
      Issue.record("Expected the selected Mock profile to own a session")
      return
    }
    await #expect(
      throws: CompanionSensingCoordinatorError.transitionSuperseded
    ) {
      try await staleRequest.value
    }
    #expect(selectedToken.profile == secondSelection.profile)
    #expect(await coordinator.currentSession() == selectedToken)
    #expect(await adapter.startCount() == 1)
    #expect(await adapter.stopCount() == 0)
    #expect(await pending.count() == 0)
    #expect(
      await store.configurations().map(\.profile) == [
        secondSelection.profile
      ]
    )
  }

  @Test("Suspension invalidates in-flight intent and permits a same-epoch restart")
  func suspensionInvalidatesIntentAndCanRestart() async throws {
    let fixture = try await makeFixture()
    let now = Date(timeIntervalSince1970: 9_000)
    let epoch = SensingEpoch(
      LamportRevision(counter: 2, originDeviceID: "phone")
    )
    guard
      case .applied(let firstToken?) = try await fixture.coordinator.setEnabled(
        true,
        profile: fixture.profile,
        sensingEpoch: epoch,
        effectiveAt: now
      )
    else {
      Issue.record("Expected the initial session")
      return
    }

    await fixture.coordinator.suspend()
    #expect(await fixture.coordinator.currentSession() == nil)
    #expect(
      await fixture.coordinator.admission(
        for: firstToken,
        observedAt: now.addingTimeInterval(1)
      ) == .displayOnly
    )

    guard
      case .applied(let restartedToken?) = try await fixture.coordinator.setEnabled(
        true,
        profile: fixture.profile,
        sensingEpoch: epoch,
        effectiveAt: now
      )
    else {
      Issue.record("Expected the suspended configuration to restart")
      return
    }
    #expect(restartedToken != firstToken)
    #expect(await fixture.coordinator.currentSession() == restartedToken)
    #expect(await fixture.adapter.startCount() == 2)
    #expect(await fixture.adapter.stopCount() == 1)
    #expect(await fixture.store.configurations().count == 1)
  }
}

private struct SensingFixture {
  let profile: RuntimeProfile
  let coordinator: CompanionSensingCoordinator
  let adapter: RecordingSensingAdapter
  let store: RecordingSensingStateStore
  let pending: RecordingPendingWork
}

private func makeFixture(
  adapterFailsToStart: Bool = false
) async throws -> SensingFixture {
  let revision = LamportRevision(counter: 1, originDeviceID: "phone")
  let profile = realProfile(revision: revision)
  let selection = try ProfileSelectionRecord.real(
    profile: profile,
    selectionRevision: revision
  )
  let authority = try ProfileSelectionAuthority(initial: selection)
  let adapter = RecordingSensingAdapter(failsToStart: adapterFailsToStart)
  let store = RecordingSensingStateStore()
  let pending = RecordingPendingWork()
  let coordinator = try CompanionSensingCoordinator(
    selectionAuthority: authority,
    stateStore: store,
    adapters: [adapter],
    pendingWork: pending
  )
  return SensingFixture(
    profile: profile,
    coordinator: coordinator,
    adapter: adapter,
    store: store,
    pending: pending
  )
}

private func realProfile(revision: LamportRevision) -> RuntimeProfile {
  RuntimeProfile(
    id: ProfileID("real-profile"),
    epoch: ProfileEpoch(revision),
    deletionEpoch: DeletionEpoch(
      requestID: DeletionRequestID("baseline"),
      revision: revision
    ),
    source: .real
  )
}

private actor RecordingSensingAdapter: CompanionSensingAdapterControl {
  private let failsToStart: Bool
  private var starts = 0
  private var stops = 0

  init(failsToStart: Bool) {
    self.failsToStart = failsToStart
  }

  func start(session: CompanionSensingSessionToken) throws {
    starts += 1
    if failsToStart {
      throw CompanionSensingCoordinatorError.adapterStartFailed
    }
  }

  func stop() {
    stops += 1
  }

  func startCount() -> Int {
    starts
  }

  func stopCount() -> Int {
    stops
  }
}

private actor RecordingSensingStateStore: CompanionSensingStateStore {
  private var values: [CompanionSensingConfiguration] = []

  func commit(_ configuration: CompanionSensingConfiguration) {
    values.append(configuration)
  }

  func configurations() -> [CompanionSensingConfiguration] {
    values
  }
}

private actor RecordingPendingWork: CompanionSensingPendingWork {
  private var invalidations = 0

  func invalidatePendingWork(
    for profile: RuntimeProfile,
    supersededBy sensingEpoch: SensingEpoch,
    at date: Date
  ) {
    invalidations += 1
  }

  func count() -> Int {
    invalidations
  }
}

private actor PausingSensingAdapter: CompanionSensingAdapterControl {
  private var startedToken: CompanionSensingSessionToken?
  private var tokenWaiters: [CheckedContinuation<CompanionSensingSessionToken, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var isReleased = false
  private var stops = 0

  func start(session: CompanionSensingSessionToken) async {
    startedToken = session
    let waiters = tokenWaiters
    tokenWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: session)
    }
    guard isReleased == false else { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func stop() {
    stops += 1
    release()
  }

  func stopCount() -> Int {
    stops
  }

  func waitUntilStarted() async -> CompanionSensingSessionToken {
    if let startedToken { return startedToken }
    return await withCheckedContinuation { continuation in
      tokenWaiters.append(continuation)
    }
  }

  func release() {
    isReleased = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor PausingProfileSelectionAuthority: ProfileSelectionAuthorizing {
  private let profile: RuntimeProfile
  private var authorizationCount = 0
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstAuthorizationIsPaused = false

  init(profile: RuntimeProfile) {
    self.profile = profile
  }

  func authorize(_ profile: RuntimeProfile) async -> ProfileSelectionAccess {
    authorizationCount += 1
    if authorizationCount == 1 {
      firstAuthorizationIsPaused = true
      let waiters = pauseWaiters
      pauseWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        releaseWaiters.append(continuation)
      }
    }
    return profile == self.profile
      ? .authorized
      : .rejected(.profileIsNotSelected)
  }

  func waitUntilFirstAuthorizationIsPaused() async {
    guard firstAuthorizationIsPaused == false else { return }
    await withCheckedContinuation { continuation in
      pauseWaiters.append(continuation)
    }
  }

  func releaseFirstAuthorization() {
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor SwitchingPausingProfileSelectionAuthority: ProfileSelectionAuthorizing {
  private var selectedProfile: RuntimeProfile
  private let pausedProfile: RuntimeProfile
  private var shouldPause = true
  private var isPaused = false
  private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    selectedProfile: RuntimeProfile,
    pausedProfile: RuntimeProfile
  ) {
    self.selectedProfile = selectedProfile
    self.pausedProfile = pausedProfile
  }

  func authorize(_ profile: RuntimeProfile) async -> ProfileSelectionAccess {
    let access: ProfileSelectionAccess =
      profile == selectedProfile
      ? .authorized
      : .rejected(.profileIsNotSelected)
    if profile == pausedProfile, shouldPause {
      shouldPause = false
      isPaused = true
      let waiters = pauseWaiters
      pauseWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        releaseWaiters.append(continuation)
      }
    }
    return access
  }

  func select(_ profile: RuntimeProfile) {
    selectedProfile = profile
  }

  func waitUntilAuthorizationIsPaused() async {
    guard isPaused == false else { return }
    await withCheckedContinuation { continuation in
      pauseWaiters.append(continuation)
    }
  }

  func releasePausedAuthorization() {
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
