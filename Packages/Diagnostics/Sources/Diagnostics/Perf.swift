import os

/// The performance-critical intervals, defined once so the app, the packages and the report tool agree on names.
/// Each one shows up in Instruments' os_signpost track under `Perf.subsystem` / `Perf.category`.
public enum PerfInterval: String, CaseIterable, Sendable {
    /// Key event received → the frame it caused is on screen. The number the PRD's "instant" is judged by.
    case keyToFrame = "key-to-frame"
    /// Locating and reading the embedded preview bytes.
    case previewRead = "preview-read"
    /// Decoding image bytes (embedded JPEG or a developed RAW) into pixels.
    case decode = "decode"
    /// Handing decoded pixels to the GPU.
    case textureUpload = "texture-upload"
    /// Writing a sidecar (temp file, fsync, rename).
    case sidecarWrite = "sidecar-write"

    /// Signpost names must be static strings, so the raw value is repeated here.
    var signpostName: StaticString {
        switch self {
        case .keyToFrame: "key-to-frame"
        case .previewRead: "preview-read"
        case .decode: "decode"
        case .textureUpload: "texture-upload"
        case .sidecarWrite: "sidecar-write"
        }
    }
}

public enum Perf {
    public static let subsystem = "dev.oxys.Oxys"
    public static let category = "Performance"

    public static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// An open interval. Hand it to ``end(_:)`` from wherever the work finishes (the key event and the frame
    /// are in different places, so `key-to-frame` cannot use ``measure(_:_:)``).
    public struct Token: Sendable {
        let interval: PerfInterval
        let state: OSSignpostIntervalState
    }

    public static func begin(_ interval: PerfInterval) -> Token {
        Token(interval: interval,
              state: signposter.beginInterval(interval.signpostName, id: signposter.makeSignpostID()))
    }

    public static func end(_ token: Token) {
        signposter.endInterval(token.interval.signpostName, token.state)
    }

    /// Runs `body` inside an interval.
    public static func measure<T>(_ interval: PerfInterval, _ body: () throws -> T) rethrows -> T {
        let token = begin(interval)
        defer { end(token) }
        return try body()
    }
}
