import SwiftUI

struct PrivacyView: View {
  let model: PhonePresentationModel
  @State private var shareCareSummary = true
  @State private var shareLimitedHealthSummary = false
  @State private var proactiveMessages = true

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
        PhoneMockBadge(scenarioName: model.scenario.displayName)
          .padding(.top, CompanionSpacing.small)

        CompanionCard {
          Label("你的健康数据属于你", systemImage: "lock.shield.fill")
            .font(.headline)
            .foregroundStyle(CompanionPalette.mint)
          Text("默认只在本机用于生成宠物状态。不会向好友暴露睡眠、心率或原始记录。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 5)
        }

        Text("主动陪伴")
          .font(.headline)
        settingToggle(
          title: "允许 Mori 主动来信",
          detail: "遵守安静时段和频率上限，可随时关闭。",
          isOn: $proactiveMessages,
          identifier: "phone.privacy.proactive"
        )

        Text("好友可见范围")
          .font(.headline)
          .padding(.top, CompanionSpacing.small)
        settingToggle(
          title: "关心摘要",
          detail: "默认开启，只分享“今天适合放慢”等非医疗、非原始数据表达。",
          isOn: $shareCareSummary,
          identifier: "phone.privacy.care-summary"
        )
        settingToggle(
          title: "有限健康摘要",
          detail: "默认关闭。开启后也不会分享睡眠阶段、心率数值或 HealthKit 原始记录。",
          isOn: $shareLimitedHealthSummary,
          identifier: "phone.privacy.health-summary"
        )

        CompanionCard {
          Label("演示数据", systemImage: "testtube.2")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(CompanionPalette.blue)
          Text("此版本使用 Mock 场景验证产品交互；接入真实权限前，不会读取或上传 HealthKit 数据。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 5)
        }
      }
    }
    .navigationTitle("隐私")
    .accessibilityIdentifier("phone.privacy")
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
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .tint(CompanionPalette.mint)
      .accessibilityIdentifier(identifier)
    }
  }
}
