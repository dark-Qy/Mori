import SwiftUI

struct MessageInboxView: View {
  let messages: [WatchMessage]

  var body: some View {
    List {
      if messages.isEmpty {
        Section {
          VStack(alignment: .leading, spacing: 5) {
            Label("Mori 还没有来信", systemImage: "envelope.open")
              .font(.caption.weight(.semibold))
            Text("合适的时候它会自然出现，不会为了打卡催促你。")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("watch.messages-empty")
        }
      }

      ForEach(messages) { message in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: message.symbol)
            .foregroundStyle(message.tint)
            .frame(width: 22)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            HStack {
              Text(message.title)
                .font(.caption.weight(message.isUnread ? .bold : .semibold))
              Spacer(minLength: 2)
              if message.isUnread {
                Text("新")
                  .font(.caption2.weight(.bold))
                  .foregroundStyle(AdventurePalette.mint)
              }
            }
            Text(message.body)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Text(message.relativeTime)
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch.message.\(message.id)")
      }
    }
    .navigationTitle("Mori 来信")
    .accessibilityIdentifier("watch.messages")
  }
}
