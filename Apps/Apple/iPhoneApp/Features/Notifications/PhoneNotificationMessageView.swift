import AppRuntime
import SwiftUI

struct PhoneNotificationMessageView: View {
  let destination: RuntimeNotificationDestination
  let onDismiss: () -> Void

  private var content:
    (
      symbol: String,
      title: String,
      detail: String
    )
  {
    switch destination {
    case .recoveryMessage:
      (
        "bird.fill",
        "已回到 Mori",
        "这是一条旧版入口；它不会凭通知类型生成一封不存在的来信。"
      )
    case .activityMessage:
      (
        "sun.max.fill",
        "已打开今天",
        "这是一条旧版入口；它只负责导航，不会创建或完成任务。"
      )
    case .careMessage:
      (
        "bird.fill",
        "已回到 Mori",
        "这是一条旧版入口；真实来信必须携带可验证的内容标识。"
      )
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: CompanionSpacing.large) {
        Spacer()
        Image(systemName: content.symbol)
          .font(.system(size: 46, weight: .semibold))
          .foregroundStyle(CompanionPalette.mint)
          .accessibilityHidden(true)

        Text(content.title)
          .font(.largeTitle.bold())
          .multilineTextAlignment(.center)

        Text(content.detail)
          .font(.title3)
          .foregroundStyle(CompanionPalette.secondaryText)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        Text("打开来信只负责导航，不会自动完成任务或写入健康数据。")
          .font(.footnote)
          .foregroundStyle(CompanionPalette.secondaryText)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        Button("继续", action: onDismiss)
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(CompanionPalette.mint)
          .accessibilityIdentifier("phone.notification.dismiss")
        Spacer()
      }
      .padding(CompanionSpacing.large)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(CompanionPalette.background.ignoresSafeArea())
      .navigationTitle("Mori 来信")
      .navigationBarTitleDisplayMode(.inline)
    }
    .accessibilityIdentifier("phone.notification.\(destination.rawValue)")
  }
}
