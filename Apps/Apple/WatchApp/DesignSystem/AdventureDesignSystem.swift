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

struct MockBadge: View {
  let scenarioName: String

  var body: some View {
    Label("Mock", systemImage: "testtube.2")
      .font(.caption2.weight(.bold))
      .foregroundStyle(AdventurePalette.blue)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(AdventurePalette.blue.opacity(0.13), in: Capsule())
      .accessibilityLabel("演示数据，场景 \(scenarioName)")
      .accessibilityIdentifier("watch.mock-badge")
  }
}

struct WatchDataBadge: View {
  let model: WatchPresentationModel

  var body: some View {
    if case .invalidMock(let value) = model.dataMode {
      Label("Mock 无效", systemImage: "exclamationmark.triangle.fill")
        .font(.caption2.weight(.bold))
        .foregroundStyle(AdventurePalette.rose)
        .accessibilityLabel("Mock 场景无效，\(value)")
        .accessibilityIdentifier("watch.invalid-mock-badge")
    } else if let scenario = model.mockScenario {
      MockBadge(scenarioName: scenario.displayName)
    } else {
      Label("HealthKit", systemImage: "heart.fill")
        .font(.caption2.weight(.bold))
        .foregroundStyle(AdventurePalette.mint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(AdventurePalette.mint.opacity(0.13), in: Capsule())
        .accessibilityLabel("真实模式，本机 HealthKit 数据")
        .accessibilityIdentifier("watch.live-badge")
    }
  }
}
