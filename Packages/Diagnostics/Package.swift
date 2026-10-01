// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Diagnostics",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
    ],
    targets: [
        // Signpost intervals and latency statistics, shared by every module on a performance path.
        .target(name: "Diagnostics"),
        // F-02 tool: reads an Instruments trace and prints p50/p95 per interval; `selftest` emits synthetic intervals.
        .executableTarget(name: "PerfTool", dependencies: ["Diagnostics"]),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"]),
    ]
)
