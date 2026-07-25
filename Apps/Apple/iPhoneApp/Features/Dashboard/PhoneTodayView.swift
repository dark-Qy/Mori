import SwiftUI

struct PhoneTodayView: View {
  @ObservedObject var store: PhoneAppStore

  private var task: PhoneRecommendedTask? {
    store.mockExperience.recommendedTask
  }

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.large) {
        header
          .padding(.top, CompanionSpacing.small)

        if store.companionExperienceAvailable, let task {
          recommendedTask(task)
        } else if store.companionExperienceAvailable {
          noRecommendedTask
        } else {
          unavailableTask
        }

        exactFacts
        secondaryTasks
        todayRecord

        if let status = store.statusMessage {
          Text(status)
            .font(.footnote)
            .foregroundStyle(CompanionPalette.secondaryText)
            .accessibilityIdentifier("phone.today.status")
        }
      }
    }
    .navigationTitle("今天")
    .accessibilityIdentifier("phone.today")
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Mori 今天想和你做一件小事")
          .font(.title2.bold())
        Text(
          store.mockExperience.completedTaskIDs.isEmpty
            ? "今天还没有完成"
            : "今天已完成 \(store.mockExperience.completedTaskIDs.count) 件"
        )
          .font(.subheadline)
          .foregroundStyle(CompanionPalette.secondaryText)
          .accessibilityIdentifier("phone.today.completed-count")
      }
      Spacer()
      if store.companionExperienceAvailable {
        Label(
          "\(store.activeCoinBalance)",
          systemImage: "circle.fill"
        )
        .font(.subheadline.bold())
        .foregroundStyle(CompanionPalette.gold)
        .accessibilityLabel("金币 \(store.activeCoinBalance) 枚")
        .accessibilityIdentifier("phone.today.coins")
      }
    }
  }

  private func recommendedTask(_ task: PhoneRecommendedTask) -> some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
      Label("Mori 推荐", systemImage: "sparkles")
        .font(.subheadline.bold())
        .foregroundStyle(CompanionPalette.mint)

      Text(task.title)
        .font(.title3.bold())
        .accessibilityIdentifier("phone.today.recommended-title")
      Text(task.detail)
        .font(.subheadline)
        .foregroundStyle(CompanionPalette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Label("\(task.reward) 金币", systemImage: "circle.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(CompanionPalette.gold)
        Spacer()
        Button {
          Task { await store.completeRecommendedTask() }
        } label: {
          Label("我完成了", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .tint(CompanionPalette.mint)
        .disabled(store.isSavingMockExperience)
        .accessibilityIdentifier("phone.today.complete-recommended")
      }
    }
    .padding(CompanionSpacing.medium)
    .background(
      CompanionPalette.surface,
      in: RoundedRectangle(cornerRadius: CompanionRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("phone.today.recommended")
  }

  private var noRecommendedTask: some View {
    ContentUnavailableView(
      "现在没有推荐任务",
      systemImage: "sparkles",
      description: Text("只有出现可以确认的现实事件，且同类冷却结束后，Mori 才会提出一件小事。")
    )
    .frame(maxWidth: .infinity)
    .padding(.vertical, CompanionSpacing.large)
    .accessibilityIdentifier("phone.today.recommended-empty")
  }

  private var unavailableTask: some View {
    ContentUnavailableView(
      store.model.allowsInteraction ? "任务账本待接入" : "Mock 场景无效",
      systemImage: "checklist",
      description: Text(
        store.model.allowsInteraction
          ? "真实数据模式不会回退到演示任务。"
          : "请到设置中选择有效的 Mock 数据。"
      )
    )
    .frame(maxWidth: .infinity)
    .padding(.vertical, CompanionSpacing.large)
    .accessibilityIdentifier("phone.today.task-unavailable")
  }

  private var exactFacts: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.small) {
      Text("自动记录")
        .font(.headline)
      Label(store.model.stepsText, systemImage: "figure.walk")
        .accessibilityIdentifier("phone.today.steps")
      Divider()
      Label(store.model.sleepText, systemImage: "moon.fill")
        .accessibilityIdentifier("phone.today.sleep")
      Text("这里只显示本机已有的数值，不把它们解释成健康结论，也不重复生成奖励任务。")
        .font(.caption)
        .foregroundStyle(CompanionPalette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var secondaryTasks: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.small) {
      Text("其他小事")
        .font(.headline)
      Text("Mori 暂时没有提出别的事。以后同时出现时也会保持精简。")
        .font(.subheadline)
        .foregroundStyle(CompanionPalette.secondaryText)
        .accessibilityIdentifier("phone.today.secondary-empty")
    }
  }

  private var todayRecord: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.small) {
      Text("今天的陪伴记录")
        .font(.headline)
      Text(store.model.currentFactNarrative)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("phone.today.record")
      Text("这仍是当天记录；只有 iPhone 在 22:00 后成功封存的内容才会进入「回忆」。")
        .font(.footnote)
        .foregroundStyle(CompanionPalette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("phone.today.memory-boundary")
    }
  }
}
