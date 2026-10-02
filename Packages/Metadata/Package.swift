// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Metadata",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Metadata", targets: ["Metadata"]),
    ],
    dependencies: [
        // ByteReader and the container walkers; the maker-note reader (V-01) uses them.
        .package(path: "../Containers"),
    ],
    targets: [
        .target(name: "Metadata", dependencies: [.product(name: "Containers", package: "Containers")]),
        // M-16 tool: prints EXIF per file and compares it with a reference extractor (PREVIEW_ORACLE).
        .executableTarget(name: "ExifCheck", dependencies: ["Metadata"]),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata"]),
    ]
)
