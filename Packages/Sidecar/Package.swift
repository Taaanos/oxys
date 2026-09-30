// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Sidecar",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Sidecar", targets: ["Sidecar"]),
    ],
    targets: [
        .target(name: "Sidecar"),
        .testTarget(name: "SidecarTests", dependencies: ["Sidecar"]),
    ]
)
