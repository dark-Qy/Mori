import SwiftUI

enum PhoneTab: Hashable {
  case overview
  case history
  case wardrobe
  case privacy
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
        managementTabs
      }
    }
    .task {
      await store.start()
    }
  }

  private var managementTabs: some View {
    TabView(selection: $store.selectedTab) {
      NavigationStack {
        OverviewView(store: store)
      }
      .tabItem {
        Label("概览", systemImage: "house.fill")
      }
      .accessibilityIdentifier("phone.tab.overview")
      .tag(PhoneTab.overview)

      NavigationStack {
        HistoryView(model: store.model)
      }
      .tabItem {
        Label("历史", systemImage: "chart.bar.xaxis")
      }
      .accessibilityIdentifier("phone.tab.history")
      .tag(PhoneTab.history)

      NavigationStack {
        WardrobeView(store: store)
      }
      .tabItem {
        Label("衣橱", systemImage: "tshirt.fill")
      }
      .accessibilityIdentifier("phone.tab.wardrobe")
      .tag(PhoneTab.wardrobe)

      NavigationStack {
        PrivacyView(store: store)
      }
      .tabItem {
        Label("隐私", systemImage: "hand.raised.fill")
      }
      .accessibilityIdentifier("phone.tab.privacy")
      .tag(PhoneTab.privacy)
    }
    .tint(CompanionPalette.mint)
    .accessibilityIdentifier("phone.root")
    .sheet(item: $store.notificationDestination) { destination in
      PhoneNotificationMessageView(
        destination: destination,
        onDismiss: store.dismissNotificationDestination
      )
    }
  }
}

#if DEBUG
  #Preview {
    PhoneRootView(
      store: PhoneAppStore(arguments: ["-UITesting", "--mock-scenario=health_normal"])
    )
  }
#endif
