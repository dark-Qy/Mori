//
//  WatchCompanionApp.swift
//  WatchCompanion
//
//  Created by shubing on 2026/7/22.
//

import SwiftUI

@main
struct WatchCompanionApp: App {
  @StateObject private var store = PhoneAppStore()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      PhoneRootView(store: store)
    }
    .onChange(of: scenePhase) {
      if scenePhase != .active {
        store.stopMoriSpeech()
      }
    }
  }
}
