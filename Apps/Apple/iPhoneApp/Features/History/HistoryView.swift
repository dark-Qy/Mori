import SwiftUI

struct HistoryView: View {
  let model: PhonePresentationModel

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
        PhoneMockBadge(scenarioName: model.scenario.displayName)
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

          HStack(alignment: .bottom, spacing: 10) {
            ForEach(model.history) { day in
              VStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: 3) {
                  Capsule()
                    .fill(CompanionPalette.blue)
                    .frame(width: 9, height: max(12, day.recovery * 120))
                  Capsule()
                    .fill(CompanionPalette.mint)
                    .frame(width: 9, height: max(12, day.activity * 120))
                }
                Text(day.weekday)
                  .font(.caption2.weight(.medium))
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(
                "星期\(day.weekday)，恢复 \(Int(day.recovery * 100))，活动 \(Int(day.activity * 100))")
            }
          }
          .frame(height: 150, alignment: .bottom)
          .accessibilityIdentifier("phone.history-chart")
        }

        Text("最近发生")
          .font(.headline)
          .padding(.top, CompanionSpacing.small)

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
}
