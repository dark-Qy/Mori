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
            .foregroundStyle(CompanionPalette.secondaryText)

          HStack {
            Label("恢复", systemImage: "moon.fill")
              .foregroundStyle(CompanionPalette.blue)
            Label("活动", systemImage: "figure.walk")
              .foregroundStyle(CompanionPalette.mint)
          }
          .font(.caption.weight(.semibold))
          .padding(.top, CompanionSpacing.medium)

          if model.history.isEmpty {
            VStack(spacing: CompanionSpacing.small) {
              Image(systemName: "chart.bar.xaxis")
                .font(.title2.weight(.semibold))
                .foregroundStyle(CompanionPalette.mint)
              Text("趋势正在积累")
                .font(.headline)
              Text("至少保留两天已知数据后再开始比较；缺失日不会按零计算。")
                .font(.subheadline)
                .foregroundStyle(CompanionPalette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .padding(.vertical, CompanionSpacing.small)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("phone.history-empty")
          } else {
            HStack(alignment: .bottom, spacing: 10) {
              ForEach(model.history) { day in
                VStack(spacing: 6) {
                  HStack(alignment: .bottom, spacing: 3) {
                    historyBar(day.recovery, color: CompanionPalette.blue, style: .recovery)
                    historyBar(day.activity, color: CompanionPalette.mint, style: .activity)
                  }
                  Text(day.weekday)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(CompanionPalette.secondaryText)
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
            .foregroundStyle(CompanionPalette.secondaryText)
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
                  .foregroundStyle(CompanionPalette.secondaryText)
                Text(log.time)
                  .font(.caption)
                  .foregroundStyle(CompanionPalette.secondaryText)
              }
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier(accessibilityIdentifier(for: log))
        }
      }
    }
    .navigationTitle("历史")
    .accessibilityIdentifier("phone.history")
  }

  private enum BarStyle {
    case recovery
    case activity

    var width: CGFloat { self == .recovery ? 7 : 11 }
    var cornerRadius: CGFloat { self == .recovery ? 4 : 2 }
  }

  private func historyBar(_ value: Double?, color: Color, style: BarStyle) -> some View {
    Group {
      if let value {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
          .fill(color)
          .frame(width: style.width, height: max(12, value * 120))
      } else {
        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
          .stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2]))
          .frame(width: style.width, height: 12)
      }
    }
  }

  private func accessibilityLabel(for day: PhoneHistoryDay) -> String {
    let recovery = day.recovery.map { String(Int($0 * 100)) } ?? "缺失"
    let activity = day.activity.map { String(Int($0 * 100)) } ?? "缺失"
    return "\(day.weekday)日，恢复相对值 \(recovery)，活动相对值 \(activity)"
  }

  private func accessibilityIdentifier(for log: PhoneActivityLog) -> String {
    log.id.hasPrefix("rule-") ? "phone.log.rule" : "phone.log.\(log.id)"
  }
}
