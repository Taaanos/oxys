// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Library",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Library", targets: ["Library"]),
    ],
    dependencies: [
        .package(path: "../Containers"),
        .package(path: "../Metadata"),
        .package(path: "../Diagnostics"),
        .package(path: "../Sidecar"),
    ],
    targets: [
        .target(name: "Library", dependencies: ["Containers", "Metadata", "Diagnostics", "Sidecar"]),
        // M-01 tool: times a folder scan and the capture-time pass.
        .executableTarget(name: "ScanBench", dependencies: ["Library"]),
        // V-13 tool: times extraction of a folder against a plain copy, and compares the bytes with an oracle.
        .executableTarget(name: "ExtractBench", dependencies: ["Library", "Containers"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library", "Containers"]),
    ]
)
