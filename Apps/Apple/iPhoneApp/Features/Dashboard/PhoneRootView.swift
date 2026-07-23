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
    .task {
      await store.start()
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
