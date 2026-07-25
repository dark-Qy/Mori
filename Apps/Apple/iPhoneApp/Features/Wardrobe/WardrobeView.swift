import AppRuntime
import SwiftUI

struct PhoneScenesView: View {
  @ObservedObject var store: PhoneAppStore

  private let characters = CompanionCharacterOption.all
  private let scenes = PhoneSceneOption.all
  private let columns = [
    GridItem(.adaptive(minimum: 145), spacing: CompanionSpacing.medium)
  ]

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.large) {
        header
          .padding(.top, CompanionSpacing.small)

        scenePreview
        characterPicker

        VStack(alignment: .leading, spacing: CompanionSpacing.small) {
          Text("场景")
            .font(.headline)

          LazyVGrid(columns: columns, spacing: CompanionSpacing.medium) {
            ForEach(scenes) { scene in
              sceneButton(scene)
            }
          }
        }

        if let status = store.statusMessage {
          Text(status)
            .font(.footnote)
            .foregroundStyle(CompanionPalette.secondaryText)
            .accessibilityIdentifier("phone.scenes.status")
        }
      }
    }
    .navigationTitle("场景")
    .accessibilityIdentifier("phone.scenes")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("伙伴与场景")
        .font(.title2.bold())
      Text("所有场景都已开放，点一下即可切换。")
        .font(.subheadline)
        .foregroundStyle(CompanionPalette.secondaryText)
    }
  }

  private var scenePreview: some View {
    ZStack(alignment: .bottom) {
      Image("scene_\(store.selectedSceneID)_large")
        .resizable()
        .interpolation(.none)
        .scaledToFill()

      LinearGradient(
        colors: [.clear, .black.opacity(0.16)],
        startPoint: .center,
        endPoint: .bottom
      )

      Image("character_\(store.selectedCharacterID)_idle_lively_00")
        .resizable()
        .interpolation(.none)
        .scaledToFit()
        .frame(width: 180, height: 196)
        .padding(.bottom, 12)

      Text("\(characterName) · \(sceneName)")
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.72), in: Capsule())
        .padding(.bottom, 12)
    }
    .aspectRatio(1.55, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("场景预览")
    .accessibilityValue("\(characterName)，\(sceneName)")
    .accessibilityIdentifier("phone.scenes.preview")
  }

  private var characterPicker: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.small) {
      Text("伙伴")
        .font(.headline)

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 104), spacing: CompanionSpacing.small)],
        spacing: CompanionSpacing.small
      ) {
        ForEach(characters) { character in
          Button {
            store.selectCharacter(character.id)
          } label: {
            VStack(spacing: 6) {
              Image("character_\(character.id)_idle_neutral_00")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 68, height: 72)

              Text(character.name)
                .font(.caption.bold())
                .foregroundStyle(CompanionPalette.ink)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
              store.selectedCharacterID == character.id
                ? CompanionPalette.mintSoft : CompanionPalette.surface,
              in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                  store.selectedCharacterID == character.id
                    ? CompanionPalette.mint : Color.clear,
                  lineWidth: 2
                )
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            "\(character.name)\(store.selectedCharacterID == character.id ? "，正在陪伴" : "")"
          )
          .accessibilityIdentifier("phone.character.\(character.id)")
        }
      }
    }
  }

  private func sceneButton(_ scene: PhoneSceneOption) -> some View {
    let isSelected = store.selectedSceneID == scene.id

    return Button {
      store.selectScene(scene.id)
    } label: {
      VStack(alignment: .leading, spacing: CompanionSpacing.small) {
        Image("scene_\(scene.id)_small")
          .resizable()
          .interpolation(.none)
          .scaledToFill()
          .aspectRatio(1.3, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 12))

        HStack(spacing: 6) {
          Text(scene.title)
            .font(.subheadline.bold())
            .lineLimit(1)
          Spacer(minLength: 0)
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(CompanionPalette.mint)
          }
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected ? CompanionPalette.mintSoft : CompanionPalette.surface,
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(isSelected ? CompanionPalette.mint : Color.clear, lineWidth: 2)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(scene.title)\(isSelected ? "，正在使用" : "")")
    .accessibilityIdentifier("phone.scene.\(scene.id)")
  }

  private var characterName: String {
    CompanionVisualCatalog.characterDisplayName(store.selectedCharacterID)
  }

  private var sceneName: String {
    CompanionVisualCatalog.backgroundDisplayName(store.selectedSceneID)
  }
}

private struct CompanionCharacterOption: Identifiable {
  let id: String
  let name: String
  let detail: String

  static let all = [
    CompanionCharacterOption(id: "penguin", name: "企鹅伙伴", detail: "黑发、蓝灰眼睛与企鹅装"),
    CompanionCharacterOption(id: "polar_bear", name: "白熊伙伴", detail: "灰发、琥珀眼睛与白熊装"),
    CompanionCharacterOption(id: "bili_22", name: "22 娘", detail: "深蓝长发与闪电形呆毛"),
    CompanionCharacterOption(id: "bili_33", name: "33 娘", detail: "浅蓝侧马尾与播放发饰"),
  ]
}
