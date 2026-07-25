import AppRuntime
import SwiftUI

struct WatchNotificationMessageView: View {
  let destination: RuntimeNotificationDestination
  let onDismiss: () -> Void

  private var content: (symbol: String, color: Color, title: String, detail: String) {
    switch destination {
    case .recoveryMessage:
      (
        "moon.stars.fill",
        AdventurePalette.blue,
        "今天可以慢一点",
        "休息、换个轻任务，或暂时不回应都可以。"
      )
    case .activityMessage:
      (
        "figure.walk",
        AdventurePalette.mint,
        "要不要走两分钟？",
        "这是邀请，不是命令；不完成也不会失去成长。"
      )
    case .careMessage:
      (
        "heart.text.square.fill",
        AdventurePalette.rose,
        "我可以陪你一会儿",
        "不用解释，也不需要立刻变好。"
      )
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AdventureSpacing.medium) {
        Image(systemName: content.symbol)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(content.color)
          .frame(maxWidth: .infinity)
          .accessibilityHidden(true)

        Text(content.title)
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
        Text(content.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Label("打开来信不会自动完成任务", systemImage: "checkmark.shield.fill")
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
