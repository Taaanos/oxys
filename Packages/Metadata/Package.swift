// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Metadata",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Metadata", targets: ["Metadata"]),
    ],
    targets: [
        .target(name: "Metadata"),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata"]),
    ]
)
