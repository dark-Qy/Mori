// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AppRuntime",
  platforms: [
    .iOS(.v17),
    .watchOS(.v10),
    .macOS(.v14),
  ],
  products: [
    .library(name: "AppRuntime", targets: ["AppRuntime"])
  ],
  dependencies: [
    .package(path: "../AppleAdapters"),
    .package(path: "../CompanionCore"),
  ],
  targets: [
    .target(
      name: "AppRuntime",
      dependencies: [
        .product(name: "AppleAdapters", package: "AppleAdapters"),
        .product(name: "Domain", package: "CompanionCore"),
        .product(name: "Growth", package: "CompanionCore"),
        .product(name: "Persistence", package: "CompanionCore"),
      ]
    ),
    .testTarget(
      name: "AppRuntimeTests",
      dependencies: [
        "AppRuntime",
        .product(name: "AppleAdapters", package: "AppleAdapters"),
        .product(name: "Domain", package: "CompanionCore"),
        .product(name: "Growth", package: "CompanionCore"),
        .product(name: "Persistence", package: "CompanionCore"),
      ]
    ),
  ]
)
