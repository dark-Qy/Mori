import SwiftUI

struct WardrobeView: View {
  let model: PhonePresentationModel
  @State private var selectedItemID = "scarf"

  private let items = WardrobeItem.samples

  var body: some View {
    PhonePage {
      VStack(alignment: .leading, spacing: CompanionSpacing.medium) {
        PhoneMockBadge(scenarioName: model.scenario.displayName)
          .padding(.top, CompanionSpacing.small)

        VStack(spacing: CompanionSpacing.medium) {
          ZStack {
            Circle()
              .fill(CompanionPalette.mintSoft)
              .frame(width: 146, height: 146)
            Image(systemName: "pawprint.fill")
              .font(.system(size: 64, weight: .semibold))
              .foregroundStyle(CompanionPalette.mint)
            if let item = items.first(where: { $0.id == selectedItemID }) {
              Image(systemName: item.overlaySymbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(item.color)
                .offset(x: 46, y: -48)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(
            "Mori 当前装扮，\(items.first(where: { $0.id == selectedItemID })?.name ?? "无")"
          )
          .accessibilityIdentifier("phone.wardrobe-preview")
          Text("装扮会在下次同步时出现在手表上")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CompanionSpacing.large)
        .background(
          CompanionPalette.surface,
          in: RoundedRectangle(cornerRadius: CompanionRadius.hero, style: .continuous))

        Text("已拥有")
          .font(.headline)

        LazyVGrid(
          columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: CompanionSpacing.medium
        ) {
          ForEach(items) { item in
            Button {
              selectedItemID = item.id
            } label: {
              VStack(alignment: .leading, spacing: CompanionSpacing.small) {
                Image(systemName: item.overlaySymbol)
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
                  if selectedItemID == item.id {
                    Image(systemName: "checkmark.circle.fill")
                      .foregroundStyle(CompanionPalette.mint)
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
                    selectedItemID == item.id ? CompanionPalette.mint : Color.clear, lineWidth: 2)
              }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.name)\(selectedItemID == item.id ? "，已装备" : "")")
            .accessibilityIdentifier("phone.wardrobe.\(item.id)")
          }
        }
      }
    }
    .navigationTitle("衣橱")
    .accessibilityIdentifier("phone.wardrobe")
  }
}

private struct WardrobeItem: Identifiable {
  let id: String
  let name: String
  let overlaySymbol: String
  let color: Color

  static let samples = [
    WardrobeItem(id: "scarf", name: "冒险围巾", overlaySymbol: "wind", color: CompanionPalette.rose),
    WardrobeItem(
      id: "leaf", name: "发光叶子", overlaySymbol: "leaf.fill", color: CompanionPalette.mint),
    WardrobeItem(
      id: "star", name: "守夜星星", overlaySymbol: "star.fill", color: CompanionPalette.gold),
    WardrobeItem(
      id: "drop", name: "雨滴徽章", overlaySymbol: "drop.fill", color: CompanionPalette.blue),
  ]
}
