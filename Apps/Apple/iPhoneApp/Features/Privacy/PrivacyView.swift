import AppRuntime
import MoriRuntime
import SwiftUI
import UIKit

struct PhoneSettingsView: View {
  @ObservedObject var store: PhoneAppStore
  @State private var isConfirmingPersonalizationClear = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      dataSection
      companionSection
      notificationSection
      conversationSection
      personalizationSection
      sharingSection
      dataManagementSection
      developerSection
      localStorageSection
    }
    .navigationTitle("设置")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("完成") {
          store.dismissSettings()
          dismiss()
        }
        .accessibilityIdentifier("phone.settings.done")
      }
    }
    .accessibilityIdentifier("phone.settings")
    .alert(
      "清除对话记录？",
      isPresented: Binding(
        get: { store.isShowingClearConversationConfirmation },
        set: { isPresented in
          if isPresented == false {
            store.cancelClearConversation()
          }
        }
      )
    ) {
      Button("取消", role: .cancel) {
        store.cancelClearConversation()
      }
      Button("清除", role: .destructive) {
        Task { await store.clearConversation() }
      }
      .accessibilityIdentifier("phone.settings.clear-conversation-confirm")
    } message: {
      Text("只清除本机对话和草稿；共同回忆仍会保留。")
    }
    .sheet(
      isPresented: Binding(
        get: { store.isShowingDeleteAllConfirmation },
        set: { isPresented in
          if isPresented == false {
            store.cancelDeleteAllMoriData()
          }
        }
      )
    ) {
      PhoneDeleteAllMoriDataView(store: store)
    }
    .alert(
      "清除 Mori 对你的了解？",
      isPresented: $isConfirmingPersonalizationClear
    ) {
      Button("清除", role: .destructive) {
        Task { await store.clearPersonalization() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这会清除 Mori 学到的偏好和适应性性格；不会删除共同回忆或健康记录。")
    }
  }

  private var dataSection: some View {
    Section {
      LabeledContent("当前模式") {
        Text(dataModeTitle)
          .foregroundStyle(CompanionPalette.secondaryText)
          .accessibilityIdentifier("phone.settings.data-mode-value")
      }

      if store.dataSourceSelectionAvailable {
        Picker(
          "数据模式",
          selection: Binding(
            get: { store.selectedDataSource },
            set: { source in
              Task { await store.selectDataSource(source) }
            }
          )
        ) {
          ForEach(CompanionDataSource.allCases, id: \.rawValue) { source in
            Text(source.displayName).tag(source)
          }
        }
        .accessibilityIdentifier("phone.settings.data-mode")
        .disabled(store.isSwitchingDataSource)
      }

      if store.selectedDataSource == .healthKit {
        LabeledContent("Apple 健康") {
          Text(store.model.stepCount == nil ? "待连接" : "已读取本机记录")
            .foregroundStyle(CompanionPalette.secondaryText)
        }
        Text("健康记录会在前台自动更新；权限关闭时请前往系统设置恢复。")
          .font(.footnote)
          .foregroundStyle(CompanionPalette.secondaryText)
      } else {
        Text("Mock 与真实记录使用独立命名空间，不会互相覆盖。")
          .font(.footnote)
          .foregroundStyle(CompanionPalette.secondaryText)
      }
    } header: {
      Text("数据与权限")
    }
  }

  private var companionSection: some View {
    Section {
      if store.companionExperienceAvailable {
        Toggle(
          "随行感知",
          isOn: Binding(
            get: { store.companionSensingEnabled },
            set: store.setCompanionSensingEnabled
          )
        )
        .accessibilityIdentifier("phone.settings.companion-sensing")

        Picker(
          "提醒方式",
          selection: Binding(
            get: { store.reminderMode },
            set: store.setReminderMode
          )
        ) {
          Text("抬腕提醒").tag(CompanionReminderMode.wristRaise)
          Text("轻震提醒").tag(CompanionReminderMode.gentleHaptic)
        }
        .accessibilityIdentifier("phone.settings.reminder-mode")

        NavigationLink {
          QuietHoursSettingsView(store: store)
        } label: {
          HStack {
            Text("安静时段")
              .font(.body)
            Spacer()
            Text(quietHoursText)
              .font(.body)
              .foregroundStyle(CompanionPalette.secondaryText)
          }
        }
        .accessibilityIdentifier("phone.settings.quiet-hours")
      } else {
        LabeledContent("Mori 随行") {
          Text("待连接")
            .foregroundStyle(CompanionPalette.secondaryText)
        }
      }
    } header: {
      Text("Mori 随行")
    } footer: {
      Text("手表首页仍保留随行入口；这里用于更完整地管理提醒和安静时段。")
    }
  }

  private var notificationSection: some View {
    Section {
      Toggle(
        "允许 Mori 主动来信",
        isOn: Binding(
          get: { store.preferences.proactiveMessagesEnabled },
          set: store.setProactiveMessages
        )
      )
      .accessibilityIdentifier("phone.settings.proactive")
      LabeledContent("通知权限") {
        Text(store.notificationStatus)
          .foregroundStyle(CompanionPalette.secondaryText)
      }
    } header: {
      Text("通知")
    } footer: {
      Text("Mock 不会请求系统权限。真实模式仅在你开启时请求。")
    }
  }

  private var conversationSection: some View {
    Section {
      Toggle(
        "允许使用共同回忆",
        isOn: Binding(
          get: { store.conversation.memoryContextIsEnabled },
          set: store.setMemoryContext
        )
      )
      .disabled(store.companionExperienceAvailable == false)
      .accessibilityIdentifier("phone.settings.memory-context")

      Button("清除对话记录", role: .destructive) {
        store.requestClearConversation()
      }
      .disabled(store.companionExperienceAvailable == false)
      .accessibilityIdentifier("phone.settings.clear-conversation")
    } header: {
      Text("Mori 对话")
    } footer: {
      Text(
        store.model.isLive
          ? "正式对话运行时尚未接入。"
          : "当前是本机 Mock 预览，不发送到服务器。开启后，每次最多使用一段 500 字以内的共同回忆；清除对话不会删除回忆本身。"
      )
    }
  }

  private var personalizationSection: some View {
    Section {
      Toggle(
        "允许 Mori 逐渐了解我",
        isOn: Binding(
          get: { store.isPersonalizationEnabled },
          set: store.setPersonalizationEnabled
        )
      )
      .accessibilityIdentifier("phone.privacy.personalization")

      Text("只从明确选择、完成的活动与多日作息节奏中调整陪伴方式；不会根据单晚睡眠或心率判断性格。")
        .font(.footnote)
        .foregroundStyle(CompanionPalette.secondaryText)

      Button("清除 Mori 对我的了解", role: .destructive) {
        isConfirmingPersonalizationClear = true
      }
      .disabled(store.isClearingPersonalization)
      .accessibilityIdentifier("phone.privacy.personalization-clear")

      if let status = store.personalizationStatus {
        Text(status)
          .font(.footnote)
          .foregroundStyle(CompanionPalette.secondaryText)
          .accessibilityIdentifier("phone.privacy.personalization-status")
      }
    } header: {
      Text("个性化陪伴")
    }
  }

  private var sharingSection: some View {
    Section {
      Toggle(
        "启用好友分享",
        isOn: Binding(
          get: { store.preferences.socialSharingEnabled },
          set: store.setSocialSharing
        )
      )
      .accessibilityIdentifier("phone.settings.social-sharing")

      Picker(
        "公开宠物状态",
        selection: Binding(
          get: { store.preferences.publicPetSocialState },
          set: store.setPublicPetSocialState
        )
      ) {
        ForEach(PublicPetSocialStateV1.allCases, id: \.rawValue) { value in
          Text(socialTitle(value)).tag(value)
        }
      }
      .disabled(store.preferences.socialSharingEnabled == false)
      .accessibilityIdentifier("phone.settings.social-state")
    } header: {
      Text("好友与触碰交换")
    } footer: {
      Text("默认开启。触碰交换只发送你选择的公开宠物状态，不包含步数、睡眠或健康数据；你可以随时关闭。")
    }
  }

  private var dataManagementSection: some View {
    Section {
      if let settingsURL = URL(
        string: UIApplication.openSettingsURLString
      ) {
        Link(destination: settingsURL) {
          Label("打开 Apple 设置", systemImage: "gear")
        }
        .accessibilityIdentifier("phone.settings.open-apple-settings")
      }

      Button("删除所有 Mori 数据", role: .destructive) {
        store.requestDeleteAllMoriData()
      }
      .disabled(store.isDeletingAllMoriData)
      .accessibilityIdentifier("phone.settings.delete-all")
    } header: {
      Text("数据管理")
    } footer: {
      Text("Apple 设置用于管理健康、定位和通知权限。删除 Mori 数据不会删除 Apple 健康记录，也不会声称系统权限已经撤销。")
    }
  }

  @ViewBuilder
  private var developerSection: some View {
    #if DEBUG
      Section {
        if store.selectedDataSource.isMock {
          LabeledContent("Mock 场景") {
            Text(store.selectedDataSource.displayName)
              .foregroundStyle(CompanionPalette.secondaryText)
          }
          Button("重置当前 Mock 状态", role: .destructive) {
            Task { await store.resetCurrentMockState() }
          }
          .disabled(store.dataSourceSelectionAvailable == false)
          .accessibilityIdentifier("phone.settings.reset-mock")
        } else {
          Text("当前是 Apple 健康模式；Mock 控件不会修改真实记录。")
            .foregroundStyle(CompanionPalette.secondaryText)
        }
      } header: {
        Text("开发者选项")
      }
    #endif
  }

  private var localStorageSection: some View {
    Section {
      LabeledContent("跨设备同步") {
        Text("尚未接入")
          .foregroundStyle(CompanionPalette.secondaryText)
      }
      .accessibilityIdentifier("phone.settings.sync-status")
    } footer: {
      Text("当前设置、Mock 任务、金币与收藏只保存在本机。iPhone 与 Watch 的配对中继尚未接入；接入后会自动同步，这里不提供手动同步或测试按钮。")
    }
  }

  private var dataModeTitle: String {
    if case .invalidMock = store.dataMode {
      return "无效 Mock"
    }
    return store.model.isLive
      ? "Apple 健康 · 本机"
      : "Mock · \(store.model.mockScenario?.displayName ?? "未知")"
  }

  private var quietHoursText: String {
    "\(timeText(store.quietHours.startMinute))–\(timeText(store.quietHours.endMinute))"
  }

  private func timeText(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }

  private func socialTitle(_ state: PublicPetSocialStateV1) -> String {
    switch state {
    case .greeting: "想打个招呼"
    case .walk: "想一起散步"
    case .quietCompany: "想安静陪伴"
    }
  }
}

