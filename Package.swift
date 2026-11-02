// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "VisorIPhone",
  platforms: [.macOS(.v26)],
  targets: [
    .executableTarget(
      name: "VisorIPhone",
      path: "Sources/VisorIPhone",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
