// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Canvas",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Canvas", targets: ["Canvas"]),
    ],
    targets: [
        .target(name: "Canvas"),
        .testTarget(name: "CanvasTests", dependencies: ["Canvas"]),
    ]
)
