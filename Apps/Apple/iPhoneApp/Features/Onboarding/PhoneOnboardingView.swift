import SwiftUI

struct PhoneOnboardingView: View {
  @ObservedObject var store: PhoneAppStore

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: CompanionSpacing.large) {
          ZStack(alignment: .bottom) {
            Image("scene_spring_meadow_stream_large")
              .resizable()
              .interpolation(.none)
              .scaledToFill()
            LinearGradient(
              colors: [.clear, .black.opacity(0.2)],
              startPoint: .center,
              endPoint: .bottom
            )
            Image("character_penguin_idle_lively_00")
              .resizable()
              .interpolation(.none)
              .scaledToFit()
              .frame(width: 220, height: 238)
              .padding(.bottom, 12)
          }
          .aspectRatio(1.15, contentMode: .fit)
          .clipped()
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("黑色企鹅 Mori 在春日花溪等你")

          VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
            Text("认识 Mori")
              .font(.largeTitle.bold())
            Text("它会安静地陪你走过现实中的一天，把本机能够确认的步数、停留和共同经历变成回忆。")
              .font(.title3)
              .foregroundStyle(CompanionPalette.secondaryText)
              .fixedSize(horizontal: false, vertical: true)

            onboardingRow(
              symbol: "iphone.gen3",
              title: "尽量在本机理解",
              detail: "不会把推测写成事实，也不会用健康数据给你下结论。"
            )
            onboardingRow(
              symbol: "applewatch",
              title: "手表负责当下陪伴",
              detail: "抬腕看 Mori；随行提醒、轻震和安静时段由你决定。"
            )
            onboardingRow(
              symbol: "lock.shield",
              title: "权限稍后再决定",
              detail: "这里不会自动请求健康、定位或通知权限；Mock 与真实记录始终隔离。"
            )
          }
          .padding(.horizontal, CompanionSpacing.page)

          Button {
            Task { await store.completeOnboarding() }
          } label: {
            Label(
              store.isSavingPreferences ? "正在保存…" : "开始陪伴",
              systemImage: "arrow.right"
            )
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(CompanionPalette.mint)
          .disabled(store.isSavingPreferences)
          .padding(.horizontal, CompanionSpacing.page)
          .accessibilityIdentifier("phone.onboarding.complete")

          if let status = store.statusMessage {
            Text(status)
              .font(.footnote)
              .foregroundStyle(CompanionPalette.secondaryText)
              .padding(.horizontal, CompanionSpacing.page)
              .accessibilityIdentifier("phone.onboarding.status")
          }
        }
        .padding(.bottom, 40)
      }
      .background(CompanionPalette.background.ignoresSafeArea())
      .navigationTitle("欢迎")
      .navigationBarTitleDisplayMode(.inline)
    }
    .accessibilityIdentifier("phone.onboarding")
  }

  private func onboardingRow(
    symbol: String,
    title: String,
    detail: String
  ) -> some View {
    HStack(alignment: .top, spacing: CompanionSpacing.medium) {
      Image(systemName: symbol)
        .font(.title3.weight(.semibold))
        .foregroundStyle(CompanionPalette.mint)
        .frame(width: 30)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(CompanionPalette.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
