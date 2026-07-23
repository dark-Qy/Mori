import AppRuntime
import SwiftUI

struct PhoneNotificationMessageView: View {
  let destination: RuntimeNotificationDestination
  let onDismiss: () -> Void

  var body: some View {
    NavigationStack {
      PhonePage {
        VStack(alignment: .leading, spacing: CompanionSpacing.large) {
          Image(systemName: destination == .recoveryMessage ? "moon.stars.fill" : "figure.walk")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(
              destination == .recoveryMessage ? CompanionPalette.blue : CompanionPalette.mint
            )
            .accessibilityHidden(true)

          Text(destination == .recoveryMessage ? "Mori 的恢复来信" : "Mori 的活动来信")
            .font(.largeTitle.bold())
            .fixedSize(horizontal: false, vertical: true)

          Text(
            destination == .recoveryMessage
              ? "今天可以慢一点。你可以休息、换个更轻的任务，或者什么也不做。"
              : "如果愿意，我们可以一起走两分钟；不回应也不会失去成长。"
          )
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
