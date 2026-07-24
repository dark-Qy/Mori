import AppRuntime
import MoriRuntime
import SwiftUI

struct WatchSettingsView: View {
  @ObservedObject var store: WatchAppStore

  var body: some View {
    List {
      Section {
        NavigationLink(value: WatchProductRoute.companionSettings) {
          Label("Mori 随行", systemImage: "location.fill")
        }
        .accessibilityIdentifier("watch.settings.open-companion")
      }

      Section {
        settingsRow(
          title: "数据来源",
          value: store.selectedDataSource == .healthKit ? "Apple 健康" : "Mock"
        )
        settingsRow(
          title: "随行感知",
          value: companionStatus
        )
        settingsRow(
          title: "Mori 通知",
          value: store.preferences.proactiveMessagesEnabled ? "App 内开启" : "App 内关闭"
        )
      } header: {
        Text("数据状态")
      } footer: {
        Text("系统授权状态请在 Apple Watch 设置中查看。")
      }

      #if DEBUG
        Section {
          NavigationLink {
            WatchDataModeView(store: store)
          } label: {
            HStack {
              Text("数据模式")
              Spacer()
              Text(store.selectedDataSource.isMock ? "Mock" : "真实")
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("watch.settings.open-data-mode")

          if store.selectedDataSource.isMock {
            Button("重置当前 Mock 状态") {
              Task { await store.resetCurrentMockState() }
            }
            .disabled(!store.dataSourceSelectionAvailable)
            .accessibilityIdentifier("watch.settings.reset-mock")
          }
        } header: {
          Text("开发者选项")
        } footer: {
          Text("Mock 与真实记录完全隔离；这里没有手动同步或同步测试。")
        }
      #endif
    }
    .navigationTitle("设置")
    .accessibilityIdentifier("watch.settings")
  }

  private func settingsRow(title: String, value: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }

  private var companionStatus: String {
    guard store.companionExperienceAvailable else { return "待连接" }
    return store.companionSensingEnabled ? "App 内开启" : "App 内关闭"
  }
}

struct WatchCompanionSettingsView: View {
  @ObservedObject var store: WatchAppStore

  var body: some View {
    List {
      #if DEBUG
        if store.companionExperienceAvailable {
          Section {
            Toggle(
              "随行感知",
              isOn: Binding(
                get: { store.companionSensingEnabled },
                set: store.setCompanionSensingEnabled
              )
            )
            .accessibilityHint("关闭后不会生成新的随行事件或抬腕提醒")
            .accessibilityIdentifier("watch.companion.sensing")
          } footer: {
            Text("移动线索尽量在本机处理；关闭后 Mori 仍会留在首页。")
          }

          Section("提醒方式") {
            ForEach(CompanionReminderMode.allCases, id: \.rawValue) { mode in
              Button {
                store.setReminderMode(mode)
              } label: {
                HStack(alignment: .top, spacing: 8) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                      .foregroundStyle(.primary)
                    Text(mode.detail)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  Spacer(minLength: 4)
                  if store.reminderMode == mode {
                    Image(systemName: "checkmark")
                      .foregroundStyle(AdventurePalette.mint)
                      .accessibilityHidden(true)
                  }
                }
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(store.reminderMode == mode ? .isSelected : [])
              .accessibilityIdentifier("watch.companion.reminder.\(mode.rawValue)")
            }
          }

          Section {
            DatePicker(
              "开始",
              selection: quietHoursBinding(
                minute: store.quietHours.startMinute,
                update: { store.setQuietHours(startMinute: $0) }
              ),
              displayedComponents: .hourAndMinute
            )
            .accessibilityIdentifier("watch.companion.quiet-start")

            DatePicker(
              "结束",
              selection: quietHoursBinding(
                minute: store.quietHours.endMinute,
                update: { store.setQuietHours(endMinute: $0) }
              ),
              displayedComponents: .hourAndMinute
            )
            .accessibilityIdentifier("watch.companion.quiet-end")
          } header: {
            Text("安静时段")
          } footer: {
            Text("安静时段不轻震；开始和结束相同表示无效，不会静音全天。")
          }
        } else {
          unavailableCompanionSection
        }
      #else
        unavailableCompanionSection
      #endif
    }
    .navigationTitle("Mori 随行")
    .accessibilityValue(
      store.isSavingCompanionPreferences ? "正在保存" : "已保存"
    )
    .accessibilityIdentifier("watch.companion-settings")
  }

  private var unavailableCompanionSection: some View {
    Section {
      Label("真实随行感知尚未连接", systemImage: "location.slash")
    } footer: {
      Text("当前模式不会模拟事件或触觉；真实运行时接入后才会开放这些选项。")
    }
  }

  private func quietHoursBinding(
    minute: Int,
    update: @escaping (Int) -> Void
  ) -> Binding<Date> {
    Binding(
      get: { date(for: minute) },
      set: { update(minuteOfDay(for: $0)) }
    )
  }

  private func date(for minute: Int) -> Date {
    Calendar.current.date(
      bySettingHour: minute / 60,
      minute: minute % 60,
      second: 0,
      of: Date()
    ) ?? Date()
  }

  private func minuteOfDay(for date: Date) -> Int {
    Calendar.current.component(.hour, from: date) * 60
      + Calendar.current.component(.minute, from: date)
  }
}

#if DEBUG
  private struct WatchDataModeView: View {
    @ObservedObject var store: WatchAppStore

    var body: some View {
      List {
        if !store.dataSourceSelectionAvailable {
          Section {
            Text("当前由启动参数锁定为 \(store.selectedDataSource.displayName)。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section {
          ForEach(CompanionDataSource.allCases, id: \.self) { source in
            Button {
              Task { await store.selectDataSource(source) }
            } label: {
              HStack {
                Text(source.displayName)
                  .foregroundStyle(.primary)
                Spacer()
                if source == store.selectedDataSource {
                  Image(systemName: "checkmark")
                    .foregroundStyle(AdventurePalette.mint)
                    .accessibilityHidden(true)
                }
              }
            }
            .buttonStyle(.plain)
            .disabled(!store.dataSourceSelectionAvailable)
            .accessibilityAddTraits(
              source == store.selectedDataSource ? .isSelected : []
            )
            .accessibilityIdentifier("watch.data-mode.\(source.rawValue)")
          }
        } header: {
          Text("数据模式")
        } footer: {
          Text("连接可用时自动同步；不会提供手动同步按钮。")
        }
      }
      .navigationTitle("数据模式")
      .accessibilityIdentifier("watch.data-mode")
    }
  }
#endif
