import AppRuntime
import SwiftUI

struct WardrobeView: View {
  @ObservedObject var store: PhoneAppStore
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private let items = WardrobeItem.samples
  private var model: PhonePresentationModel { store.model }
  private var equippedItemID: String { store.preferences.selectedOutfitID }
  private var previewItemID: String { store.previewOutfitID }
  private var previewedItem: WardrobeItem? { items.first { $0.id == previewItemID } }
  private var previewIsUnlocked: Bool { store.unlockedOutfitIDs.contains(previewItemID) }

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
        PhoneDataBadge(model: model)
          .padding(.top, CompanionSpacing.small)

        VStack(spacing: CompanionSpacing.medium) {
          ZStack {
            Circle()
              .fill(CompanionPalette.mintSoft)
              .frame(width: 146, height: 146)
            Image(systemName: "pawprint.fill")
              .font(.system(size: 64, weight: .semibold))
              .foregroundStyle(CompanionPalette.mint)
            if let symbol = previewedItem?.overlaySymbol, let item = previewedItem {
              Image(systemName: symbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(item.color)
                .offset(x: 46, y: -48)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(
            "Mori 装扮预览，\(previewedItem?.name ?? "基础外观")，\(previewIsUnlocked ? "已解锁" : "未解锁")"
          )
          .accessibilityIdentifier("phone.wardrobe-preview")
          Text(
            previewItemID == equippedItemID
              ? "当前已装备：\(previewedItem?.name ?? "基础外观")"
              : "正在预览：\(previewedItem?.name ?? "基础外观")"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("phone.wardrobe-selection-state")

          if previewIsUnlocked {
            Button {
              store.equipPreviewedOutfit()
            } label: {
              Label(
                previewItemID == equippedItemID ? "已装备" : "装备这件装扮",
                systemImage: previewItemID == equippedItemID
                  ? "checkmark.circle.fill" : "tshirt.fill"
              )
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(CompanionPalette.mint)
            .disabled(previewItemID == equippedItemID || store.isSavingPreferences)
            .accessibilityIdentifier("phone.wardrobe.equip")
          } else {
            Label("还未解锁；可以预览，但不能装备", systemImage: "lock.fill")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("phone.wardrobe.locked-reason")
          }

          Button("恢复默认外观") {
            store.resetOutfit()
          }
          .buttonStyle(.bordered)
          .disabled(equippedItemID == "default" || store.isSavingPreferences)
          .accessibilityIdentifier("phone.wardrobe.reset")

          if let status = store.statusMessage {
            Text(status)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("phone.wardrobe-sync-status")
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CompanionSpacing.large)
        .background(
          CompanionPalette.surface,
          in: RoundedRectangle(cornerRadius: CompanionRadius.hero, style: .continuous))

        Text("已拥有")
          .font(.headline)

        LazyVGrid(
          columns: wardrobeColumns, spacing: CompanionSpacing.medium
        ) {
          ForEach(items) { item in
            Button {
              store.previewOutfit(item.id)
            } label: {
              VStack(alignment: .leading, spacing: CompanionSpacing.small) {
                Image(systemName: item.overlaySymbol ?? "pawprint.fill")
                  .font(.title2)
                  .foregroundStyle(item.color)
                  .frame(width: 48, height: 48)
                  .background(
                    item.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack {
                  Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CompanionPalette.ink)
                  Spacer()
                  if equippedItemID == item.id {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(CompanionPalette.mint)
                  } else if previewItemID == item.id {
                    Image(systemName: "eye.fill")
                      .foregroundStyle(CompanionPalette.blue)
                  } else if !store.unlockedOutfitIDs.contains(item.id) {
                    Image(systemName: "lock.fill")
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .padding(CompanionSpacing.medium)
              .background(
                CompanionPalette.surface,
                in: RoundedRectangle(cornerRadius: CompanionRadius.card, style: .continuous)
              )
              .overlay {
                RoundedRectangle(cornerRadius: CompanionRadius.card, style: .continuous)
                  .stroke(
                    previewItemID == item.id ? CompanionPalette.blue : Color.clear, lineWidth: 2)
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
              "\(item.name)\(equippedItemID == item.id ? "，已装备" : "")\(store.unlockedOutfitIDs.contains(item.id) ? "" : "，未解锁")"
            )
            .accessibilityIdentifier("phone.wardrobe.preview.\(item.id)")
          }
        }
      }
    }
    .navigationTitle("衣橱")
    .accessibilityIdentifier("phone.wardrobe")
  }

  private var wardrobeColumns: [GridItem] {
    if dynamicTypeSize.isAccessibilitySize {
      return [GridItem(.flexible())]
    }
    return [GridItem(.flexible()), GridItem(.flexible())]
  }
}

private struct WardrobeItem: Identifiable {
  let id: String
  let name: String
  let overlaySymbol: String?
  let color: Color

  static let samples = [
    WardrobeItem(
      id: "default", name: "基础外观", overlaySymbol: nil, color: CompanionPalette.mint),
    WardrobeItem(
      id: "soccer_scarf", name: "球场围巾", overlaySymbol: "wind",
      color: CompanionPalette.rose),
    WardrobeItem(
      id: "scarf", name: "冒险围巾", overlaySymbol: "wind", color: CompanionPalette.rose),
    WardrobeItem(
      id: "leaf", name: "发光叶子", overlaySymbol: "leaf.fill", color: CompanionPalette.mint),
    WardrobeItem(
      id: "star", name: "守夜星星", overlaySymbol: "star.fill", color: CompanionPalette.gold),
    WardrobeItem(
      id: "drop", name: "雨滴徽章", overlaySymbol: "drop.fill", color: CompanionPalette.blue),
  ]
}
