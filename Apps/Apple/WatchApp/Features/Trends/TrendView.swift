import SwiftUI

struct TrendView: View {
  let model: WatchPresentationModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AdventureSpacing.medium) {
        MockBadge(scenarioName: model.scenario.displayName)
        Text("你的节奏，不是分数比赛")
          .font(.headline)
        Text("趋势只和你自己的近期状态比较。缺失数据不会扣除生命力。")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        AdventureCard {
          VStack(alignment: .leading, spacing: AdventureSpacing.small) {
            HStack {
              Label("恢复", systemImage: "circle.fill")
                .foregroundStyle(AdventurePalette.blue)
              Label("活动", systemImage: "circle.fill")
                .foregroundStyle(AdventurePalette.mint)
            }
            .font(.caption2.weight(.semibold))

            HStack(alignment: .bottom, spacing: 5) {
              ForEach(model.trends) { day in
                VStack(spacing: 4) {
                  HStack(alignment: .bottom, spacing: 2) {
                    Capsule()
                      .fill(AdventurePalette.blue)
                      .frame(width: 5, height: max(8, day.recovery * 68))
                    Capsule()
                      .fill(AdventurePalette.mint)
                      .frame(width: 5, height: max(8, day.activity * 68))
                  }
                  Text(day.weekday)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                  "星期\(day.weekday)，恢复 \(Int(day.recovery * 100))，活动 \(Int(day.activity * 100))")
              }
            }
            .frame(height: 90, alignment: .bottom)
            .accessibilityIdentifier("watch.trend-chart")
          }
        }

        AdventureCard {
          Label(model.trendSummary, systemImage: "lightbulb.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AdventurePalette.gold)
          Text(model.scenario == .recoveryLow ? "最近恢复连续走低，今天的主线已自动变轻。" : "近 7 天入睡时间更稳定，节律比上周更连贯。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, AdventureSpacing.page)
      .padding(.bottom, AdventureSpacing.large)
    }
    .background(AdventurePalette.background.ignoresSafeArea())
    .navigationTitle("7 日趋势")
    .accessibilityIdentifier("watch.trends")
  }
}
