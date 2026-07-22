// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AppleAdapters",
  platforms: [
    .iOS(.v17),
    .watchOS(.v10),
    .macOS(.v14),
  ],
  products: [
    .library(name: "AppleAdapters", targets: ["AppleAdapters"])
  ],
  targets: [
    .target(name: "AppleAdapters"),
    .testTarget(name: "AppleAdaptersTests", dependencies: ["AppleAdapters"]),
  ]
)
