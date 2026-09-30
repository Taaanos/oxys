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
        .testTarget(name: "ImagingTests", dependencies: ["Imaging"]),
    ]
)
