import SwiftUI

enum PhoneTab: Hashable {
  case mori
  case today
  case memories
  case collection
}

struct PhoneRootView: View {
  @ObservedObject var store: PhoneAppStore

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
        PhoneMemoriesView(model: store.model)
          .phoneSettingsToolbar(action: store.showSettings)
      }
      .tabItem {
        Label("回忆", systemImage: "book.pages.fill")
      }
      .accessibilityIdentifier("phone.tab.memories")
      .tag(PhoneTab.memories)

      NavigationStack {
        PhoneCollectionView(store: store)
          .phoneSettingsToolbar(action: store.showSettings)
      }
      .tabItem {
        Label("收藏", systemImage: "heart.fill")
      }
      .accessibilityIdentifier("phone.tab.collection")
      .tag(PhoneTab.collection)
    }
    .tint(CompanionPalette.mint)
    .accessibilityIdentifier("phone.root")
    .sheet(
      isPresented: $store.isShowingSettings,
      onDismiss: store.dismissSettings
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
