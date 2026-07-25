#if DEBUG
  import MoriDomain
  import MoriRuntime

  /// Profile-local consent used only by the deterministic, on-device Mock
  /// conversation. It deliberately never mutates the global consent state
  /// that will govern a future production transport.
  actor PhoneMockChatAuthority: ChatAuthorityProviding {
    private let profile: RuntimeProfile
    private var memoryContextConsent: MoriConsentRecord
    private let remoteChatConsent: MoriConsentRecord

    init(
      profile: RuntimeProfile,
      memoryContextEnabled: Bool
    ) {
      self.profile = profile
      let selectionCounter: UInt64
      if case .mock(_, let selectionEpoch) = profile.source {
        selectionCounter = selectionEpoch.revision.counter
      } else {
        selectionCounter = 0
      }
      let baseCounter =
        max(
          max(
            profile.epoch.revision.counter,
            profile.deletionEpoch.revision.counter
          ),
          selectionCounter
        ) &+ 1
      remoteChatConsent = MoriConsentRecord(
        enabled: false,
        disclosureVersion: 0,
        revision: LamportRevision(
          counter: baseCounter,
          originDeviceID: "phone-mock-chat"
        ),
        authorDevice: .phone
      )
      memoryContextConsent = MoriConsentRecord(
        enabled: memoryContextEnabled,
        disclosureVersion:
          memoryContextEnabled
          ? MoriConsentKind.memoryContext.requiredDisclosureVersion
          : 0,
        revision: LamportRevision(
          counter: baseCounter &+ 1,
          originDeviceID: "phone-mock-chat"
        ),
        authorDevice: .phone
      )
    }

    func currentChatAuthority() -> ChatAuthoritySnapshot {
      snapshot()
    }

    @discardableResult
    func setMemoryContext(
      _ enabled: Bool
    ) -> ChatAuthoritySnapshot {
      guard memoryContextConsent.enabled != enabled else {
        return snapshot()
      }
      memoryContextConsent = MoriConsentRecord(
        enabled: enabled,
        disclosureVersion:
          enabled
          ? MoriConsentKind.memoryContext.requiredDisclosureVersion
          : 0,
        revision: LamportRevision(
          counter: memoryContextConsent.revision.counter &+ 1,
          originDeviceID: "phone-mock-chat"
        ),
        authorDevice: .phone
      )
      return snapshot()
    }

    private func snapshot() -> ChatAuthoritySnapshot {
      ChatAuthoritySnapshot(
        profile: profile,
        remoteChatConsent: remoteChatConsent,
        memoryContextConsent: memoryContextConsent
      )
    }
  }
#endif
