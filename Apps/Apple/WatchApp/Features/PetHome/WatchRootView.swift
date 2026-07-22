//
//  WatchRootView.swift
//  WatchCompanion Watch App
//
//  Created by shubing on 2026/7/22.
//

import Domain
import SwiftUI

struct WatchRootView: View {
  private let pet = PetState()

  var body: some View {
    VStack {
      Image(systemName: "pawprint.circle.fill")
        .imageScale(.large)
        .foregroundStyle(.tint)
      Text(pet.name)
        .font(.headline)
      Text("Ready for an adventure")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding()
    .accessibilityIdentifier("watch.pet-home")
  }
}

#Preview {
  WatchRootView()
}
