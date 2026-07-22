// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "CompanionCore",
  platforms: [
    .iOS(.v17),
    .watchOS(.v10),
    .macOS(.v14),
  ],
  products: [
    .library(name: "Domain", targets: ["Domain"]),
    .library(name: "Rules", targets: ["Rules"]),
    .library(name: "Story", targets: ["Story"]),
    .library(name: "Growth", targets: ["Growth"]),
    .library(name: "Persistence", targets: ["Persistence"]),
    .library(name: "Sync", targets: ["Sync"]),
    .library(name: "MockKit", targets: ["MockKit"]),
  ],
  targets: [
    .target(name: "Domain"),
    .target(name: "Rules", dependencies: ["Domain"]),
    .target(name: "Story", dependencies: ["Domain"]),
    .target(name: "Growth", dependencies: ["Domain", "Rules", "Story"]),
    .target(name: "Persistence", dependencies: ["Domain"]),
    .target(name: "Sync", dependencies: ["Domain"]),
    .target(
      name: "MockKit",
      dependencies: ["Domain", "Rules", "Story", "Growth", "Persistence", "Sync"]
    ),
    .testTarget(
      name: "CompanionCoreTests",
      dependencies: ["Domain", "Rules", "Story", "Growth", "Persistence", "Sync", "MockKit"]
    ),
  ]
)
