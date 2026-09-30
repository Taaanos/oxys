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
        .testTarget(name: "ContainersTests", dependencies: ["Containers"]),
    ]
)
