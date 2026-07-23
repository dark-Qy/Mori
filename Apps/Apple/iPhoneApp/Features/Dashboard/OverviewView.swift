import SwiftUI

struct OverviewView: View {
  @ObservedObject var store: PhoneAppStore
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var model: PhonePresentationModel { store.model }

  var body: some View {
    PhonePage {
      VStack(spacing: CompanionSpacing.medium) {
        HStack {
          PhoneDataBadge(model: model)
          Spacer()
        }
        .padding(.top, CompanionSpacing.small)

        PetOverviewCard(model: model)

        metricTiles

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
            .foregroundStyle(CompanionPalette.secondaryText)
            .padding(.top, 2)
            .accessibilityIdentifier("phone.quest-detail")
          ProgressView(value: model.questProgress)
            .tint(CompanionPalette.gold)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .padding(.top, CompanionSpacing.small)
            .accessibilityLabel("今日主线进度")
            .accessibilityValue("\(Int(model.questProgress * 100))%")
        }
        .accessibilityIdentifier("phone.today-quest")

        CompanionCard {
          Label("数据说明", systemImage: "info.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(CompanionPalette.blue)
            .accessibilityIdentifier("phone.data-explanation.title")
          Text(model.dataExplanation)
            .font(.footnote)
            .foregroundStyle(CompanionPalette.secondaryText)
            .padding(.top, 5)
            .accessibilityIdentifier("phone.data-explanation.detail")
        }

        if model.isLive {
          Button {
            Task { await store.connectHealth() }
          } label: {
            Label(
              store.isRefreshingHealth ? "正在读取…" : "连接或刷新健康数据",
              systemImage: "heart.text.clipboard"
            )
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .tint(CompanionPalette.mint)
          .disabled(store.isRefreshingHealth)
          .accessibilityIdentifier("phone.connect-health")
        }

        if let status = store.statusMessage {
          Text(status)
            .font(.footnote)
            .foregroundStyle(CompanionPalette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("phone.status-message")
        }
      }
    }
    .navigationTitle("Mori")
    .accessibilityIdentifier("phone.overview")
  }

  @ViewBuilder private var metricTiles: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(spacing: CompanionSpacing.small) {
        ForEach(model.metrics) { metric in
          MetricTile(metric: metric)
        }
      }
    } else {
      HStack(spacing: CompanionSpacing.small) {
        ForEach(model.metrics) { metric in
          MetricTile(metric: metric)
        }
      }
    }
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
            .foregroundStyle(.white)
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
          .frame(minHeight: 44)
          .contentShape(Rectangle())
          .accessibilityLabel("生命力")
          .accessibilityValue("\(model.vitality)/100")
      }

      Label(model.syncStatus, systemImage: "applewatch.radiowaves.left.and.right")
        .font(.caption)
        .foregroundStyle(.white)
    }
    .foregroundStyle(.white)
    .padding(CompanionSpacing.large)
    .background {
      LinearGradient(
        colors: [Color(red: 0.055, green: 0.34, blue: 0.27), CompanionPalette.heroMint],
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
        .font(.caption)
        .foregroundStyle(CompanionPalette.secondaryText)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
    .padding(CompanionSpacing.small)
    .background(
      CompanionPalette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(metric.title)，\(metric.accessibilityValue)。\(metric.detail)")
    .accessibilityIdentifier("phone.metric.\(metric.id)")
  }
}
