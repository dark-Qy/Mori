import SwiftUI

struct PhoneOnboardingView: View {
  @ObservedObject var store: PhoneAppStore

  var body: some View {
    NavigationStack {
      PhonePage {
        VStack(alignment: .leading, spacing: CompanionSpacing.large) {
          PhoneDataBadge(model: store.model)
            .padding(.top, CompanionSpacing.small)

          VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
            Image(systemName: "pawprint.fill")
              .font(.system(size: 56, weight: .semibold))
              .foregroundStyle(CompanionPalette.mint)
              .accessibilityHidden(true)
            Text("Mori 会在手表上陪你成长")
              .font(.largeTitle.bold())
              .fixedSize(horizontal: false, vertical: true)
            Text("它把睡眠、活动和你主动完成的小习惯，翻译成容易理解的状态与剧情；健康数据不是通关门槛。")
              .font(.body)
              .foregroundStyle(CompanionPalette.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }

          CompanionCard {
            Label("先开始陪伴，之后再决定是否连接 HealthKit", systemImage: "hand.raised.fill")
              .font(.headline)
            Text("不会在这里自动请求健康或通知权限；缺失数据保持中性，也不会让宠物受伤或退化。")
              .font(.subheadline)
              .foregroundStyle(CompanionPalette.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }

          Button {
            Task { await store.completeOnboarding() }
          } label: {
            Label(
              store.isSavingPreferences ? "正在保存…" : "开始陪伴",
              systemImage: "sparkles"
            )
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .tint(CompanionPalette.mint)
          .disabled(store.isSavingPreferences)
          .accessibilityIdentifier("phone.onboarding.complete")

          if let status = store.statusMessage {
            Text(status)
              .font(.footnote)
              .foregroundStyle(CompanionPalette.secondaryText)
              .accessibilityIdentifier("phone.onboarding.status")
          }
        }
      }
      .navigationTitle("欢迎")
    }
    .accessibilityIdentifier("phone.onboarding")
  }
}
