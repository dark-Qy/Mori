// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MoriMotion",
  platforms: [
    .iOS(.v17),
    .watchOS(.v10),
    .macOS(.v14),
  ],
  products: [
    .library(name: "MoriMotion", targets: ["MoriMotion"])
  ],
  targets: [
    .target(name: "MoriMotion"),
    .testTarget(name: "MoriMotionTests", dependencies: ["MoriMotion"]),
  ]
)
