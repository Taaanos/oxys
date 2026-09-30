// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Library",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Library", targets: ["Library"]),
    ],
    targets: [
        .target(name: "Library"),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    ]
)
