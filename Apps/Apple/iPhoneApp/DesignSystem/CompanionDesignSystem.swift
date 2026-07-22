import SwiftUI
import UIKit

enum CompanionPalette {
  static let ink = Color(uiColor: .label)
  static let background = Color(uiColor: .systemGroupedBackground)
  static let surface = Color(uiColor: .secondarySystemGroupedBackground)
  static let mint = adaptive(
    light: UIColor(red: 0.00, green: 0.38, blue: 0.26, alpha: 1),
    dark: UIColor(red: 0.36, green: 0.95, blue: 0.70, alpha: 1),
    highContrastLight: UIColor(red: 0.00, green: 0.28, blue: 0.19, alpha: 1),
    highContrastDark: UIColor(red: 0.55, green: 1.00, blue: 0.80, alpha: 1)
  )
  static let mintSoft = adaptive(
    light: UIColor(red: 0.85, green: 0.95, blue: 0.90, alpha: 1),
    dark: UIColor(red: 0.08, green: 0.24, blue: 0.18, alpha: 1),
    highContrastLight: UIColor(red: 0.78, green: 0.92, blue: 0.85, alpha: 1),
    highContrastDark: UIColor(red: 0.05, green: 0.30, blue: 0.21, alpha: 1)
  )
  static let blue = adaptive(
    light: UIColor(red: 0.00, green: 0.32, blue: 0.70, alpha: 1),
    dark: UIColor(red: 0.42, green: 0.72, blue: 1.00, alpha: 1),
    highContrastLight: UIColor(red: 0.00, green: 0.22, blue: 0.58, alpha: 1),
    highContrastDark: UIColor(red: 0.60, green: 0.82, blue: 1.00, alpha: 1)
  )
  static let gold = adaptive(
    light: UIColor(red: 0.50, green: 0.28, blue: 0.00, alpha: 1),
    dark: UIColor(red: 1.00, green: 0.76, blue: 0.34, alpha: 1),
    highContrastLight: UIColor(red: 0.38, green: 0.19, blue: 0.00, alpha: 1),
    highContrastDark: UIColor(red: 1.00, green: 0.86, blue: 0.58, alpha: 1)
  )
  static let rose = adaptive(
    light: UIColor(red: 0.68, green: 0.08, blue: 0.25, alpha: 1),
    dark: UIColor(red: 1.00, green: 0.48, blue: 0.61, alpha: 1),
    highContrastLight: UIColor(red: 0.52, green: 0.02, blue: 0.17, alpha: 1),
    highContrastDark: UIColor(red: 1.00, green: 0.66, blue: 0.74, alpha: 1)
  )

  private static func adaptive(
    light: UIColor,
    dark: UIColor,
    highContrastLight: UIColor,
    highContrastDark: UIColor
  ) -> Color {
    Color(
      uiColor: UIColor { traits in
        switch (traits.userInterfaceStyle, traits.accessibilityContrast) {
        case (.dark, .high): highContrastDark
        case (.dark, _): dark
        case (_, .high): highContrastLight
        default: light
        }
      })
  }
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
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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
