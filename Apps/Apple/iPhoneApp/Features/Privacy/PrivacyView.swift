import AppRuntime
import SwiftUI

struct PrivacyView: View {
  @ObservedObject var store: PhoneAppStore
  @State private var isConfirmingPersonalizationClear = false

  private var model: PhonePresentationModel { store.model }

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
        PhoneDataBadge(model: model)
          .padding(.top, CompanionSpacing.small)

        CompanionCard {
          Label("你的健康数据属于你", systemImage: "lock.shield.fill")
            .font(.headline)
            .foregroundStyle(CompanionPalette.mint)
          Text("原始 HealthKit 数据只在本机生成状态与趋势；不会自动向好友发送睡眠阶段、心率数值或原始记录。")
            .font(.subheadline)
            .foregroundStyle(CompanionPalette.secondaryText)
            .padding(.top, 5)
        }

        Text("主动陪伴")
          .font(.headline)
        settingToggle(
          title: "允许 Mori 主动来信",
          detail: "遵守安静时段和四小时频率上限。通知权限：\(store.notificationStatus)。",
          isOn: Binding(
            get: { store.preferences.proactiveMessagesEnabled },
            set: store.setProactiveMessages
          ),
          identifier: "phone.privacy.proactive"
        )

        Text("个性化陪伴")
          .font(.headline)
          .padding(.top, CompanionSpacing.small)
        settingToggle(
          title: "允许 Mori 逐渐了解我",
          detail: "Mori 会保留温暖、好奇、不评判的原有性格，只从明确选择、完成的活动与多日作息节奏中，慢慢贴近你的陪伴方式。",
          isOn: Binding(
            get: { store.isPersonalizationEnabled },
            set: store.setPersonalizationEnabled
          ),
          identifier: "phone.privacy.personalization"
        )

        CompanionCard {
          VStack(alignment: .leading, spacing: CompanionSpacing.small) {
            Text("作息只会形成多日时间带与规律性，不保留单晚睡眠明细；Mori 不会据此或心率判断你的性格。")
              .font(.footnote)
              .foregroundStyle(CompanionPalette.secondaryText)
              .fixedSize(horizontal: false, vertical: true)

            Button("清除 Mori 对我的了解", role: .destructive) {
              isConfirmingPersonalizationClear = true
            }
            .disabled(store.isClearingPersonalization)
            .accessibilityIdentifier("phone.privacy.personalization-clear")

            if let status = store.personalizationStatus {
              Text(status)
                .font(.footnote)
                .foregroundStyle(CompanionPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("phone.privacy.personalization-status")
            }
          }
        }

        Text("好友可见范围")
          .font(.headline)
          .padding(.top, CompanionSpacing.small)
        settingToggle(
          title: "启用好友分享",
          detail: "默认开启，无需先打开 iPhone 设置。开始触碰后会临时上传公开宠物卡，验证两块 Watch 靠近后才向对方展示；双方确认后才建立相遇。你可以随时关闭。",
          isOn: Binding(
            get: { store.preferences.socialSharingEnabled },
            set: store.setSocialSharing
          ),
          identifier: "phone.privacy.social-sharing"
        )

        CompanionCard {
          VStack(alignment: .leading, spacing: CompanionSpacing.small) {
            Text("公开宠物社交状态")
              .font(.subheadline.weight(.semibold))
            if store.preferences.socialSharingEnabled {
              Picker(
                "公开状态",
                selection: Binding(
                  get: { store.preferences.publicPetSocialState },
                  set: store.setPublicPetSocialState
                )
              ) {
                ForEach(PublicPetSocialStateV1.allCases, id: \.rawValue) { state in
                  Text(socialStateTitle(state)).tag(state)
                }
              }
              .pickerStyle(.navigationLink)
              .accessibilityIdentifier("phone.privacy.social-state-picker")
            } else {
              Label("好友分享已关闭，触碰交换不会发送宠物卡", systemImage: "lock.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(CompanionPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("phone.privacy.social-state-locked")
            }

            Text("当前：\(socialStateTitle(store.preferences.publicPetSocialState))")
              .font(.footnote.weight(.semibold))
              .accessibilityIdentifier("phone.privacy.social-state-summary")
            Text("只描述宠物想怎样社交；不会包含睡眠、心率、生命力或其他健康推导。")
              .font(.footnote)
              .foregroundStyle(CompanionPalette.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        CompanionCard {
          VStack(alignment: .leading, spacing: CompanionSpacing.small) {
            Text("健康摘要分享")
              .font(.subheadline.weight(.semibold))
              .accessibilityIdentifier("phone.privacy.sharing-scope")
            Label(
              "暂未启用；当前版本不会向好友发送任何健康摘要。",
              systemImage: "lock.shield"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(CompanionPalette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("phone.privacy.health-sharing-unavailable")
            Text("触碰交换只发送上方明确列出的公开宠物卡。")
              .font(.footnote)
              .foregroundStyle(CompanionPalette.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        CompanionCard {
          Label(
            model.isLive ? "本机数据模式" : "演示数据", systemImage: model.isLive ? "iphone" : "testtube.2"
          )
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(CompanionPalette.blue)
          Text(
            model.isLive
              ? "HealthKit 原始数据仍只在本机处理。只有你主动发送聊天时，最近对话与粗粒度性格提示会交给 AI 服务生成回复；不会写入长期记忆。"
              : "此运行使用显式 Mock 场景验证交互，不会把演示值标记为真实健康数据。"
          )
          .font(.footnote)
          .foregroundStyle(CompanionPalette.secondaryText)
          .padding(.top, 5)
        }
      }
    }
    .navigationTitle("隐私")
    .accessibilityIdentifier("phone.privacy")
    .alert("清除 Mori 对你的了解？", isPresented: $isConfirmingPersonalizationClear) {
      Button("清除", role: .destructive) {
        Task { await store.clearPersonalization() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这会清除 Mori 学到的偏好和适应性性格；不会删除周报或健康记录。")
    }
  }

  private func socialStateTitle(_ state: PublicPetSocialStateV1) -> String {
    switch state {
    case .greeting:
      "想打个招呼"
    case .walk:
      "想一起散步"
    case .quietCompany:
      "想安静陪伴"
    }
  }

  private func settingToggle(
    title: String,
    detail: String,
    isOn: Binding<Bool>,
    identifier: String
  ) -> some View {
    CompanionCard {
      Toggle(isOn: isOn) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.subheadline.weight(.semibold))
          Text(detail)
            .font(.footnote)
            .foregroundStyle(CompanionPalette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .tint(CompanionPalette.mint)
      .accessibilityIdentifier(identifier)
    }
  }
}
