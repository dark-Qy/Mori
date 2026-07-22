//
//  PhoneRootView.swift
//  WatchCompanion
//
//  Created by shubing on 2026/7/22.
//

import Domain
import SwiftUI

struct PhoneRootView: View {
  private let pet = PetState()

  var body: some View {
    VStack {
      Image(systemName: "pawprint.circle.fill")
        .imageScale(.large)
        .foregroundStyle(.tint)
      Text("Watch Companion")
        .font(.headline)
      Text("\(pet.name) lives on your Watch")
        .foregroundStyle(.secondary)
    }
    .padding()
    .accessibilityIdentifier("phone.root")
  }
}

#Preview {
  PhoneRootView()
}
