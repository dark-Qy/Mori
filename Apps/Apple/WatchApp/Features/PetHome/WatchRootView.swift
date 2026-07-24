import AppRuntime
import SwiftUI
import WatchKit

struct WatchRootView: View {
  @ObservedObject var store: WatchAppStore
  @State private var interactionCount = 0
  @State private var showsDataSourcePicker = false
  @State private var sceneReactionSequence = 0
  @State private var sceneReaction: WatchSceneReaction?

  private var model: WatchPresentationModel { store.model }
  private var showsTouchExchangeDirectly: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains("--touch-exchange-direct")
    #else
      false
    #endif
  }

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
        if showsTouchExchangeDirectly {
          TouchExchangeView(
            localCard: store.touchExchangeLocalCard,
            socialSharingEnabled: store.isTouchExchangeSharingEnabled,
            socialSharingReady: store.isTouchExchangeSharingReady
          )
        } else if let destination = store.notificationDestination {
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
          PetHeroCard(model: model, reaction: sceneReaction) { interaction in
            interactionCount += 1
            Task { await store.interact(with: interaction) }
          }
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
            onAdvance: {
              Task {
                if await store.advanceMainStory() {
                  triggerSceneReaction(.storyReaction)
                }
              }
            }
          )
          HealthPillRow(metrics: model.metrics)
          interactionCard
          destinationLinks
          DataSourceCard(model: model)
          if store.dataSourceSelectionAvailable {
            Button {
              showsDataSourcePicker = true
            } label: {
              Label(
                store.isRefreshingHealth
                  ? "读取中…"
                  : "数据 · \(store.selectedDataSource.displayName)",
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
    .sheet(isPresented: $showsDataSourcePicker) {
      WatchDataSourcePicker(store: store, isPresented: $showsDataSourcePicker)
    }
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
        if interactionCount == 0
          && (model.requestsCompanionInteraction || !store.actionCompleted)
        {
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
          if model.requestsCompanionInteraction {
            interactionCount += 1
            triggerSceneReaction(.touchHead)
            Task { await store.interact(with: .touchHead) }
          } else if model.isLive {
            Task {
              if await store.completeSuggestedAction() {
                triggerSceneReaction(.actionSuccess)
              }
            }
          } else {
            interactionCount += 1
            triggerSceneReaction(.touchHead)
            Task { await store.interact(with: .touchHead) }
          }
        } label: {
          Label(
            interactionCount == 0
              && (model.requestsCompanionInteraction || !store.actionCompleted)
              ? model.actionTitle : "今天已回应",
            systemImage: "hand.tap.fill"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AdventurePalette.mint)
        .disabled(
          store.isCompletingAction
            || (store.actionCompleted && !model.requestsCompanionInteraction)
            || !model.allowsInteraction
        )
        .accessibilityIdentifier("watch.interact")
      }
    }
  }

  private func triggerSceneReaction(_ animation: WatchCharacterAnimation) {
    sceneReactionSequence += 1
    sceneReaction = WatchSceneReaction(
      sequence: sceneReactionSequence,
      animation: animation
    )
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

      NavigationLink {
        TouchExchangeView(
          localCard: store.touchExchangeLocalCard,
          socialSharingEnabled: store.isTouchExchangeSharingEnabled,
          socialSharingReady: store.isTouchExchangeSharingReady
        )
      } label: {
        DestinationRow(
          title: "触碰交换",
          detail:
            !store.isTouchExchangeSharingReady
            ? "正在自动同步好友分享"
            : store.isTouchExchangeSharingEnabled
              ? "和附近的宠物交换遇见卡"
              : "好友分享已关闭",
          systemImage: "wave.3.right.circle.fill"
        )
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("watch.open-touch-exchange")
    }
  }
}

private struct WatchDataSourcePicker: View {
  @ObservedObject var store: WatchAppStore
  @Binding var isPresented: Bool

  var body: some View {
    NavigationStack {
      List(CompanionDataSource.allCases, id: \.self) { source in
        Button {
          isPresented = false
          Task { await store.selectDataSource(source) }
        } label: {
          HStack {
            Text(source.displayName)
            Spacer()
            if source == store.selectedDataSource {
              Image(systemName: "checkmark")
                .foregroundStyle(AdventurePalette.mint)
                .accessibilityHidden(true)
            }
          }
        }
        .accessibilityIdentifier("watch.data-source.option.\(source.rawValue)")
      }
      .navigationTitle("数据来源")
      .accessibilityIdentifier("watch.data-source-picker")
    }
  }
}

private struct PetHeroCard: View {
  let model: WatchPresentationModel
  let reaction: WatchSceneReaction?
  let onInteraction: (WatchCharacterAnimation) -> Void

  var body: some View {
    VStack(spacing: AdventureSpacing.small) {
      CompanionSceneView(
        scene: model.scene,
        reaction: reaction,
        onInteraction: onInteraction
      )
      .aspectRatio(352 / 430, contentMode: .fit)

      HStack(alignment: .firstTextBaseline) {
        Text("Mori · Lv.\(model.level)")
          .font(.headline)
          .accessibilityIdentifier("watch.pet-level")
        Spacer(minLength: 6)
        Label("\(model.vitality)", systemImage: "leaf.fill")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(AdventurePalette.mint)
      }

      Text(model.petMood)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

      ProgressView(value: Double(model.vitality), total: 100)
        .tint(AdventurePalette.mint)
        .accessibilityIdentifier("watch.vitality-progress")
        .accessibilityLabel("生命力")
        .accessibilityValue("\(model.vitality)/100")
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
