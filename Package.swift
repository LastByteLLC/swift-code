// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "junco",
  platforms: [.macOS("26.0"), .iOS("26.0")],
  products: [
    .executable(name: "junco", targets: ["junco"]),
    .executable(name: "junco-eval", targets: ["JuncoEval"]),
    .executable(name: "junco-meta", targets: ["JuncoMeta"]),
    .executable(name: "afm-probe", targets: ["AFMLoraProbe"]),
    .library(name: "JuncoKit", targets: ["JuncoKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.9.0")
  ],
  targets: [
    .target(
      name: "TreeSitterSwiftGrammar",
      path: "Sources/TreeSitterSwiftGrammar",
      sources: ["src/parser.c", "src/scanner.c"],
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("src")]
    ),
    .target(
      name: "JuncoKit",
      dependencies: [
        .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
        "TreeSitterSwiftGrammar"
      ],
      path: "Sources/JuncoKit",
      exclude: ["Resources"]
    ),
    .executableTarget(
      name: "junco",
      dependencies: [
        "JuncoKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ],
      path: "Sources/junco"
    ),
    .executableTarget(
      name: "JuncoEval",
      dependencies: ["JuncoKit"],
      path: "Sources/JuncoEval"
    ),
    .executableTarget(
      name: "AFMLoraProbe",
      dependencies: ["JuncoKit"],
      path: "Sources/AFMLoraProbe"
    ),
    .executableTarget(
      name: "JuncoMeta",
      dependencies: ["JuncoKit"],
      path: "Sources/JuncoMeta"
    ),
    .testTarget(
      name: "JuncoTests",
      dependencies: ["JuncoKit"],
      path: "Tests/JuncoTests",
      exclude: ["Fixtures"]
    )
  ]
)
