import SwiftUI

struct WatchRootView: View {
  private let model = WatchPresentationModel.fromLaunchArguments()
  @State private var interactionCount = 0

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: AdventureSpacing.medium) {
          statusHeader
          PetHeroCard(model: model)
          HealthPillRow(metrics: model.metrics)
          TodayQuestCard(quest: model.quest)
          interactionCard
          destinationLinks
          DataSourceCard(model: model)
        }
        .padding(.horizontal, AdventureSpacing.page)
        .padding(.bottom, AdventureSpacing.large)
      }
      .background(AdventurePalette.background.ignoresSafeArea())
      .navigationTitle("Mori")
      .navigationBarTitleDisplayMode(.inline)
    }
    .tint(AdventurePalette.mint)
    .accessibilityIdentifier("watch.pet-home")
  }

  private var statusHeader: some View {
    HStack(spacing: AdventureSpacing.small) {
      MockBadge(scenarioName: model.scenario.displayName)
      Spacer(minLength: 4)
      Label(model.dayStatus, systemImage: "sparkles")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(AdventurePalette.gold)
        .accessibilityIdentifier("watch.day-status")
    }
  }

  private var interactionCard: some View {
    AdventureCard {
      VStack(alignment: .leading, spacing: AdventureSpacing.small) {
        if interactionCount == 0 {
          Text(model.petPrompt)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("watch.pet-prompt")
        } else {
          Label("Mori 蹭了蹭你：一起慢慢变好。", systemImage: "heart.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(AdventurePalette.rose)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("watch.interaction-response")
        }

        Button {
          interactionCount += 1
        } label: {
          Label(interactionCount == 0 ? "回应 Mori" : "再摸摸它", systemImage: "hand.tap.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AdventurePalette.mint)
        .accessibilityIdentifier("watch.interact")
      }
    }
  }

  private var destinationLinks: some View {
    VStack(spacing: AdventureSpacing.small) {
      NavigationLink {
        TrendView(model: model)
      } label: {
        DestinationRow(
          title: "7 日趋势",
          detail: model.trendSummary,
          systemImage: "chart.xyaxis.line"
        )
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("watch.open-trends")

      NavigationLink {
        MessageInboxView(messages: model.messages)
      } label: {
        DestinationRow(
          title: "Mori 来信",
          detail: "\(model.unreadMessageCount) 条新消息",
          systemImage: "envelope.badge.fill"
        )
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("watch.open-messages")
    }
  }
}

private struct PetHeroCard: View {
  let model: WatchPresentationModel

  var body: some View {
    VStack(spacing: AdventureSpacing.medium) {
      ZStack {
        Circle()
          .fill(AdventurePalette.mint.opacity(0.18))
          .frame(width: 74, height: 74)
        Circle()
          .stroke(AdventurePalette.mint.opacity(0.35), lineWidth: 1)
          .frame(width: 64, height: 64)
        Image(systemName: model.petSymbol)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(AdventurePalette.mint)
          .symbolEffect(.bounce, value: model.vitality)
      }
      .accessibilityHidden(true)

      VStack(spacing: 2) {
        Text("Mori · Lv.\(model.level)")
          .font(.headline)
          .accessibilityIdentifier("watch.pet-level")
        Text(model.petMood)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: 4) {
        HStack {
          Label("生命力", systemImage: "leaf.fill")
          Spacer()
          Text("\(model.vitality)/100")
            .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        ProgressView(value: Double(model.vitality), total: 100)
          .tint(AdventurePalette.mint)
          .accessibilityIdentifier("watch.vitality-progress")
      }
    }
    .padding(AdventureSpacing.medium)
    .background {
      RoundedRectangle(cornerRadius: AdventureRadius.hero, style: .continuous)
        .fill(
          LinearGradient(
            colors: [AdventurePalette.surface, AdventurePalette.mint.opacity(0.09)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
    }
    .overlay {
      RoundedRectangle(cornerRadius: AdventureRadius.hero, style: .continuous)
        .stroke(AdventurePalette.mint.opacity(0.14), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("watch.pet-hero")
  }
}

private struct HealthPillRow: View {
  let metrics: [WatchMetric]

  var body: some View {
    HStack(spacing: 5) {
      ForEach(metrics) { metric in
        VStack(spacing: 3) {
          Image(systemName: metric.symbol)
            .font(.caption2)
            .foregroundStyle(metric.color)
          Text(metric.shortValue)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
          Text(metric.shortTitle)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
          AdventurePalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title)，\(metric.value)")
        .accessibilityIdentifier("watch.metric.\(metric.id)")
      }
    }
  }
}

private struct TodayQuestCard: View {
  let quest: WatchQuest

  var body: some View {
    AdventureCard {
      VStack(alignment: .leading, spacing: AdventureSpacing.small) {
        HStack {
          Label("今日主线", systemImage: "map.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(AdventurePalette.gold)
          Spacer()
          Text("+\(quest.reward) XP")
            .font(.caption2.monospacedDigit().weight(.bold))
            .foregroundStyle(AdventurePalette.mint)
        }
        Text(quest.title)
          .font(.subheadline.weight(.semibold))
          .accessibilityIdentifier("watch.quest-title")
        Text(quest.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
          ProgressView(value: quest.progress)
            .tint(AdventurePalette.gold)
          Text(quest.progressLabel)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("watch.today-quest")
  }
}

private struct DestinationRow: View {
  let title: String
  let detail: String
  let systemImage: String

  var body: some View {
    HStack(spacing: AdventureSpacing.small) {
      Image(systemName: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(AdventurePalette.mint)
        .frame(width: 26, height: 26)
        .background(AdventurePalette.mint.opacity(0.13), in: Circle())
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 2)
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.bold))
        .foregroundStyle(.tertiary)
    }
    .padding(AdventureSpacing.small)
    .background(
      AdventurePalette.surface,
      in: RoundedRectangle(cornerRadius: AdventureRadius.card, style: .continuous))
  }
}

#Preview {
  WatchRootView()
}
