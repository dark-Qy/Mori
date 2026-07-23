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

        Text(isPetIntroduction ? "你好，我是 Mori" : "一起照顾今天的状态")
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)

        Text(
          isPetIntroduction
            ? "我会陪你完成主线、记录小习惯，也会在合适的时候主动来找你。"
            : "健康数据可以帮助 Mori 理解你的节奏，但不是通关门槛；没有数据也不会受罚。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Label("不会自动请求 HealthKit 或通知权限", systemImage: "hand.raised.fill")
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
              ? "保存中…" : (isPetIntroduction ? "和 Mori 打招呼" : "开始陪伴"),
            systemImage: "sparkles"
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
