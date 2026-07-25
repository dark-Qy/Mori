import AppRuntime
import SwiftUI

struct PhoneCollectionView: View {
  @ObservedObject var store: PhoneAppStore
  @State private var category = PhoneCollectionCategory.clothing

  private let characters = CompanionCharacterOption.all

  private var visibleItems: [PhoneCollectionItem] {
    PhoneCollectionItem.catalog.filter { $0.category == category }
  }

  private let columns = [
    GridItem(.adaptive(minimum: 145), spacing: CompanionSpacing.medium)
  ]

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.large) {
        balanceHeader
          .padding(.top, CompanionSpacing.small)

        collectionPreview

        characterPicker

        Picker("收藏分类", selection: $category) {
          ForEach(PhoneCollectionCategory.allCases) { value in
            Text(value.title).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("phone.collection.category")

        if store.companionExperienceAvailable {
          LazyVGrid(columns: columns, spacing: CompanionSpacing.medium) {
            ForEach(visibleItems) { item in
              collectionItem(item)
            }
          }
        } else {
          ContentUnavailableView(
            store.model.allowsInteraction ? "收藏账本待接入" : "Mock 场景无效",
            systemImage: "heart.slash",
            description: Text(
              store.model.allowsInteraction
                ? "真实数据模式不会回退到演示金币和收藏。"
                : "请到设置中选择有效的 Mock 数据。"
            )
          )
          .frame(maxWidth: .infinity)
          .padding(.vertical, 34)
          .accessibilityIdentifier("phone.collection.unavailable")
        }

        if let status = store.statusMessage {
          Text(status)
            .font(.footnote)
            .foregroundStyle(CompanionPalette.secondaryText)
            .accessibilityIdentifier("phone.collection.status")
        }
      }
    }
    .navigationTitle("收藏")
    .accessibilityIdentifier("phone.collection")
  }

  private var balanceHeader: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("伙伴与场景")
          .font(.title2.bold())
        Text("这里只保留已经拥有和可以获得的外观。")
          .font(.subheadline)
          .foregroundStyle(CompanionPalette.secondaryText)
      }
      Spacer()
      if store.companionExperienceAvailable {
        Label(
          "\(store.activeCoinBalance)",
          systemImage: "circle.fill"
        )
        .font(.headline)
        .foregroundStyle(CompanionPalette.gold)
        .accessibilityLabel("金币 \(store.activeCoinBalance) 枚")
        .accessibilityIdentifier("phone.collection.coins")
      }
    }
  }

  private var collectionPreview: some View {
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

      equippedItemSymbols

      Text(characterName)
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.72), in: Capsule())
        .padding(.bottom, 12)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .aspectRatio(1.55, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("收藏预览")
    .accessibilityValue(characterName)
    .accessibilityIdentifier("phone.collection.preview")
  }

  private var characterPicker: some View {
    VStack(alignment: .leading, spacing: CompanionSpacing.small) {
      Text("伙伴")
        .font(.headline)

      ScrollView(.horizontal) {
        HStack(spacing: CompanionSpacing.small) {
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
              .frame(width: 104)
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
      .scrollIndicators(.hidden)
    }
  }

  @ViewBuilder
  private var equippedItemSymbols: some View {
    let clothing = PhoneCollectionItem.catalog.first(where: {
      $0.id == store.mockExperience.equippedItemID
        && $0.id != "default"
    })
    let accessory = store.mockExperience.equippedAccessoryID.flatMap {
      accessoryID in
      PhoneCollectionItem.catalog.first(where: { $0.id == accessoryID })
    }
    if clothing != nil || accessory != nil {
      HStack(spacing: 8) {
        if let clothing {
          Image(systemName: clothing.symbol)
        }
        if let accessory {
          Image(systemName: accessory.symbol)
        }
      }
      .font(.title3.bold())
      .foregroundStyle(CompanionPalette.mint)
      .padding(8)
      .background(.black.opacity(0.46), in: Capsule())
      .padding(12)
      .frame(
        maxWidth: .infinity,
        maxHeight: .infinity,
        alignment: .topTrailing
      )
      .accessibilityHidden(true)
    }
  }

  private var characterName: String {
    CompanionVisualCatalog.characterDisplayName(store.selectedCharacterID)
  }

  private func collectionItem(_ item: PhoneCollectionItem) -> some View {
    let isOwned = store.mockExperience.ownedItemIDs.contains(item.id)
    let isEquipped = store.mockExperience.isEquipped(item)

    return VStack(alignment: .leading, spacing: CompanionSpacing.small) {
      itemArtwork(item)

      Text(item.title)
        .font(.subheadline.bold())
        .lineLimit(1)

      if isEquipped {
        Label("使用中", systemImage: "checkmark.circle.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(CompanionPalette.mint)
      } else if isOwned {
        Button("使用") {
          Task { await store.equip(item) }
        }
        .buttonStyle(.bordered)
        .disabled(store.isSavingMockExperience)
        .accessibilityIdentifier("phone.collection.use.\(item.id)")
      } else {
        Button {
          Task { await store.purchase(item) }
        } label: {
          Label("\(item.price)", systemImage: "circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(CompanionPalette.mint)
        .disabled(store.isSavingMockExperience)
        .accessibilityLabel("用 \(item.price) 枚金币收藏 \(item.title)")
        .accessibilityIdentifier("phone.collection.buy.\(item.id)")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      CompanionPalette.surface,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("phone.collection.item.\(item.id)")
  }

  @ViewBuilder
  private func itemArtwork(_ item: PhoneCollectionItem) -> some View {
    if let sceneID = item.sceneID {
      Image("scene_\(sceneID)_small")
        .resizable()
        .interpolation(.none)
        .scaledToFill()
        .aspectRatio(1.3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    } else {
      Image(systemName: item.symbol)
        .font(.system(size: 34, weight: .medium))
        .foregroundStyle(CompanionPalette.mint)
        .frame(maxWidth: .infinity)
        .frame(height: 94)
        .background(CompanionPalette.mintSoft)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
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
