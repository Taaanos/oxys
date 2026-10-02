import Containers
import Diagnostics
import Foundation
import Metadata

/// Copies each RAW's largest embedded JPEG into a folder (V-13). The picture data is never re-encoded: it is the
/// bytes of the embedded stream. By default an Exif segment is added when the preview has none, so the file still
/// has its orientation, camera and date; "exact bytes" turns that off.
public enum EmbeddedJPEGExtractor {
    public struct Extracted: Sendable, Equatable {
        public var output: URL
        /// The name was taken, so a suffix was added.
        public var renamed: Bool
        public var exifAdded: Bool
    }

    public enum Failure: Error, Equatable {
        /// A JPEG, HEIC or TIFF original: nothing to extract.
        case notRaw
        case noEmbeddedJPEG
    }

    public struct Summary: Sendable, Equatable {
        public struct Item: Sendable, Equatable { public var name: String; public var detail: String }
        public var total = 0
        public var written = 0
        public var exifAdded = 0
        /// Source name and the name it got, when `name.jpg` was taken.
        public var renamed: [Item] = []
        public var withoutEmbeddedJPEG: [String] = []
        public var notRaw: [String] = []
        public var failed: [Item] = []
        public var cancelled = false
        public var destination: URL?

        public init() {}
        public var hasProblems: Bool { !withoutEmbeddedJPEG.isEmpty || !notRaw.isEmpty || !failed.isEmpty }
    }

    /// Extracts one file into `folder`. Never overwrites: a taken name gets `-1`, `-2`... The file appears whole or not at all.
    public static func extract(_ source: URL, into folder: URL, exactBytes: Bool = false) throws -> Extracted {
        let token = Perf.begin(.extractFile)
        defer { Perf.end(token) }
        if let format = PhotoFormat(pathExtension: source.pathExtension), !format.isRaw { throw Failure.notRaw }
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        guard let found = PreviewLocator.locate(in: data), let best = found.largest else { throw Failure.noEmbeddedJPEG }
        var bytes = PreviewLocator.bytes(of: best, in: data)

        var exifAdded = false
        if !exactBytes, !best.header.hasExif {
            var fields = ExifSegment.Fields(make: found.info.make, model: found.info.model, orientation: found.info.orientation)
            fields.dateTimeOriginal = CaptureTime.dateTimeOriginalString(in: data) ?? CaptureTime.read(from: source).map(exifDate)
            if let segment = ExifSegment.build(fields), let withExif = ExifSegment.insert(segment, into: bytes) {
                bytes = withExif
                exifAdded = true
            }
        }

        // Written to a hidden temporary file, then renamed with RENAME_EXCL: the final name appears whole, and an
        // existing file is never replaced, even by something that appeared a moment ago.
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).oxys-partial")
        do {
            try bytes.write(to: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let stem = source.deletingPathExtension().lastPathComponent
        var attempt = 0
        while true {
            let name = attempt == 0 ? "\(stem).jpg" : "\(stem)-\(attempt).jpg"
            let target = folder.appendingPathComponent(name)
            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                return Extracted(output: target, renamed: attempt > 0, exifAdded: exifAdded)
            }
            let code = errno
            guard code == EEXIST, attempt < 9_999 else {
                try? FileManager.default.removeItem(at: temporary)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            attempt += 1
        }
    }

    /// Runs the job in the caller's thread, one file after another. `isCancelled` is checked between files; a file is
    /// written whole, so a cancel leaves no partial `.jpg`. `progress` gets the number of files done.
    public static func run(_ sources: [URL], into folder: URL, exactBytes: Bool = false,
                           progress: (Int) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> Summary {
        var summary = Summary()
        summary.total = sources.count
        summary.destination = folder
        for (index, source) in sources.enumerated() {
            if isCancelled() { summary.cancelled = true; break }
            let name = source.lastPathComponent
            do {
                let result = try extract(source, into: folder, exactBytes: exactBytes)
                summary.written += 1
                if result.exifAdded { summary.exifAdded += 1 }
                if result.renamed { summary.renamed.append(.init(name: name, detail: result.output.lastPathComponent)) }
            } catch Failure.notRaw {
                summary.notRaw.append(name)
            } catch Failure.noEmbeddedJPEG {
                summary.withoutEmbeddedJPEG.append(name)
            } catch {
                summary.failed.append(.init(name: name, detail: error.localizedDescription))
            }
            progress(index + 1)
        }
        return summary
    }

    static func exifDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: date)
    }
}
