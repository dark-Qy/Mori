import SwiftUI

struct PhoneMemoriesView: View {
  @ObservedObject var store: PhoneAppStore
  @State private var showsMemoryManager = false
  @State private var pendingDeletion: PhoneWeeklyMemory?

  private var model: PhonePresentationModel { store.model }

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.large) {
        HStack {
          PhoneDataBadge(model: model)
          Spacer()
        }
        .padding(.top, CompanionSpacing.small)

        memoryIntro

        if let dailyMoments = model.dailyMomentCollection {
          DailyMomentsSection(collection: dailyMoments)
        } else if !model.sharedMemories.isEmpty {
          VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
            ForEach(model.sharedMemories) { memory in
              MemoryTimelineEntry(memory: memory)
            }
          }
        }

        if !store.visibleWeeklyMemories.isEmpty {
          weeklySection
        } else if model.dailyMomentCollection != nil {
          Label(
            "本周时刻还在收集中",
            systemImage: "calendar.badge.clock"
          )
          .font(.subheadline)
          .foregroundStyle(CompanionPalette.secondaryText)
          .accessibilityIdentifier("phone.weekly-memory.collecting")
        } else if model.sharedMemories.isEmpty {
          WeeklyMemoryEmptyState(
            isLoading: store.isPreparingWeeklyMemory,
            onRetry: { Task { await store.prepareWeeklyMemory(force: true) } }
          )
        }

        if let status = store.weeklyMemoryStatus {
          Label(status, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(CompanionPalette.mint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("phone.weekly-memory-status")
        }
      }
    }
    .navigationTitle("回忆")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showsMemoryManager = true
        } label: {
          Label("管理回忆", systemImage: "slider.horizontal.3")
        }
        .accessibilityIdentifier("phone.weekly-memory.manage")
      }
    }
    .accessibilityIdentifier("phone.memories")
    .task(id: model.mockScenario?.id) {
      await store.prepareWeeklyMemory()
    }
    .sheet(isPresented: $showsMemoryManager) {
      WeeklyMemoryManager(store: store, pendingDeletion: $pendingDeletion)
    }
    .alert(item: $pendingDeletion) { memory in
      Alert(
        title: Text("移除“\(memory.record.title)”？"),
        message: Text("这会把这一周从回忆时间线中移除。"),
        primaryButton: .destructive(Text("移除这周回忆")) {
          Task { await store.deleteWeeklyMemory(memory) }
        },
        secondaryButton: .cancel(Text("保留"))
      )
    }
  }

  private var memoryIntro: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(
        model.dailyMomentCollection == nil
          ? "和 Mori 走过的五周"
          : "今天，白熊记住了这些时刻"
      )
      .font(.title2.weight(.bold))
      Text("一天可以留下多个画面；每日时刻会换新，每周时刻继续沉淀。")
        .font(.subheadline)
        .foregroundStyle(CompanionPalette.secondaryText)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("phone.weekly-memory.quote")
  }

  private var memoryTimeline: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
      ForEach(Array(store.visibleWeeklyMemories.enumerated()), id: \.element.id) {
        index, memory in
        WeeklyTimelineEntry(
          memory: memory,
          isLatest: index == 0,
          showsContinuation: index < store.visibleWeeklyMemories.count - 1,
          onFavorite: {
            Task {
              await store.setWeeklyMemoryFavorite(
                memory,
                value: !memory.record.isFavorite
              )
            }
          },
          onHide: {
            Task { await store.setWeeklyMemoryHidden(memory, value: true) }
          },
          onDelete: { pendingDeletion = memory }
        )
      }
    }
    .accessibilityIdentifier("phone.weekly-memory.timeline")
  }

  private var weeklySection: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
      Text("每周时刻")
        .font(.headline)
      memoryTimeline
    }
  }
}

private struct DailyMomentsSection: View {
  let collection: PhoneDailyMomentCollection

