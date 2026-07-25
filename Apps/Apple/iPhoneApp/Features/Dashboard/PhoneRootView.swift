import SwiftUI

enum PhoneTab: Hashable {
  case mori
  case today
  case memories
  case scenes
}

struct PhoneRootView: View {
  @ObservedObject var store: PhoneAppStore
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      switch store.phase {
      case .loading:
        ProgressView("正在载入本机状态…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(CompanionPalette.background)
          .accessibilityIdentifier("phone.loading")
      case .onboarding:
        PhoneOnboardingView(store: store)
      case .ready:
        productTabs
      }
    }
    .task {
      await store.start()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await store.handleForegroundActivation() }
    }
  }

  private var productTabs: some View {
    TabView(selection: $store.selectedTab) {
      NavigationStack {
        MoriHomeView(store: store)
          .phoneSettingsToolbar(action: store.showSettings)
      }
      .tabItem {
        Label("Mori", systemImage: "bird.fill")
      }
      .accessibilityIdentifier("phone.tab.mori")
      .tag(PhoneTab.mori)

      NavigationStack {
        PhoneTodayView(store: store)
          .phoneSettingsToolbar(action: store.showSettings)
      }
      .tabItem {
        Label("今天", systemImage: "sun.max.fill")
      }
      .accessibilityIdentifier("phone.tab.today")
      .tag(PhoneTab.today)

      NavigationStack {
        PhoneMemoriesView(store: store)
          .phoneSettingsToolbar(action: store.showSettings)
      }
      .tabItem {
        Label("回忆", systemImage: "book.pages.fill")
      }
      .accessibilityIdentifier("phone.tab.memories")
      .tag(PhoneTab.memories)

      NavigationStack {
        PhoneScenesView(store: store)
          .phoneSettingsToolbar(action: store.showSettings)
      }
      .tabItem {
        Label("场景", systemImage: "photo.on.rectangle.angled")
      }
      .accessibilityIdentifier("phone.tab.scenes")
      .tag(PhoneTab.scenes)
    }
    .tint(CompanionPalette.mint)
    .accessibilityIdentifier("phone.root")
    .onChange(of: store.selectedTab) {
      if store.selectedTab != .mori {
        store.stopMoriSpeech()
      }
    }
    .sheet(
      isPresented: $store.isShowingSettings,
      onDismiss: store.settingsDidDismiss
    ) {
      NavigationStack {
        PhoneSettingsView(store: store)
      }
    }
    .sheet(item: $store.notificationDestination) { destination in
      PhoneNotificationMessageView(
        destination: destination,
        onDismiss: store.dismissNotificationDestination
      )
    }
  }
}

private struct PhoneSettingsToolbarModifier: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    content
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: action) {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("设置")
          .accessibilityIdentifier("phone.open-settings")
        }
      }
  }
}

extension View {
  fileprivate func phoneSettingsToolbar(
    action: @escaping () -> Void
  ) -> some View {
    modifier(PhoneSettingsToolbarModifier(action: action))
  }
}

#if DEBUG
  #Preview {
    PhoneRootView(
      store: PhoneAppStore(
        arguments: ["-UITesting", "--mock-scenario=mock1"]
      )
    )
  }
#endif
