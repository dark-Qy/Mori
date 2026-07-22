//
//  WatchCompanionWatchApp.swift
//  WatchCompanion Watch App
//
//  Created by shubing on 2026/7/22.
//

import SwiftUI

@main
struct WatchCompanionWatchApp: App {
  @StateObject private var store = WatchAppStore()

  var body: some Scene {
    WindowGroup {
      WatchRootView(store: store)
    }
  }
}
