import Foundation
import os
import Synchronization

/// The performance-critical intervals, defined once so the app, the packages and the report tool agree on names.
/// Each one shows up in Instruments' os_signpost track under `Perf.subsystem` / `Perf.category`.
public enum PerfInterval: String, CaseIterable, Sendable {
    /// Key event received → the frame it caused is on screen. The number the PRD's "instant" is judged by.
    case keyToFrame = "key-to-frame"
    /// Locating and reading the embedded preview bytes.
    case previewRead = "preview-read"
    /// Decoding image bytes (embedded JPEG or a developed RAW) into pixels.
    case decode = "decode"
    /// Reading, decoding and uploading one frame in the image pipeline (M-04): the cold cost of a frame.
    case frameLoad = "frame-load"
    /// Handing decoded pixels to the GPU.
    case textureUpload = "texture-upload"
    /// Writing a sidecar (temp file, fsync, rename).
    case sidecarWrite = "sidecar-write"
    /// Listing a folder's photos (M-01): the list the user sees first.
    case folderScan = "folder-scan"
    /// Reading every capture time in a folder, in the background after the list is shown.
    case captureTimes = "capture-times"
    /// A cull key press → the next display frame after the badge was set (M-06; 16 ms at 60 Hz).
    case cullFeedback = "cull-feedback"
    /// Reading every existing sidecar in a folder, in the background after the list is shown (M-07).
    case sidecarRead = "sidecar-read"
    /// Loading one Grid thumbnail: disk cache hit, or decode and store (M-12).
    case gridThumbnail = "grid-thumbnail"
    /// Opening a folder → every thumbnail on the first screen of Grid is drawn (M-12; 300 ms for 1,000 files).
    case gridFirstScreen = "grid-first-screen"
    /// A zoom command → the zoomed frame is on screen (M-14; one display frame, 16 ms at 60 Hz).
    case zoom = "zoom"
    /// Computing one frame's histogram (M-17), inside the frame load.
    case histogram = "histogram"

    /// Signpost names must be static strings, so the raw value is repeated here.
    var signpostName: StaticString {
        switch self {
        case .keyToFrame: "key-to-frame"
        case .previewRead: "preview-read"
        case .decode: "decode"
        case .frameLoad: "frame-load"
        case .textureUpload: "texture-upload"
        case .sidecarWrite: "sidecar-write"
        case .folderScan: "folder-scan"
        case .captureTimes: "capture-times"
        case .cullFeedback: "cull-feedback"
        case .sidecarRead: "sidecar-read"
        case .gridThumbnail: "grid-thumbnail"
        case .gridFirstScreen: "grid-first-screen"
        case .zoom: "zoom"
        case .histogram: "histogram"
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
        let start: UInt64
    }

    public static func begin(_ interval: PerfInterval) -> Token {
        Token(interval: interval,
              state: signposter.beginInterval(interval.signpostName, id: signposter.makeSignpostID()),
              start: DispatchTime.now().uptimeNanoseconds)
    }

    public static func end(_ token: Token) {
        signposter.endInterval(token.interval.signpostName, token.state)
        if logFile.isOn {
            record(token.interval.rawValue, Double(DispatchTime.now().uptimeNanoseconds - token.start) / 1_000_000)
        }
    }

    /// Appends `name<TAB>value` to the file named by `OXYS_PERF_LOG` (M-26), so a run can be measured without
    /// Instruments. Intervals are written in milliseconds as they end; the bench adds its own metrics, whose
    /// names carry their unit (`rss-mb`). Does nothing when the variable is not set.
    public static func record(_ name: String, _ value: Double) {
        logFile.append("\(name)\t\(value)\n")
    }

    private static let logFile = LogFile(path: ProcessInfo.processInfo.environment["OXYS_PERF_LOG"])

    /// Runs `body` inside an interval.
    public static func measure<T>(_ interval: PerfInterval, _ body: () throws -> T) rethrows -> T {
        let token = begin(interval)
        defer { end(token) }
        return try body()
    }
}

private final class LogFile: Sendable {
    private let handle: Mutex<FileHandle?>
    let isOn: Bool

    init(path: String?) {
        var opened: FileHandle?
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            opened = FileHandle(forWritingAtPath: path)
        }
        handle = Mutex(opened)
        isOn = opened != nil
    }

    func append(_ line: String) {
        handle.withLock { try? $0?.write(contentsOf: Data(line.utf8)) }
    }
}