  var body: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("每日时刻")
            .font(.headline)
          Text(collection.dayID)
            .font(.caption.monospacedDigit())
            .foregroundStyle(CompanionPalette.secondaryText)
        }
        Spacer()
        Label(
          collection.isSealed ? "已沉淀" : "整理中",
          systemImage:
            collection.isSealed ? "checkmark.circle.fill" : "clock"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(
          collection.isSealed
            ? CompanionPalette.mint : CompanionPalette.secondaryText
        )
        .accessibilityIdentifier("phone.daily-moments.seal-status")
      }

      ScrollView(.horizontal) {
        LazyHStack(spacing: CompanionSpacing.medium) {
          ForEach(Array(collection.moments.enumerated()), id: \.element.id) {
            index,
            moment in
            DailyMomentCard(
              moment: moment,
              characterID: collection.characterID,
              index: index,
              count: collection.moments.count
            )
          }
        }
        .scrollTargetLayout()
      }
      .scrollIndicators(.hidden)
      .scrollTargetBehavior(.viewAligned)
      .accessibilityIdentifier("phone.daily-moments.gallery")

      Text("每日时刻按本地日期刷新；昨天的内容不会冒充今天。")
        .font(.caption)
        .foregroundStyle(CompanionPalette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct DailyMomentCard: View {
  let moment: PhoneDailyMomentPresentation
  let characterID: String
  let index: Int
  let count: Int

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      Image("scene_\(moment.sceneID)_large")
        .resizable()
        .interpolation(.none)
        .scaledToFill()
        .frame(width: 270, height: 340)
        .clipped()

      LinearGradient(
        colors: [.clear, .black.opacity(0.16), .black.opacity(0.82)],
        startPoint: .top,
        endPoint: .bottom
      )

      Image("character_\(characterID)_\(moment.animationID)_00")
        .resizable()
        .interpolation(.none)
        .scaledToFit()
        .frame(width: 154, height: 168)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 8)
        .padding(.bottom, 86)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(moment.timeLabel)
            .font(.caption.weight(.bold).monospacedDigit())
          Spacer()
          Text("\(index + 1) / \(count)")
            .font(.caption2.monospacedDigit())
        }
        Text(moment.title)
          .font(.headline)
        Text(moment.body)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.86))
          .lineLimit(3)
      }
      .foregroundStyle(.white)
      .padding(CompanionSpacing.medium)
    }
    .frame(width: 270, height: 340)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(moment.timeLabel)，\(moment.title)。\(moment.body)，第 \(index + 1) 个，共 \(count) 个"
    )
    .accessibilityIdentifier("phone.daily-moment.\(moment.id)")
  }
}

private struct WeeklyTimelineEntry: View {
  let memory: PhoneWeeklyMemory
  let isLatest: Bool
  let showsContinuation: Bool
  let onFavorite: () -> Void
  let onHide: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      timelineRail
      memoryCard
    }
    .accessibilityIdentifier("phone.weekly-memory.timeline.\(memory.record.weekOrdinal)")
  }

  private var timelineRail: some View {
    VStack(spacing: 6) {
      Text("\(memory.record.weekOrdinal)")
        .font(.caption.weight(.bold).monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(
          isLatest ? CompanionPalette.blue : CompanionPalette.mint,
          in: Circle()
        )
        .accessibilityHidden(true)

      if showsContinuation {
        Rectangle()
          .fill(CompanionPalette.mint.opacity(0.32))
          .frame(width: 2)
          .frame(maxHeight: .infinity)
          .accessibilityHidden(true)
      }
    }
    .frame(width: 30)
    .frame(maxHeight: .infinity)
  }

  private var memoryCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      WeeklyMemoryCover(memory: memory, isLatest: isLatest)

      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          Text(memory.record.weekLabel)
            .font(.caption.weight(.bold))
            .foregroundStyle(isLatest ? CompanionPalette.blue : CompanionPalette.mint)
          Spacer()
          Text(memory.record.dateLabel)
            .font(.caption.monospacedDigit())
            .foregroundStyle(CompanionPalette.secondaryText)
        }

        Text(memory.record.title)
          .font(.headline)
          .foregroundStyle(CompanionPalette.ink)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier(
            isLatest
              ? "phone.weekly-memory.title"
              : "phone.weekly-memory.title.\(memory.record.weekOrdinal)"
          )

        Text(memory.record.body)
          .font(.subheadline)
          .foregroundStyle(CompanionPalette.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier(
            isLatest
              ? "phone.weekly-memory.body" : "phone.weekly-memory.body.\(memory.record.weekOrdinal)"
          )

        if !memory.record.metrics.isEmpty {
          Divider()
          WeeklyMetricRow(
            metrics: memory.record.metrics,
            weekOrdinal: memory.record.weekOrdinal
          )
        }

        HStack {
          Spacer()
          Button(action: onFavorite) {
            Label(
              memory.record.isFavorite ? "取消收藏" : "收藏回忆",
              systemImage: memory.record.isFavorite ? "heart.fill" : "heart"
            )
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
          }
          .foregroundStyle(CompanionPalette.rose)
          .accessibilityIdentifier(
            isLatest
              ? "phone.weekly-memory.favorite"
              : "phone.weekly-memory.favorite.\(memory.record.weekOrdinal)"
          )

          Menu {
            Button(action: onHide) {
              Label("隐藏这周回忆", systemImage: "eye.slash")
            }
            Button(role: .destructive, action: onDelete) {
              Label("移除这周回忆", systemImage: "trash")
            }
          } label: {
            Label("更多回忆操作", systemImage: "ellipsis")
              .labelStyle(.iconOnly)
              .frame(width: 44, height: 44)
          }
          .accessibilityIdentifier(
            isLatest
              ? "phone.weekly-memory.more"
              : "phone.weekly-memory.more.\(memory.record.weekOrdinal)"
          )
        }
        .frame(height: 34)
      }
      .padding(CompanionSpacing.medium)
    }
    .background(
      CompanionPalette.memoryPaper,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(CompanionPalette.memoryLine.opacity(0.45), lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(isLatest ? "phone.weekly-memory.hero" : "phone.weekly-memory.card")
  }
}

