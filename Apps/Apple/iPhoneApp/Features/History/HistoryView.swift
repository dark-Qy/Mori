import SwiftUI

struct PhoneMemoriesView: View {
  let model: PhonePresentationModel

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: 0) {
        if model.sharedMemories.isEmpty {
          VStack(spacing: CompanionSpacing.medium) {
            Image(systemName: "book.closed")
              .font(.system(size: 42, weight: .regular))
              .foregroundStyle(CompanionPalette.secondaryText)
              .accessibilityHidden(true)
            Text("还没有共同回忆")
              .font(.headline)
              .foregroundStyle(CompanionPalette.ink)
            Text("只有 iPhone 在 22:00 后成功封存的共同经历才会出现在这里；当天数字不会提前冒充回忆。")
              .font(.subheadline)
              .foregroundStyle(CompanionPalette.secondaryText)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 80)
          .accessibilityIdentifier("phone.memories.empty")
        } else {
          ForEach(model.sharedMemories) { memory in
            MemoryTimelineEntry(memory: memory)
          }
        }
      }
    }
    .navigationTitle("共同回忆")
    .accessibilityIdentifier("phone.memories")
  }
}

private struct MemoryTimelineEntry: View {
  let memory: PhoneMemoryPresentation

  var body: some View {
    HStack(alignment: .top, spacing: CompanionSpacing.medium) {
      VStack(spacing: 0) {
        Circle()
          .fill(CompanionPalette.mint)
          .frame(width: 10, height: 10)
          .padding(.top, 7)
        Rectangle()
          .fill(Color.secondary.opacity(0.22))
          .frame(width: 1)
          .frame(maxHeight: .infinity)
      }

      VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
        Text(memory.dayLabel)
          .font(.headline)

        ZStack(alignment: .bottom) {
          Image("scene_\(memory.sceneID)_large")
            .resizable()
            .interpolation(.none)
            .scaledToFill()

          LinearGradient(
            colors: [.clear, .black.opacity(0.24)],
            startPoint: .center,
            endPoint: .bottom
          )

          Image("character_penguin_idle_resting_00")
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: 150, height: 164)
            .padding(.bottom, 10)
        }
        .aspectRatio(1.45, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)

        Text(memory.narrative)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("phone.memory.\(memory.id).narrative")

        HStack(spacing: CompanionSpacing.large) {
          if let steps = memory.steps {
            Label(
              "\(steps.formatted(.number.grouping(.automatic)))步",
              systemImage: "figure.walk"
            )
          }
          if let sleepMinutes = memory.sleepMinutes {
            Label(
              Self.sleepText(sleepMinutes),
              systemImage: "moon.fill"
            )
          }
        }
        .font(.footnote)
        .foregroundStyle(CompanionPalette.secondaryText)
        .accessibilityIdentifier("phone.memory.\(memory.id).facts")

        Text("这些数字只记录已知事实，不是对健康或情绪的判断。")
          .font(.caption)
          .foregroundStyle(CompanionPalette.secondaryText)
          .padding(.bottom, CompanionSpacing.large)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("phone.memory.\(memory.id)")
  }

  private static func sleepText(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)小时" : "\(hours)小时\(remainder)分"
  }
}
