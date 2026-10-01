// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Imaging",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Imaging", targets: ["Imaging"]),
    ],
    dependencies: [
        .package(path: "../Containers"),
        .package(path: "../Diagnostics"),
    ],
    targets: [
        .target(name: "Imaging", dependencies: ["Containers", "Diagnostics"]),
        // M-02 tool: renders every file's Loupe and Grid preview upright to PNGs and prints what it found.
        .executableTarget(name: "PreviewCheck", dependencies: ["Imaging"]),
        // F-06 spike tool: CIRAWFilter neutrality flags, sharpness, geometry and decode time per corpus file.
        .executableTarget(name: "RawSpike", dependencies: ["Imaging"]),
        .testTarget(name: "ImagingTests", dependencies: ["Imaging", "Containers"]),
    ]
)
