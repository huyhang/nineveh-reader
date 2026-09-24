// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "NinevehReaderKit",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(name: "NinevehCore", targets: ["NinevehCore"]),
    .library(name: "NinevehKit", targets: ["NinevehKit"]),
    .executable(name: "NinevehReaderApp", targets: ["NinevehReaderApp"]),
    .executable(name: "NinevehScreenshot", targets: ["NinevehScreenshot"]),
  ],
  dependencies: [
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
  ],
  targets: [
    .target(name: "NinevehCore"),
    .target(
      name: "NinevehKit",
      dependencies: [
        "NinevehCore",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ]
    ),
    .executableTarget(name: "NinevehReaderApp", dependencies: ["NinevehKit"]),
    .executableTarget(name: "NinevehScreenshot", dependencies: ["NinevehKit", "NinevehCore"]),
    .testTarget(name: "NinevehCoreTests", dependencies: ["NinevehCore"]),
    .testTarget(
      name: "NinevehKitTests",
      dependencies: [
        "NinevehKit",
        "NinevehCore",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ]
    ),
  ]
)
