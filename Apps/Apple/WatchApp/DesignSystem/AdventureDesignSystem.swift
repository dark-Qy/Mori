import SwiftUI

enum AdventurePalette {
  static let background = Color(red: 0.035, green: 0.055, blue: 0.075)
  static let surface = Color(red: 0.09, green: 0.115, blue: 0.135)
  static let mint = Color(red: 0.29, green: 0.88, blue: 0.67)
  static let blue = Color(red: 0.38, green: 0.66, blue: 1.0)
  static let gold = Color(red: 1.0, green: 0.73, blue: 0.30)
  static let rose = Color(red: 1.0, green: 0.48, blue: 0.58)
}

enum AdventureSpacing {
  static let small: CGFloat = 8
  static let medium: CGFloat = 12
  static let large: CGFloat = 20
  static let page: CGFloat = 10
}

enum AdventureRadius {
  static let card: CGFloat = 14
  static let hero: CGFloat = 22
}

struct AdventureCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AdventureSpacing.medium)
      .background(
        AdventurePalette.surface,
        in: RoundedRectangle(cornerRadius: AdventureRadius.card, style: .continuous)
      )
  }
}

struct MockBadge: View {
  let scenarioName: String

  var body: some View {
    Label("Mock · \(scenarioName)", systemImage: "testtube.2")
      .font(.system(size: 9, weight: .bold, design: .rounded))
      .foregroundStyle(AdventurePalette.blue)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(AdventurePalette.blue.opacity(0.13), in: Capsule())
      .accessibilityLabel("演示数据，场景 \(scenarioName)")
      .accessibilityIdentifier("watch.mock-badge")
  }
}
