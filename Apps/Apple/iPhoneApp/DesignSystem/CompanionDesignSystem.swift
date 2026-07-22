import SwiftUI

enum CompanionPalette {
  static let ink = Color(red: 0.08, green: 0.12, blue: 0.15)
  static let background = Color(red: 0.95, green: 0.97, blue: 0.96)
  static let surface = Color.white
  static let mint = Color(red: 0.10, green: 0.63, blue: 0.45)
  static let mintSoft = Color(red: 0.86, green: 0.96, blue: 0.91)
  static let blue = Color(red: 0.20, green: 0.50, blue: 0.90)
  static let gold = Color(red: 0.88, green: 0.56, blue: 0.10)
  static let rose = Color(red: 0.88, green: 0.28, blue: 0.42)
}

enum CompanionSpacing {
  static let small: CGFloat = 8
  static let medium: CGFloat = 14
  static let large: CGFloat = 24
  static let page: CGFloat = 18
}

enum CompanionRadius {
  static let card: CGFloat = 18
  static let hero: CGFloat = 28
}

struct CompanionCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(CompanionSpacing.medium)
      .background(
        CompanionPalette.surface,
        in: RoundedRectangle(cornerRadius: CompanionRadius.card, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: CompanionRadius.card, style: .continuous)
          .stroke(Color.black.opacity(0.045), lineWidth: 1)
      }
  }
}

struct PhoneMockBadge: View {
  let scenarioName: String

  var body: some View {
    Label("Mock 场景 · \(scenarioName)", systemImage: "testtube.2")
      .font(.caption.weight(.semibold))
      .foregroundStyle(CompanionPalette.blue)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(CompanionPalette.blue.opacity(0.10), in: Capsule())
      .accessibilityLabel("演示数据，场景 \(scenarioName)")
      .accessibilityIdentifier("phone.mock-badge")
  }
}

struct PhoneDataBadge: View {
  let model: PhonePresentationModel

  var body: some View {
    if case .invalidMock(let value) = model.dataMode {
      Label("Mock 无效", systemImage: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(CompanionPalette.rose)
        .accessibilityLabel("Mock 场景无效，\(value)")
        .accessibilityIdentifier("phone.invalid-mock-badge")
    } else if let scenario = model.mockScenario {
      PhoneMockBadge(scenarioName: scenario.displayName)
    } else {
      Label("HealthKit · 本机", systemImage: "heart.text.clipboard.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(CompanionPalette.mint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CompanionPalette.mint.opacity(0.10), in: Capsule())
        .accessibilityLabel("真实模式，本机 HealthKit 数据")
        .accessibilityIdentifier("phone.live-badge")
    }
  }
}

struct PhonePage<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      content
        .padding(.horizontal, CompanionSpacing.page)
        .padding(.bottom, 40)
    }
    .background(CompanionPalette.background.ignoresSafeArea())
  }
}