private struct WeeklyMetricRow: View {
  let metrics: [WeeklyMemoryMetric]
  let weekOrdinal: Int

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 8) {
        metricViews
      }
      VStack(alignment: .leading, spacing: 10) {
        metricViews
      }
    }
    .padding(.top, 2)
  }

  @ViewBuilder
  private var metricViews: some View {
    ForEach(metrics) { metric in
      HStack(alignment: .top, spacing: 6) {
        Image(systemName: metric.symbol)
          .font(.caption.weight(.semibold))
          .foregroundStyle(CompanionPalette.blue)
          .frame(width: 18, height: 18)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(metric.value)
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(CompanionPalette.ink)
            .lineLimit(1)
          Text(metric.label)
            .font(.caption2)
            .foregroundStyle(CompanionPalette.secondaryText)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(metric.label)，\(metric.accessibilityValue)")
      .accessibilityIdentifier("phone.weekly-memory.metric.\(metric.id).\(weekOrdinal)")
    }
  }
}

private struct WeeklyMemoryCover: View {
  let memory: PhoneWeeklyMemory
  let isLatest: Bool

  var body: some View {
    Image(memory.record.bundledCoverAssetName)
      .resizable()
      .interpolation(.none)
      .scaledToFill()
      .frame(maxWidth: .infinity)
      .frame(height: isLatest ? 190 : 172)
      .clipped()
      .overlay(alignment: .bottomLeading) {
        Label(memory.record.highlight.title, systemImage: memory.record.highlight.symbol)
          .font(.caption.weight(.bold))
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(Color.black.opacity(0.68), in: Capsule())
          .padding(10)
      }
      .overlay(alignment: .topTrailing) {
        if memory.record.isFavorite {
          Image(systemName: "bookmark.fill")
            .font(.title3)
            .foregroundStyle(CompanionPalette.blue)
            .padding(10)
            .accessibilityHidden(true)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(memory.record.highlight.title)
      .accessibilityValue(memory.record.accessibilityDescription)
      .accessibilityIdentifier(
        isLatest
          ? "phone.weekly-memory.cover"
          : "phone.weekly-memory.cover.\(memory.record.weekOrdinal)"
      )
  }
}

private struct WeeklyMemoryEmptyState: View {
  let isLoading: Bool
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: CompanionSpacing.medium) {
      Image(systemName: isLoading ? "sparkles" : "book.closed")
        .font(.largeTitle)
        .foregroundStyle(CompanionPalette.gold)
      Text(isLoading ? "Mori 正在整理五周回忆" : "还没有形成连续五周的回忆")
        .font(.headline)
      Text("准备好一段完整的旅程后，Mori 会把每一周最值得记住的画面留在这里。")
        .font(.subheadline)
        .foregroundStyle(CompanionPalette.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if !isLoading {
        Button("重新整理", action: onRetry)
          .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 36)
    .padding(.horizontal, CompanionSpacing.large)
    .background(
      CompanionPalette.memoryPaper,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("phone.weekly-memory.empty")
  }
}

private struct WeeklyMemoryManager: View {
  @ObservedObject var store: PhoneAppStore
  @Binding var pendingDeletion: PhoneWeeklyMemory?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if store.weeklyMemories.isEmpty {
          ContentUnavailableView(
            "还没有回忆",
            systemImage: "book.closed",
            description: Text("连续五周的旅程会在这里形成一条时间线。")
          )
        } else {
          Section("时间线") {
            ForEach(store.visibleWeeklyMemories) { memory in
              managerRow(memory)
            }
          }

          if !store.hiddenWeeklyMemories.isEmpty {
            Section("已隐藏") {
              ForEach(store.hiddenWeeklyMemories) { memory in
                managerRow(memory)
              }
            }
          }
        }
      }
      .navigationTitle("管理回忆")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }
        }
      }
      .accessibilityIdentifier("phone.weekly-memory.manager")
    }
    .alert(item: $pendingDeletion) { memory in
      Alert(
        title: Text("移除“\(memory.record.title)”？"),
        message: Text("这会把这一周从回忆时间线中移除。"),
        primaryButton: .destructive(Text("移除这周回忆")) {
          Task { await store.deleteWeeklyMemory(memory) }
        },
        secondaryButton: .cancel(Text("保留"))
      )
    }
  }

  private func managerRow(_ memory: PhoneWeeklyMemory) -> some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.small) {
      HStack(alignment: .firstTextBaseline) {
        Text(memory.record.title)
          .font(.headline)
        Spacer()
        if memory.record.isFavorite {
          Image(systemName: "heart.fill")
            .foregroundStyle(CompanionPalette.rose)
            .accessibilityLabel("已收藏")
        }
      }
      Text("\(memory.record.weekLabel) · \(memory.record.dateLabel)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(CompanionPalette.secondaryText)

      HStack {
        Button(memory.record.isFavorite ? "取消收藏" : "收藏") {
          Task {
            await store.setWeeklyMemoryFavorite(memory, value: !memory.record.isFavorite)
          }
        }
        .buttonStyle(.bordered)

        Button(memory.record.isHidden ? "恢复显示" : "隐藏") {
          Task {
            await store.setWeeklyMemoryHidden(memory, value: !memory.record.isHidden)
          }
        }
        .buttonStyle(.bordered)

        Spacer()

        Button("移除", role: .destructive) {
          pendingDeletion = memory
        }
      }
      .controlSize(.small)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
  }
}