private struct PhoneDeleteAllMoriDataView: View {
  @ObservedObject var store: PhoneAppStore

  var body: some View {
    NavigationStack {
      List {
        Section {
          Label("所有真实与 Mock profile", systemImage: "person.2.slash")
          Label("对话、回忆、任务与金币", systemImage: "text.badge.xmark")
          Label("收藏、设置与待处理通知", systemImage: "trash")
          Label("本机缓存与同步待发内容", systemImage: "externaldrive.badge.xmark")
        } header: {
          Text("将从 Mori 删除")
        }

        Section {
          Text("Apple 健康中的原始记录和 Apple 系统权限不属于 Mori，删除后仍需在 Apple 设置中单独管理。")
          Text("当前 Watch 删除同步尚未接入；本机先保存删除围栏，避免旧 profile 在本机恢复。")
        } header: {
          Text("不会删除")
        }

        if let status = store.statusMessage {
          Section {
            Text(status)
              .foregroundStyle(CompanionPalette.secondaryText)
          }
        }

        Section {
          Button("确认删除所有 Mori 数据", role: .destructive) {
            Task { await store.confirmDeleteAllMoriData() }
          }
          .disabled(store.isDeletingAllMoriData)
          .accessibilityIdentifier("phone.settings.confirm-delete-all")
        }
      }
      .navigationTitle("删除 Mori 数据")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") {
            store.cancelDeleteAllMoriData()
          }
          .disabled(store.isDeletingAllMoriData)
        }
      }
      .accessibilityIdentifier("phone.settings.delete-all-confirmation")
    }
  }
}

