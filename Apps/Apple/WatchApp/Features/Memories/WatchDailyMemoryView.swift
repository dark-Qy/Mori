import Domain
import SwiftUI

struct WatchDailyMemoryView: View {
  let model: WatchPresentationModel

  private var memoryScene: WatchScenePresentation {
    model.scene
      .applying(backgroundID: "moonlit_forest_camp")
      .applying(mood: .resting)
  }

  var body: some View {
    Group {
      if let collection = model.dailyMomentCollection {
        dailyMoments(collection)
      } else {
        legacyMemory
      }
    }
    .ignoresSafeArea()
    .toolbar(.visible, for: .navigationBar)
    .background(Color.black)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("watch.daily-memory")
  }

  @ViewBuilder
  private func dailyMoments(
    _ collection: WatchDailyMomentCollection
  ) -> some View {
    TabView {
      ForEach(Array(collection.moments.enumerated()), id: \.element.id) {
        index,
        moment in
        GeometryReader { geometry in
          ZStack(alignment: .bottomLeading) {
            Image("scene_\(moment.sceneID)_large")
              .resizable()
              .interpolation(.none)
              .scaledToFill()
              .frame(
                width: geometry.size.width,
                height: geometry.size.height
              )
              .clipped()
              .accessibilityHidden(true)

            LinearGradient(
              colors: [.clear, .black.opacity(0.18), .black.opacity(0.84)],
              startPoint: .top,
              endPoint: .bottom
            )
            .accessibilityHidden(true)

            Image(
              "character_\(collection.characterID)_\(moment.animationID)_00"
            )
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(
              width: min(geometry.size.width * 0.55, 108),
              height: min(geometry.size.height * 0.48, 108)
            )
            .position(
              x: geometry.size.width * 0.68,
              y: geometry.size.height * 0.36
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(moment.timeLabel)
                  .font(.caption2.weight(.bold).monospacedDigit())
                Spacer()
                Text("\(index + 1)/\(collection.moments.count)")
                  .font(.system(size: 9, weight: .medium, design: .monospaced))
              }
              Text(moment.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
              Text(moment.body)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(moment.timeLabel)，\(moment.title)。\(moment.body)，第 \(index + 1) 个，共 \(collection.moments.count) 个"
        )
        .accessibilityIdentifier("watch.daily-moment.\(moment.id)")
      }
    }
    .tabViewStyle(.verticalPage)
    .accessibilityIdentifier("watch.daily-moments")
  }

  private var legacyMemory: some View {
    GeometryReader { geometry in
      ZStack {
        Image(memoryScene.backgroundAssetName(for: geometry.size.width))
          .resizable()
          .interpolation(.none)
          .scaledToFill()
          .frame(width: geometry.size.width, height: geometry.size.height)
          .clipped()
          .accessibilityHidden(true)

        LinearGradient(
          colors: [
            .black.opacity(0.2),
            .clear,
            .black.opacity(0.72),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .accessibilityHidden(true)

        if let mori = memoryScene.slots.first {
          Image(
            memoryScene.frameAssetName(
              characterID: mori.characterID,
              animation: .idleResting,
              index: WatchCharacterAnimation.idleResting.reduceMotionFrameIndex
            )
          )
          .resizable()
          .interpolation(.none)
          .scaledToFit()
          .frame(
            width: min(geometry.size.width * 0.5, 100),
            height: min(geometry.size.height * 0.44, 100)
          )
          .position(
            x: geometry.size.width * 0.68,
            y: geometry.size.height * 0.34
          )
          .accessibilityHidden(true)
        }

        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            Text("今天，我们一起……")
              .font(.headline)
              .foregroundStyle(.white)
              .shadow(radius: 2)

            Spacer(minLength: max(72, geometry.size.height * 0.36))

            HStack {
              Label(model.homeStepsText, systemImage: "shoeprints.fill")
              Spacer(minLength: 8)
              Label(model.homeSleepText, systemImage: "moon.fill")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.65)

            Text(model.sharedMemoryNarrative)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.white)
              .fixedSize(horizontal: false, vertical: true)

            Text(model.sharedMemoryDetail)
              .font(.caption2)
              .foregroundStyle(.white.opacity(0.82))
              .fixedSize(horizontal: false, vertical: true)

            Label(
              model.isLive ? "等待 iPhone 封存" : "Mock 回忆预览",
              systemImage: model.isLive ? "clock" : "hammer"
            )
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AdventurePalette.mint)
          }
          .frame(minHeight: geometry.size.height - 10, alignment: .top)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
        }
      }
    }
  }
}
