import AppRuntime
import SwiftUI

struct WatchNotificationMessageView: View {
  let destination: RuntimeNotificationDestination
  let onDismiss: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AdventureSpacing.medium) {
        Image(systemName: destination == .recoveryMessage ? "moon.stars.fill" : "figure.walk")
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(
            destination == .recoveryMessage ? AdventurePalette.blue : AdventurePalette.mint
          )
          .frame(maxWidth: .infinity)
          .accessibilityHidden(true)

        Text(destination == .recoveryMessage ? "今天可以慢一点" : "要不要走两分钟？")
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
        Text(
          destination == .recoveryMessage
            ? "休息、换个轻任务，或暂时不回应都可以。"
            : "这是邀请，不是命令；不完成也不会失去成长。"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Label("打开来信不会领取奖励", systemImage: "checkmark.shield.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button("回到 Mori") {
          onDismiss()
        }
        .buttonStyle(.borderedProminent)
        .tint(AdventurePalette.mint)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("watch.notification.dismiss")
      }
      .padding(.horizontal, AdventureSpacing.page)
      .padding(.bottom, AdventureSpacing.large)
    }
    .background(AdventurePalette.background.ignoresSafeArea())
    .accessibilityIdentifier("watch.notification.\(destination.rawValue)")
  }
}
