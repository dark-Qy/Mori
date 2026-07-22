import SwiftUI

struct PhoneRootView: View {
  private let model = PhonePresentationModel.fromLaunchArguments()

  var body: some View {
    TabView {
      NavigationStack {
        OverviewView(model: model)
      }
      .tabItem {
        Label("概览", systemImage: "house.fill")
      }
      .accessibilityIdentifier("phone.tab.overview")

      NavigationStack {
        HistoryView(model: model)
      }
      .tabItem {
        Label("历史", systemImage: "chart.bar.xaxis")
      }
      .accessibilityIdentifier("phone.tab.history")

      NavigationStack {
        WardrobeView(model: model)
      }
      .tabItem {
        Label("衣橱", systemImage: "tshirt.fill")
      }
      .accessibilityIdentifier("phone.tab.wardrobe")

      NavigationStack {
        PrivacyView(model: model)
      }
      .tabItem {
        Label("隐私", systemImage: "hand.raised.fill")
      }
      .accessibilityIdentifier("phone.tab.privacy")
    }
    .tint(CompanionPalette.mint)
    .accessibilityIdentifier("phone.root")
  }
}

#Preview {
  PhoneRootView()
}
