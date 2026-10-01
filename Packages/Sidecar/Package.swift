// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Sidecar",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Sidecar", targets: ["Sidecar"]),
    ],
    dependencies: [
        .package(path: "../Diagnostics"),
    ],
    targets: [
        .target(name: "Sidecar", dependencies: ["Diagnostics"]),
        // M-08 tool: the kill-mid-write child and the 1,000-decision stress run.
        .executableTarget(name: "SidecarStress", dependencies: ["Sidecar"]),
        .testTarget(name: "SidecarTests", dependencies: ["Sidecar"]),
    ]
)
