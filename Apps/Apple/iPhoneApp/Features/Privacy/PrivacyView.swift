import AppRuntime
import SwiftUI

struct PrivacyView: View {
  @ObservedObject var store: PhoneAppStore

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

        Text("好友可见范围")
          .font(.headline)
          .padding(.top, CompanionSpacing.small)
        settingToggle(
          title: "启用好友分享",
          detail: "默认关闭。开启后，也只有双方主动进入触碰交换并确认，才会发送公开宠物卡。",
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
            Text("分享范围")
              .font(.subheadline.weight(.semibold))
              .accessibilityIdentifier("phone.privacy.sharing-scope")
            if store.preferences.socialSharingEnabled {
              Picker(
                "分享范围",
                selection: Binding(
                  get: { store.preferences.healthSharingScope },
                  set: store.setHealthSharingScope
                )
              ) {
                Text("游戏状态").tag(HealthSharingScope.gameStateOnly)
                Text("关心摘要").tag(HealthSharingScope.careSummary)
                Text("有限健康摘要").tag(HealthSharingScope.limitedHealthSummary)
              }
              .pickerStyle(.navigationLink)
              .accessibilityIdentifier("phone.privacy.sharing-scope-picker")
            } else {
              HStack(spacing: CompanionSpacing.small) {
                Label("好友分享已关闭", systemImage: "lock.fill")
                  .font(.footnote.weight(.semibold))
                Spacer(minLength: CompanionSpacing.small)
                Text(scopeTitle)
                  .font(.footnote.weight(.semibold))
              }
              .foregroundStyle(CompanionPalette.secondaryText)
              .accessibilityElement(children: .combine)
              .accessibilityLabel("分享范围")
              .accessibilityValue("\(scopeTitle)，好友分享已关闭")
              .accessibilityIdentifier("phone.privacy.sharing-scope-status")
            }

            Text(scopeDescription)
              .font(.footnote)
              .foregroundStyle(CompanionPalette.secondaryText)
              .fixedSize(horizontal: false, vertical: true)
            Label(
              "此健康分享范围不用于触碰交换；触碰交换只发送上方明确列出的公开宠物卡。",
              systemImage: "lock.shield"
            )
            .font(.footnote.weight(.semibold))
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
              ? "当前只读取本机授权的 HealthKit 数据并保存派生事件；没有服务器上传。"
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
  }

  private var scopeDescription: String {
    switch store.preferences.healthSharingScope {
    case .gameStateOnly:
      "只分享宠物等级、共同剧情与游戏关系。"
    case .careSummary:
      "默认范围：只分享“今天适合放慢”等非医疗、非数值表达。"
    case .limitedHealthSummary:
      "可分享用户明确允许的有限摘要；仍不包含睡眠阶段、心率数值或原始记录。"
    }
  }

  private var scopeTitle: String {
    switch store.preferences.healthSharingScope {
    case .gameStateOnly:
      "游戏状态"
    case .careSummary:
      "关心摘要"
    case .limitedHealthSummary:
      "有限健康摘要"
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
