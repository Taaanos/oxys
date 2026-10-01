// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Imaging",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Imaging", targets: ["Imaging"]),
    ],
    targets: [
        .target(name: "Imaging"),
        // F-06 spike tool: CIRAWFilter neutrality flags, sharpness, geometry and decode time per corpus file.
        .executableTarget(name: "RawSpike", dependencies: ["Imaging"]),
        .testTarget(name: "ImagingTests", dependencies: ["Imaging"]),
    ]
)
