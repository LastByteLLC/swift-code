// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "junco",
  platforms: [.macOS("26.0"), .iOS("26.0")],
  products: [
    .executable(name: "junco", targets: ["junco"]),
    .executable(name: "junco-eval", targets: ["JuncoEval"]),
    .library(name: "JuncoKit", targets: ["JuncoKit"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "JuncoKit",
      dependencies: [],
      path: "Sources/JuncoKit",
      exclude: ["Resources"]
    ),
    .executableTarget(
      name: "junco",
      dependencies: [
        "JuncoKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/junco"
    ),
    .executableTarget(
      name: "JuncoEval",
      dependencies: ["JuncoKit"],
      path: "Sources/JuncoEval"
    ),
    .testTarget(
      name: "JuncoTests",
      dependencies: ["JuncoKit"],
      path: "Tests/JuncoTests"
    ),
  ]
)
