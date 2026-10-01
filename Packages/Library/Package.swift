// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Library",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Library", targets: ["Library"]),
    ],
    dependencies: [
        .package(path: "../Metadata"),
        .package(path: "../Diagnostics"),
    ],
    targets: [
        .target(name: "Library", dependencies: ["Metadata", "Diagnostics"]),
        // M-01 tool: times a folder scan and the capture-time pass.
        .executableTarget(name: "ScanBench", dependencies: ["Library"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    ]
)