private struct QuietHoursSettingsView: View {
  @ObservedObject var store: PhoneAppStore

  var body: some View {
    Form {
      Section {
        DatePicker(
          "开始",
          selection: minuteBinding(
            get: { store.quietHours.startMinute },
            set: { store.setQuietHours(startMinute: $0) }
          ),
          displayedComponents: .hourAndMinute
        )
        .accessibilityIdentifier("phone.settings.quiet-start")

        DatePicker(
          "结束",
          selection: minuteBinding(
            get: { store.quietHours.endMinute },
            set: { store.setQuietHours(endMinute: $0) }
          ),
          displayedComponents: .hourAndMinute
        )
        .accessibilityIdentifier("phone.settings.quiet-end")
      } footer: {
        Text("安静时段内不会触发主动提醒。开始和结束时间不能相同。")
      }
    }
    .navigationTitle("安静时段")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func minuteBinding(
    get: @escaping () -> Int,
    set: @escaping (Int) -> Void
  ) -> Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          bySettingHour: get() / 60,
          minute: get() % 60,
          second: 0,
          of: Date()
        ) ?? Date()
      },
      set: { date in
        let components = Calendar.current.dateComponents(
          [.hour, .minute],
          from: date
        )
        set((components.hour ?? 0) * 60 + (components.minute ?? 0))
      }
    )
  }
}
