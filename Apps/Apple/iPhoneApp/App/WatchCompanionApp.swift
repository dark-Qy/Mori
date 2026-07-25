//
//  WatchCompanionApp.swift
//  WatchCompanion
//
//  Created by shubing on 2026/7/22.
//

import AppRuntime
import SwiftUI
import UIKit

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions:
      [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    RuntimeNotificationRouteObserver.install()
    return true
  }
}

@main
struct WatchCompanionApp: App {
  @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
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
