// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Commands",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Commands", targets: ["Commands"]),
    ],
    targets: [
        .target(name: "Commands"),
        .testTarget(name: "CommandsTests", dependencies: ["Commands"]),
    ]
)
