import SwiftUI

struct DataSourceCard: View {
  let model: WatchPresentationModel

  var body: some View {
    NavigationLink {
      ExplanationView(model: model)
    } label: {
      HStack(spacing: AdventureSpacing.small) {
        Image(systemName: "info.circle.fill")
          .foregroundStyle(AdventurePalette.blue)
        VStack(alignment: .leading, spacing: 1) {
          Text("为什么是这个状态？")
            .font(.caption.weight(.semibold))
          Text("查看数据来源与计算说明")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 2)
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.tertiary)
      }
      .padding(AdventureSpacing.small)
      .background(
        AdventurePalette.blue.opacity(0.08),
        in: RoundedRectangle(cornerRadius: AdventureRadius.card, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("watch.open-explanation")
  }
}

private struct ExplanationView: View {
  let model: WatchPresentationModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AdventureSpacing.medium) {
        WatchDataBadge(model: model)
        explanationRow(
          symbol: "moon.stars.fill", title: "恢复", detail: "睡眠时长、睡眠阶段和静息心率相对个人基线。",
          color: AdventurePalette.blue)
        explanationRow(
          symbol: "figure.walk", title: "活动", detail: "步数和已记录训练；不会要求每天达到同一目标。",
          color: AdventurePalette.mint)
        explanationRow(
          symbol: "clock.fill", title: "节律", detail: "近期入睡、起床和活动时间的一致性。",
          color: AdventurePalette.gold)
        Divider()
        Text(model.isLive ? "本机数据说明" : "演示模式说明")
          .font(.caption.weight(.bold))
        Text(model.dataExplanation)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, AdventureSpacing.page)
      .padding(.bottom, AdventureSpacing.large)
    }
    .background(AdventurePalette.background.ignoresSafeArea())
    .navigationTitle("状态来源")
    .accessibilityIdentifier("watch.explanation")
  }

  private func explanationRow(symbol: String, title: String, detail: String, color: Color)
    -> some View
  {
    AdventureCard {
      Label(title, systemImage: symbol)
        .font(.caption.weight(.bold))
        .foregroundStyle(color)
      Text(detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
