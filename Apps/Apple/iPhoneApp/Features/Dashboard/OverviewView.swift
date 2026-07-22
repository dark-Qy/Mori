import SwiftUI

struct OverviewView: View {
  let model: PhonePresentationModel

  var body: some View {
    PhonePage {
      VStack(spacing: CompanionSpacing.medium) {
        HStack {
          PhoneMockBadge(scenarioName: model.scenario.displayName)
          Spacer()
        }
        .padding(.top, CompanionSpacing.small)

        PetOverviewCard(model: model)

        HStack(spacing: CompanionSpacing.small) {
          ForEach(model.metrics) { metric in
            MetricTile(metric: metric)
          }
        }

        CompanionCard {
          Label("今日主线", systemImage: "map.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(CompanionPalette.gold)
          Text(model.questTitle)
            .font(.headline)
            .padding(.top, 5)
            .accessibilityIdentifier("phone.quest-title")
          Text(model.questDetail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
          ProgressView(value: model.scenario == .activeDay ? 0.8 : 0.62)
            .tint(CompanionPalette.gold)
            .padding(.top, CompanionSpacing.small)
        }
        .accessibilityIdentifier("phone.today-quest")

        CompanionCard {
          Label("数据说明", systemImage: "info.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(CompanionPalette.blue)
          Text("当前为确定性 Mock 数据。恢复、活动和节律只与个人近期状态比较；缺失数据不会造成惩罚。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 5)
        }
        .accessibilityIdentifier("phone.data-explanation")
      }
    }
    .navigationTitle("Mori")
    .accessibilityIdentifier("phone.overview")
  }
}

private struct PetOverviewCard: View {
  let model: PhonePresentationModel

  var body: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
      HStack(spacing: CompanionSpacing.medium) {
        ZStack {
          Circle()
            .fill(Color.white.opacity(0.22))
            .frame(width: 78, height: 78)
          Image(systemName: "pawprint.fill")
            .font(.system(size: 36, weight: .semibold))
            .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text("Mori · Lv.\(model.level)")
            .font(.title3.weight(.bold))
            .accessibilityIdentifier("phone.pet-level")
          Text(model.mood)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.82))
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(spacing: 5) {
        HStack {
          Label("生命力", systemImage: "leaf.fill")
          Spacer()
          Text("\(model.vitality)/100")
            .monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        ProgressView(value: Double(model.vitality), total: 100)
          .tint(.white)
      }

      Label(model.syncStatus, systemImage: "applewatch.radiowaves.left.and.right")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.72))
    }
    .foregroundStyle(.white)
    .padding(CompanionSpacing.large)
    .background {
      LinearGradient(
        colors: [Color(red: 0.055, green: 0.34, blue: 0.27), CompanionPalette.mint],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .clipShape(RoundedRectangle(cornerRadius: CompanionRadius.hero, style: .continuous))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("phone.pet-overview")
  }
}

private struct MetricTile: View {
  let metric: PhoneMetric

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Image(systemName: metric.symbol)
        .foregroundStyle(CompanionPalette.mint)
      Text(metric.value)
        .font(.title3.monospacedDigit().weight(.bold))
      Text(metric.title)
        .font(.caption.weight(.semibold))
      Text(metric.detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
    .padding(CompanionSpacing.small)
    .background(
      CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("phone.metric.\(metric.id)")
  }
}
