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
        // M-16 tool: prints EXIF per file and compares it with a reference extractor (PREVIEW_ORACLE).
        .executableTarget(name: "ExifCheck", dependencies: ["Metadata"]),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata"]),
    ]
)
