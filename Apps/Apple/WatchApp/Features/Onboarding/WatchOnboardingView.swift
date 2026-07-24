import SwiftUI

struct WatchOnboardingView: View {
  @ObservedObject var store: WatchAppStore
  let isPetIntroduction: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AdventureSpacing.medium) {
        WatchDataBadge(model: store.model)

        Image(systemName: "pawprint.fill")
          .font(.system(size: 42, weight: .semibold))
          .foregroundStyle(AdventurePalette.mint)
          .frame(maxWidth: .infinity)
          .accessibilityHidden(true)

        Text(isPetIntroduction ? "你好，我是 Mori" : "让 Mori 安静地陪着你")
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)

        Text(
          isPetIntroduction
            ? "我会和你一起经过日常的小路，也会记住那些值得留下的时刻。"
            : "Mori 会把本机处理后的移动和休息线索变成陪伴。没有数据时，它也只会安静待在这里。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Label("不会自动请求健康、定位或通知权限", systemImage: "hand.raised.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button {
          if isPetIntroduction {
            store.completePetIntroduction()
          } else {
            Task { await store.completeOnboarding() }
          }
        } label: {
          Label(
            store.isSavingPreferences
              ? "保存中…" : (isPetIntroduction ? "和 Mori 打招呼" : "开始"),
            systemImage: "heart.fill"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AdventurePalette.mint)
        .disabled(store.isSavingPreferences)
        .accessibilityIdentifier(
          isPetIntroduction ? "watch.pet-introduction.complete" : "watch.onboarding.complete"
        )

        if let status = store.statusMessage {
          Text(status)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("watch.onboarding.status")
        }
      }
      .padding(.horizontal, AdventureSpacing.page)
      .padding(.bottom, AdventureSpacing.large)
    }
    .background(AdventurePalette.background.ignoresSafeArea())
    .accessibilityIdentifier(
      isPetIntroduction ? "watch.pet-introduction" : "watch.onboarding"
    )
  }
}
