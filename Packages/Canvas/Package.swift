// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Canvas",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Canvas", targets: ["Canvas"]),
    ],
    dependencies: [
        .package(path: "../Diagnostics"),
    ],
    targets: [
        .target(name: "Canvas", dependencies: ["Diagnostics"]),
        .testTarget(name: "CanvasTests", dependencies: ["Canvas"]),
    ]
)
