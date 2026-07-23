import AppRuntime
import SwiftUI

struct PhoneNotificationMessageView: View {
  let destination: RuntimeNotificationDestination
  let onDismiss: () -> Void

  private var content: (symbol: String, color: Color, title: String, detail: String) {
    switch destination {
    case .recoveryMessage:
      (
        "moon.stars.fill",
        CompanionPalette.blue,
        "Mori 的恢复来信",
        "今天可以慢一点。你可以休息、换个更轻的任务，或者什么也不做。"
      )
    case .activityMessage:
      (
        "figure.walk",
        CompanionPalette.mint,
        "Mori 的活动来信",
        "如果愿意，我们可以一起走两分钟；不回应也不会失去成长。"
      )
    case .careMessage:
      (
        "heart.text.square.fill",
        CompanionPalette.rose,
        "Mori 的陪伴来信",
        "不用解释，也不需要立刻变好。要不要和我安静待一会儿？"
      )
    }
  }

  var body: some View {
    NavigationStack {
      PhonePage {
        VStack(alignment: .leading, spacing: CompanionSpacing.large) {
          Image(systemName: content.symbol)
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(content.color)
            .accessibilityHidden(true)

          Text(content.title)
            .font(.largeTitle.bold())
            .fixedSize(horizontal: false, vertical: true)

          Text(content.detail)
            .font(.title3)
            .foregroundStyle(CompanionPalette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

          CompanionCard {
            Label("打开来信只负责导航", systemImage: "checkmark.shield.fill")
              .font(.headline)
            Text("不会自动完成任务、领取奖励或写入健康数据。只有你之后明确执行的动作才会改变状态。")
              .font(.subheadline)
              .foregroundStyle(CompanionPalette.secondaryText)
          }

          Button("回到概览", action: onDismiss)
            .buttonStyle(.borderedProminent)
            .tint(CompanionPalette.mint)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("phone.notification.dismiss")
        }
      }
      .navigationTitle("Mori 来信")
    }
    .accessibilityIdentifier("phone.notification.\(destination.rawValue)")
  }
}
