// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Containers",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Containers", targets: ["Containers"]),
    ],
    targets: [
        .target(name: "Containers"),
        // F-03 spike tool: lists, verifies against a reference extractor, and times embedded previews.
        .executableTarget(name: "PreviewSpike", dependencies: ["Containers"]),
        .testTarget(name: "ContainersTests", dependencies: ["Containers"]),
    ]
)
