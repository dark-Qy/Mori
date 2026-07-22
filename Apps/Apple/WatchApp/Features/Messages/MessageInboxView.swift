import SwiftUI

struct MessageInboxView: View {
  let messages: [WatchMessage]

  var body: some View {
    ScrollView {
      LazyVStack(spacing: AdventureSpacing.small) {
        if messages.isEmpty {
          AdventureCard {
            Label("Mori 还没有来信", systemImage: "envelope.open")
              .font(.caption.weight(.semibold))
            Text("有规则允许的合适时机时，它可能主动出现；不会为了打卡而催促你。")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.top, 4)
          }
          .accessibilityIdentifier("watch.messages-empty")
        }

        ForEach(messages) { message in
          AdventureCard {
            HStack(alignment: .top, spacing: AdventureSpacing.small) {
              Image(systemName: message.symbol)
                .foregroundStyle(message.tint)
                .frame(width: 28, height: 28)
                .background(message.tint.opacity(0.13), in: Circle())
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 3) {
                HStack {
                  Text(message.title)
                    .font(.caption.weight(message.isUnread ? .bold : .semibold))
                  Spacer(minLength: 2)
                  if message.isUnread {
                    Circle()
                      .fill(AdventurePalette.mint)
                      .frame(width: 6, height: 6)
                      .accessibilityLabel("未读")
                  }
                }
                Text(message.body)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
                Text(message.relativeTime)
                  .font(.caption2.weight(.medium))
                  .foregroundStyle(.tertiary)
              }
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("watch.message.\(message.id)")
        }
      }
      .padding(.horizontal, AdventureSpacing.page)
      .padding(.bottom, AdventureSpacing.large)
    }
    .background(AdventurePalette.background.ignoresSafeArea())
    .navigationTitle("Mori 来信")
    .accessibilityIdentifier("watch.messages")
  }
}