private struct MemoryTimelineEntry: View {
  let memory: PhoneMemoryPresentation

  var body: some View {
    HStack(alignment: .top, spacing: CompanionSpacing.medium) {
      VStack(spacing: 0) {
        Circle()
          .fill(CompanionPalette.mint)
          .frame(width: 10, height: 10)
          .padding(.top, 7)
        Rectangle()
          .fill(Color.secondary.opacity(0.22))
          .frame(width: 1)
          .frame(maxHeight: .infinity)
      }

      VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
        Text(memory.dayLabel)
          .font(.headline)

        ZStack(alignment: .bottom) {
          Image("scene_\(memory.sceneID)_large")
            .resizable()
            .interpolation(.none)
            .scaledToFill()

          LinearGradient(
            colors: [.clear, .black.opacity(0.24)],
            startPoint: .center,
            endPoint: .bottom
          )

          Image("character_penguin_idle_resting_00")
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: 150, height: 164)
            .padding(.bottom, 10)
        }
        .aspectRatio(1.45, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)

        Text(memory.narrative)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("phone.memory.\(memory.id).narrative")

        HStack(spacing: CompanionSpacing.large) {
          if let steps = memory.steps {
            Label(
              "\(steps.formatted(.number.grouping(.automatic)))步",
              systemImage: "figure.walk"
            )
          }
          if let sleepMinutes = memory.sleepMinutes {
            Label(
              Self.sleepText(sleepMinutes),
              systemImage: "moon.fill"
            )
          }
        }
        .font(.footnote)
        .foregroundStyle(CompanionPalette.secondaryText)
        .accessibilityIdentifier("phone.memory.\(memory.id).facts")

        Text("这些数字只记录已知事实，不是对健康或情绪的判断。")
          .font(.caption)
          .foregroundStyle(CompanionPalette.secondaryText)
          .padding(.bottom, CompanionSpacing.large)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("phone.memory.\(memory.id)")
  }

  private static func sleepText(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)小时" : "\(hours)小时\(remainder)分"
  }
}
