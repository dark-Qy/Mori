import SwiftUI

struct TrendView: View {
  let model: WatchPresentationModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: AdventureSpacing.medium) {
        WatchDataBadge(model: model)
        Text("你的节奏，不是分数比赛")
          .font(.headline)
        Text("趋势只和你自己的近期状态比较。缺失数据不会扣除生命力。")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if model.trends.isEmpty {
          AdventureCard {
            Label("趋势正在积累", systemImage: "chart.bar.xaxis")
              .font(.caption.weight(.semibold))
              .foregroundStyle(AdventurePalette.blue)
            Text("至少保留两天已知数据后再显示图表；缺失日不会按零计算。")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.top, 4)
          }
          .accessibilityIdentifier("watch.trend-empty")
        } else {
          AdventureCard {
            VStack(alignment: .leading, spacing: AdventureSpacing.small) {
              HStack {
                Label("恢复", systemImage: "moon.fill")
                  .foregroundStyle(AdventurePalette.blue)
                Label("活动", systemImage: "figure.walk")
                  .foregroundStyle(AdventurePalette.mint)
              }
              .font(.caption2.weight(.semibold))

              HStack(alignment: .bottom, spacing: 5) {
                ForEach(model.trends) { day in
                  VStack(spacing: 4) {
                    HStack(alignment: .bottom, spacing: 2) {
                      trendBar(day.recovery, color: AdventurePalette.blue, style: .recovery)
                      trendBar(day.activity, color: AdventurePalette.mint, style: .activity)
                    }
                    Text(day.weekday)
                      .font(.caption2.weight(.medium))
                      .foregroundStyle(.secondary)
                  }
                  .frame(maxWidth: .infinity)
                  .accessibilityElement(children: .ignore)
                  .accessibilityLabel(accessibilityLabel(for: day))
                }
              }
              .frame(height: 90, alignment: .bottom)
              .accessibilityIdentifier("watch.trend-chart")
            }
          }
        }

        AdventureCard {
          Label(model.trendSummary, systemImage: "lightbulb.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AdventurePalette.gold)
          Text(model.trendDetail)
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

  private enum BarStyle {
    case recovery
    case activity

    var width: CGFloat { self == .recovery ? 4 : 7 }
    var cornerRadius: CGFloat { self == .recovery ? 3 : 1 }
  }

  private func trendBar(_ value: Double?, color: Color, style: BarStyle) -> some View {
    Group {
      if let value {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
          .fill(color)
          .frame(width: style.width, height: max(8, value * 68))
      } else {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
          .stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2]))
          .frame(width: style.width, height: 8)
      }
    }
  }

  private func accessibilityLabel(for day: WatchTrendDay) -> String {
    let recovery = day.recovery.map { String(Int($0 * 100)) } ?? "缺失"
    let activity = day.activity.map { String(Int($0 * 100)) } ?? "缺失"
    return "\(day.weekday)日，恢复相对值 \(recovery)，活动相对值 \(activity)"
  }
}
