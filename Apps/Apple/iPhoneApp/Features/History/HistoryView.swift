import SwiftUI

struct HistoryView: View {
  let model: PhonePresentationModel

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
        PhoneDataBadge(model: model)
          .padding(.top, CompanionSpacing.small)

        CompanionCard {
          Text("近 7 日状态")
            .font(.headline)
          Text("只和你自己的近期状态比较")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          HStack {
            Label("恢复", systemImage: "circle.fill")
              .foregroundStyle(CompanionPalette.blue)
            Label("活动", systemImage: "circle.fill")
              .foregroundStyle(CompanionPalette.mint)
          }
          .font(.caption.weight(.semibold))
          .padding(.top, CompanionSpacing.medium)

          if model.history.isEmpty {
            ContentUnavailableView(
              "趋势正在积累",
              systemImage: "chart.bar.xaxis",
              description: Text("至少保留两天已知数据后再开始比较；缺失日不会按零计算。")
            )
            .frame(height: 150)
            .accessibilityIdentifier("phone.history-empty")
          } else {
            HStack(alignment: .bottom, spacing: 10) {
              ForEach(model.history) { day in
                VStack(spacing: 6) {
                  HStack(alignment: .bottom, spacing: 3) {
                    historyBar(day.recovery, color: CompanionPalette.blue)
                    historyBar(day.activity, color: CompanionPalette.mint)
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
            .frame(height: 150, alignment: .bottom)
            .accessibilityIdentifier("phone.history-chart")
          }

          Text(model.trendSummary)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(CompanionPalette.gold)
        }

        Text("最近发生")
          .font(.headline)
          .padding(.top, CompanionSpacing.small)

        if model.activityLog.isEmpty {
          Text("还没有可显示的事件。完成一次健康同步或宠物互动后会出现在这里。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, CompanionSpacing.medium)
        }

        ForEach(model.activityLog) { log in
          CompanionCard {
            HStack(spacing: CompanionSpacing.medium) {
              Image(systemName: log.symbol)
                .foregroundStyle(CompanionPalette.mint)
                .frame(width: 38, height: 38)
                .background(CompanionPalette.mintSoft, in: Circle())
              VStack(alignment: .leading, spacing: 2) {
                Text(log.title)
                  .font(.subheadline.weight(.semibold))
                Text(log.detail)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                Text(log.time)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
              }
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("phone.log.\(log.id)")
        }
      }
    }
    .navigationTitle("历史")
    .accessibilityIdentifier("phone.history")
  }

  private func historyBar(_ value: Double?, color: Color) -> some View {
    Group {
      if let value {
        Capsule()
          .fill(color)
          .frame(width: 9, height: max(12, value * 120))
      } else {
        Capsule()
          .stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2]))
          .frame(width: 9, height: 12)
      }
    }
  }

  private func accessibilityLabel(for day: PhoneHistoryDay) -> String {
    let recovery = day.recovery.map { String(Int($0 * 100)) } ?? "缺失"
    let activity = day.activity.map { String(Int($0 * 100)) } ?? "缺失"
    return "\(day.weekday)日，恢复相对值 \(recovery)，活动相对值 \(activity)"
  }
}
