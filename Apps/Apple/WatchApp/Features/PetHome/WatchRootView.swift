import SwiftUI
import WatchKit

struct WatchRootView: View {
  @ObservedObject var store: WatchAppStore
  @State private var interactionCount = 0

  private var model: WatchPresentationModel { store.model }

  var body: some View {
    Group {
      switch store.phase {
      case .loading:
        ProgressView("载入中…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(AdventurePalette.background)
          .accessibilityIdentifier("watch.loading")
      case .onboarding:
        WatchOnboardingView(store: store, isPetIntroduction: false)
      case .petIntroduction:
        WatchOnboardingView(store: store, isPetIntroduction: true)
      case .ready:
        if let destination = store.notificationDestination {
          WatchNotificationMessageView(
            destination: destination,
            onDismiss: store.dismissNotificationDestination
          )
        } else {
          petHome
        }
      }
    }
    .task {
      await store.start()
    }
  }

  private var petHome: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: AdventureSpacing.medium) {
          statusHeader
          if let status = store.statusMessage {
            Text(status)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityIdentifier("watch.status-message")
          }
          TodayQuestCard(
            quest: model.quest,
            isAdvancing: store.isAdvancingStory,
            showsAction: model.isLive,
            onAdvance: { Task { await store.advanceMainStory() } }
          )
          PetHeroCard(model: model)
          HealthPillRow(metrics: model.metrics)
          interactionCard
          destinationLinks
          DataSourceCard(model: model)
          if model.isLive {
            Button {
              Task { await store.connectHealth() }
            } label: {
              Label(
                store.isRefreshingHealth ? "读取中…" : "连接健康数据",
                systemImage: "heart.text.clipboard"
              )
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AdventurePalette.mint)
            .disabled(store.isRefreshingHealth)
            .accessibilityIdentifier("watch.connect-health")
          }
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
      WatchDataBadge(model: model)
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
        if interactionCount == 0 && !store.actionCompleted {
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
          WKInterfaceDevice.current().play(.click)
          if model.isLive {
            Task { await store.completeSuggestedAction() }
          } else {
            interactionCount += 1
          }
        } label: {
          Label(
            interactionCount == 0 && !store.actionCompleted ? model.actionTitle : "今天已回应",
            systemImage: "hand.tap.fill"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AdventurePalette.mint)
        .disabled(store.isCompletingAction || store.actionCompleted || !model.allowsInteraction)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
          .symbolEffect(.bounce, value: reduceMotion ? 0 : model.vitality)
        if let accessory = WatchOutfitAccessory.make(for: model.outfitID) {
          Image(systemName: accessory.symbol)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(accessory.color)
            .offset(x: 26, y: -27)
        }
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
          .frame(minHeight: 44)
          .contentShape(Rectangle())
          .accessibilityIdentifier("watch.vitality-progress")
          .accessibilityLabel("生命力")
          .accessibilityValue("\(model.vitality)/100")
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

private struct WatchOutfitAccessory {
  let symbol: String
  let color: Color

  static func make(for outfitID: String?) -> Self? {
    switch outfitID {
    case "scarf", "soccer_scarf": Self(symbol: "wind", color: AdventurePalette.rose)
    case "leaf": Self(symbol: "leaf.fill", color: AdventurePalette.mint)
    case "star": Self(symbol: "star.fill", color: AdventurePalette.gold)
    case "drop": Self(symbol: "drop.fill", color: AdventurePalette.blue)
    default: nil
    }
  }
}

private struct HealthPillRow: View {
  let metrics: [WatchMetric]
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(spacing: 5) {
          ForEach(metrics) { metric in
            metricPill(metric, horizontal: true)
          }
        }
      } else {
        HStack(spacing: 5) {
          ForEach(metrics) { metric in
            metricPill(metric, horizontal: false)
          }
        }
      }
    }
  }

  @ViewBuilder private func metricPill(_ metric: WatchMetric, horizontal: Bool) -> some View {
    Group {
      if horizontal {
        HStack(spacing: AdventureSpacing.small) {
          metricIcon(metric)
          Text(metric.shortTitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
          Spacer(minLength: 2)
          Text(metric.shortValue)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
        }
      } else {
        VStack(spacing: 3) {
          metricIcon(metric)
          Text(metric.shortValue)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
          Text(metric.shortTitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .padding(.horizontal, horizontal ? 8 : 2)
    .background(
      AdventurePalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(metric.title)，\(metric.value)")
    .accessibilityIdentifier("watch.metric.\(metric.id)")
  }

  private func metricIcon(_ metric: WatchMetric) -> some View {
    Image(systemName: metric.symbol)
      .font(.caption2)
      .foregroundStyle(metric.color)
  }
}

private struct TodayQuestCard: View {
  let quest: WatchQuest
  let isAdvancing: Bool
  let showsAction: Bool
  let onAdvance: () -> Void

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
        if showsAction {
          Button(action: onAdvance) {
            Label(isAdvancing ? "保存中…" : "继续今日主线", systemImage: "book.pages.fill")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .disabled(isAdvancing)
          .accessibilityIdentifier("watch.advance-story")
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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("今日主线进度")
            .accessibilityValue(quest.progressLabel)
          Text(quest.progressLabel)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if let sideStoryTitle = quest.sideStoryTitle {
          Label(sideStoryTitle, systemImage: "sparkles")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AdventurePalette.mint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sideStoryTitle)
            .accessibilityIdentifier("watch.side-story")
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

#if DEBUG
  #Preview {
    WatchRootView(
      store: WatchAppStore(arguments: ["-UITesting", "--mock-scenario=health_normal"])
    )
  }
#endif
