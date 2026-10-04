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
    /// Reading, decoding and uploading the screen-size stand-in of a cold frame (P-03): what the first picture costs.
    case screenFrame = "screen-frame"
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
    /// The film strip's want list changes → its first cell is drawn (V-20).
    case filmstripRefresh = "filmstrip-refresh"
    /// A zoom command → the zoomed frame is on screen (M-14; one display frame, 16 ms at 60 Hz).
    case zoom = "zoom"
    /// Computing one frame's histogram (M-17), inside the frame load.
    case histogram = "histogram"
    /// Developing one RAW into a GPU texture (V-02): the filter, the render and the mip chain. 1 s at 24 MP, 2 s at 61 MP.
    case rawDevelop = "raw-develop"
    /// A zero-length mark: a develop finished after it was cancelled and its result was thrown away. Should never appear.
    case rawWasted = "raw-wasted"
    /// A peaking command → the overlay is on screen (V-06; one display frame, 16 ms at 60 Hz). The first frame also runs the analysis.
    case peaking = "peaking"
    /// A clipping command → the overlay is on screen (V-07; one display frame). The first frame also runs the analysis.
    case clipping = "clipping"
    /// Extracting one embedded JPEG (V-13): locate, read, add EXIF if needed, write. A job has one per file.
    case extractFile = "extract-file"
    /// Developing one RAW into a full-size CGImage for export (V-21): the decode and the render. A job has one per file.
    case exportDevelop = "export-develop"
    /// Encoding a developed image to JPEG or HEIC and adding its metadata (V-21). A job has one per file.
    case exportEncode = "export-encode"
    /// Giving the allocator's free pages back to the system once the frame pipeline is idle (P-04).
    case memoryRelief = "memory-relief"

    /// Signpost names must be static strings, so the raw value is repeated here.
    var signpostName: StaticString {
        switch self {
        case .keyToFrame: "key-to-frame"
        case .previewRead: "preview-read"
        case .decode: "decode"
        case .frameLoad: "frame-load"
        case .screenFrame: "screen-frame"
        case .textureUpload: "texture-upload"
        case .sidecarWrite: "sidecar-write"
        case .folderScan: "folder-scan"
        case .captureTimes: "capture-times"
        case .cullFeedback: "cull-feedback"
        case .sidecarRead: "sidecar-read"
        case .gridThumbnail: "grid-thumbnail"
        case .gridFirstScreen: "grid-first-screen"
        case .filmstripRefresh: "filmstrip-refresh"
        case .zoom: "zoom"
        case .histogram: "histogram"
        case .rawDevelop: "raw-develop"
        case .rawWasted: "raw-wasted"
        case .peaking: "peaking"
        case .clipping: "clipping"
        case .extractFile: "extract-file"
        case .exportDevelop: "export-develop"
        case .exportEncode: "export-encode"
        case .memoryRelief: "memory-relief"
        }
    }
}

public enum Perf {
    public static let subsystem = "com.thanosam.Oxys"
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
        if logFile.withLock({ $0 }) != nil {
            record(token.interval.rawValue, Double(DispatchTime.now().uptimeNanoseconds - token.start) / 1_000_000)
        }
    }

    /// Appends `name<TAB>value` to the log file (M-26), so a run can be measured without Instruments.
    /// Intervals are written in milliseconds as they end; the bench adds its own metrics, whose names carry
    /// their unit (`rss-mb`). Does nothing until `enableLog(path:)` has been called.
    public static func record(_ name: String, _ value: Double) {
        logFile.withLock { $0 }?.append("\(name)\t\(value)\n")
    }

    /// Starts the log file (S-6). Only the app's developer-hook build calls this, from `OXYS_PERF_LOG`; the
    /// package reads no environment variable itself, so a release build has no way to turn the log on.
    public static func enableLog(path: String) {
        logFile.withLock { $0 = LogFile(path: path) }
    }

    private static let logFile = Mutex<LogFile?>(nil)

    /// Runs `body` inside an interval.
    public static func measure<T>(_ interval: PerfInterval, _ body: () throws -> T) rethrows -> T {
        let token = begin(interval)
        defer { end(token) }
        return try body()
    }
}

private final class LogFile: Sendable {
    private let handle: Mutex<FileHandle?>

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = Mutex(FileHandle(forWritingAtPath: path))
    }

    func append(_ line: String) {
        handle.withLock { try? $0?.write(contentsOf: Data(line.utf8)) }
    }
}
