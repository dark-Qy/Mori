import SwiftUI

struct HistoryView: View {
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

        if store.visibleWeeklyMemories.isEmpty {
          WeeklyMemoryEmptyState(
            isLoading: store.isPreparingWeeklyMemory,
            onRetry: { Task { await store.prepareWeeklyMemory(force: true) } }
          )
        } else {
          memoryTimeline
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
    .accessibilityIdentifier("phone.history")
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
      Text("和 Mori 走过的五周")
        .font(.title2.weight(.bold))
      Text("每一周，只留下一个最值得记住的画面。")
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
