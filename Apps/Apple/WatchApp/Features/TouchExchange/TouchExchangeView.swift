import SwiftUI
import WatchKit

struct TouchExchangeView: View {
  @ObservedObject private var exchange: TouchExchangeViewModel
  private let socialSharingEnabled: Bool
  @State private var successPulse = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var automaticallyConfirmsExchange: Bool {
    #if DEBUG
      !ProcessInfo.processInfo.arguments.contains("--touch-exchange-manual-confirm")
    #else
      true
    #endif
  }

  init(
    exchange: TouchExchangeViewModel,
    socialSharingEnabled: Bool
  ) {
    self.exchange = exchange
    self.socialSharingEnabled = socialSharingEnabled
  }

  var body: some View {
    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(spacing: AdventureSpacing.medium) {
          phaseArtwork
            .id("touch-exchange-transfer-artwork")
          phaseContent
        }
        .padding(.horizontal, AdventureSpacing.page)
        .padding(.bottom, AdventureSpacing.large)
      }
      .background(AdventurePalette.background.ignoresSafeArea())
      .navigationTitle("触碰交换")
      .navigationBarTitleDisplayMode(.inline)
      .accessibilityIdentifier("watch.touch-exchange")
      .onChange(of: exchange.phase) { _, phase in
        if phase == .approaching {
          WKInterfaceDevice.current().play(.notification)
          return
        }
        guard phase == .completed else { return }
        guard exchange.transferPresentation == nil else { return }
        WKInterfaceDevice.current().play(.success)
        guard !reduceMotion else { return }
        withAnimation(.bouncy(duration: 0.55)) {
          successPulse.toggle()
        }
      }
      .onChange(of: exchange.transferPresentation?.eventID) { _, eventID in
        guard eventID != nil else { return }
        if reduceMotion {
          scrollProxy.scrollTo("touch-exchange-transfer-artwork", anchor: .top)
        } else {
          withAnimation(.easeOut(duration: 0.22)) {
            scrollProxy.scrollTo("touch-exchange-transfer-artwork", anchor: .top)
          }
        }
      }
      .onChange(of: socialSharingEnabled) { _, enabled in
        exchange.updateSocialSharingEnabled(enabled)
        guard enabled, exchange.phase == .idle else { return }
        exchange.start()
      }
      .task {
        await exchange.runVisualDemoIfRequested()
        guard exchange.phase == .idle, exchange.socialSharingEnabled else { return }
        exchange.start()
      }
    }
  }

  @ViewBuilder private var phaseContent: some View {
    switch exchange.phase {
    case .idle:
      explanation
      if exchange.socialSharingEnabled {
        progressCard(
          title: "准备自动发现",
          detail: "另一块手表进入触碰交换并靠近后，会自动完成配对与交换。"
        )
      } else {
        Text(
          "好友分享已关闭。关闭时不会寻找设备，也不会上传公开宠物卡；可以稍后在 iPhone 隐私设置中重新开启。"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("watch.touch-exchange.sharing-gate")
        primaryButton("好友分享已关闭", systemImage: "lock.fill") {}
          .disabled(true)
          .accessibilityIdentifier("watch.touch-exchange.start")
      }

    case .joining:
      progressCard(
        title: "正在寻找另一块手表",
        detail: exchange.statusText
      )
      cancelButton

    case .approaching:
      progressCard(
        title: "已经找到对方",
        detail: exchange.statusText
      )
      .accessibilityIdentifier("watch.touch-exchange.candidate-found")
      cancelButton

    case .preview:
      if let peer = exchange.peerCard {
        peerCard(peer)
      }
      if automaticallyConfirmsExchange {
        progressCard(
          title: "距离已确认",
          detail: "正在自动完成交换"
        )
      } else {
        primaryButton("确认交换", systemImage: "checkmark.circle.fill") {
          exchange.confirm()
        }
        .accessibilityIdentifier("watch.touch-exchange.confirm")
      }
      cancelButton

    case .awaitingPeer:
      if exchange.canConfirm {
        if let peer = exchange.peerCard {
          peerCard(peer)
        }
        if automaticallyConfirmsExchange {
          progressCard(
            title: "对方已经确认",
            detail: "正在自动完成你的确认"
          )
        } else {
          Text("对方已经确认。还需要你主动确认，交换才会完成。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("watch.touch-exchange.peer-first-message")
          primaryButton("确认交换", systemImage: "checkmark.circle.fill") {
            exchange.confirm()
          }
          .accessibilityIdentifier("watch.touch-exchange.confirm")
        }
      } else {
        progressCard(
          title: "已确认",
          detail: "正在等待对方确认。只有双方都同意后才会完成交换。"
        )
      }
      cancelButton

    case .cancelling:
      progressCard(
        title: "正在确认取消结果",
        detail: exchange.statusText
      )

    case .completed:
      VStack(alignment: .leading, spacing: 5) {
        Label("遇见卡交换成功", systemImage: "checkmark.seal.fill")
          .font(.headline)
          .foregroundStyle(AdventurePalette.mint)
        if let peer = exchange.peerCard {
          Text("Mori 和 \(peer.displayName) 完成了这次相遇。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        Text(exchange.statusText)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
          .accessibilityIdentifier("watch.touch-exchange.persistence-status")
      }
      .accessibilityIdentifier("watch.touch-exchange.completed")

    case .failed:
      VStack(alignment: .leading, spacing: 5) {
        Label("这次没有交换", systemImage: "exclamationmark.triangle.fill")
          .font(.headline)
          .foregroundStyle(AdventurePalette.rose)
        Text(exchange.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityIdentifier("watch.touch-exchange.failed")
      primaryButton("重新尝试", systemImage: "arrow.clockwise") {
        exchange.retry()
      }
      .accessibilityIdentifier("watch.touch-exchange.retry")

    case .cancellationUnconfirmed:
      VStack(alignment: .leading, spacing: 5) {
        Label("取消状态未确认", systemImage: "wifi.exclamationmark")
          .font(.headline)
          .foregroundStyle(AdventurePalette.rose)
        Text(exchange.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityIdentifier("watch.touch-exchange.cancel-unconfirmed")
      primaryButton("重新确认", systemImage: "arrow.clockwise") {
        exchange.retry()
      }
      .accessibilityIdentifier("watch.touch-exchange.retry")

    case .cancelled:
      VStack(alignment: .leading, spacing: 5) {
        Label("已取消", systemImage: "xmark.circle.fill")
          .font(.headline)
        Text(exchange.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityIdentifier("watch.touch-exchange.cancelled")
      primaryButton("再次开始", systemImage: "wave.3.right") {
        exchange.retry()
      }
      .accessibilityIdentifier("watch.touch-exchange.retry")
    }
  }

  @ViewBuilder private var phaseArtwork: some View {
    if exchange.phase == .completed,
      let presentation = exchange.transferPresentation
    {
      TouchExchangePetTransferView(presentation: presentation)
    } else {
      ZStack {
        Circle()
          .fill(AdventurePalette.blue.opacity(0.14))
          .frame(width: 100, height: 100)

        HStack(spacing: exchange.phase == .completed ? -4 : 20) {
          Image(systemName: "pawprint.fill")
            .foregroundStyle(AdventurePalette.mint)
          Image(systemName: "pawprint.fill")
            .foregroundStyle(AdventurePalette.gold)
        }
        .font(.system(size: 31, weight: .semibold))
        .scaleEffect(successPulse ? 1.12 : 0.94)
        .animation(
          reduceMotion ? nil : .smooth(duration: 0.35),
          value: exchange.phase
        )
      }
      .accessibilityHidden(true)
    }
  }

  private var explanation: some View {
    VStack(alignment: .leading, spacing: 5) {
      Label("只交换公开的宠物状态", systemImage: "lock.shield.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(AdventurePalette.blue)
      Text("两块手表都保持 Mori 在前台，靠近后会自动交换。不会交换睡眠、心率、生命力或其他健康推导信息。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
      Text("你将公开：\(exchange.localSocialStatusText)")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(AdventurePalette.mint)
        .padding(.top, 4)
        .accessibilityIdentifier("watch.touch-exchange.local-social-state")
    }
  }

  private func progressCard(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: AdventureSpacing.small) {
        ProgressView()
        Text(title)
          .font(.subheadline.weight(.semibold))
      }
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("watch.touch-exchange.progress")
  }

  private func peerCard(_ peer: TouchExchangePeerCard) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(peer.displayName, systemImage: "pawprint.circle.fill")
        .font(.headline)
        .foregroundStyle(AdventurePalette.gold)
      Text(peer.socialStatusText)
        .font(.caption)
        .padding(.top, 4)
      Text("角色 \(peer.petAssetID) · 公开游戏状态")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }
    .padding(.vertical, 7)
    .overlay(alignment: .bottom) {
      Divider()
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("watch.touch-exchange.peer-card")
  }

  private func primaryButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .tint(AdventurePalette.mint)
  }

  private var cancelButton: some View {
    Button("取消", role: .cancel) {
      exchange.cancel()
    }
    .buttonStyle(.bordered)
    .accessibilityIdentifier("watch.touch-exchange.cancel")
  }
}
