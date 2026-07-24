import SwiftUI

struct WatchTodayView: View {
  @ObservedObject var store: WatchAppStore

  private var model: WatchPresentationModel { store.model }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Mori 推荐")
          .font(.caption2)
          .foregroundStyle(.secondary)

        if model.isLive {
          noRecommendation
        } else {
          recommendation
        }

        if let steps = model.stepCount, steps > 0 {
          Divider()
          detectedWalk(steps: steps)
        }

        if let sleepMinutes = model.sleepMinutes {
          Divider()
          knownFact(
            symbol: "moon.fill",
            title: "昨晚一起休息了",
            detail: durationText(minutes: sleepMinutes)
          )
        }

        Text("今天只突出一件事；其他内容会保持安静。")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 16)
    }
    .navigationTitle("今天")
    .background(Color.black.ignoresSafeArea())
    .accessibilityIdentifier("watch.today")
  }

  private var recommendation: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .firstTextBaseline) {
        Text("和 Mori 安静待一分钟")
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 6)
        HStack(spacing: 3) {
          MoriCoinMark()
          Text("\(model.mockTaskCoinReward)")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(AdventurePalette.gold)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("奖励 \(model.mockTaskCoinReward) 枚金币")
        .accessibilityRespondsToUserInteraction(false)
        .accessibilityIdentifier("watch.today.reward")
      }

      Text("这件事由你决定是否完成，不根据步数或睡眠结果判定。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button {
        Task { _ = await store.completeSuggestedAction() }
      } label: {
        Label(
          store.actionCompleted
            ? "已经记下"
            : (store.isCompletingAction ? "记录中…" : "完成这件事"),
          systemImage: store.actionCompleted ? "checkmark" : "hand.tap"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(AdventurePalette.mint)
      .disabled(store.actionCompleted || store.isCompletingAction)
      .accessibilityIdentifier("watch.today.complete-recommendation")
    }
    .padding(12)
    .background(
      Color.white.opacity(0.09),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("watch.today.recommendation")
  }

  private var noRecommendation: some View {
    ContentUnavailableView(
      "今天没有新的小事",
      systemImage: "pawprint",
      description: Text("Mori 想到合适的一件事时，会放在这里。")
    )
    .accessibilityIdentifier("watch.today.no-recommendation")
  }

  private func detectedWalk(steps: Int) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "shoeprints.fill")
        .foregroundStyle(AdventurePalette.mint)
        .frame(width: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("一起走过的路")
          .font(.caption.weight(.semibold))
        Text("\(steps.formatted(.number.grouping(.automatic))) 步 · 已自动记录")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("watch.today.detected-walk")
  }

  private func knownFact(
    symbol: String,
    title: String,
    detail: String
  ) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: symbol)
        .foregroundStyle(AdventurePalette.blue)
        .frame(width: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("watch.today.sleep-fact")
  }

  private func durationText(minutes: Int) -> String {
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainder) 分"
  }
}
