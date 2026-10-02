import Containers
import Diagnostics
import Foundation
import Metadata
import Synchronization

/// Copies each RAW's largest embedded JPEG into a folder (V-13). The picture data is never re-encoded: it is the
/// bytes of the embedded stream. By default the file also keeps the RAW's metadata: all of its Exif (camera, lens,
/// exposure, date, GPS, maker note), its XMP (the Oxys sidecar's rating and label, or a DNG's own packet), and, as
/// file attributes, its dates, permissions and extended attributes (Finder tags, comments, where-from, quarantine).
/// "Exact bytes" leaves the embedded JPEG untouched; the file attributes are copied in both modes.
public enum EmbeddedJPEGExtractor {
    public struct Extracted: Sendable, Equatable {
        public var output: URL
        /// The name was taken, so a suffix was added.
        public var renamed: Bool
        /// The Exif segment was written from the RAW (or built from its few known fields).
        public var exifAdded: Bool
        public var xmpAdded: Bool
        /// The RAW has a maker note and it could not be copied.
        public var makerNoteSkipped: Bool
        /// What of the file's own attributes could not be copied; empty when all was.
        public var attributeWarnings: [String]
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
        public var xmpAdded = 0
        /// Source name and the name it got, when `name.jpg` was taken.
        public var renamed: [Item] = []
        public var makerNoteSkipped: [String] = []
        /// Source name and what was not copied.
        public var attributeWarnings: [Item] = []
        public var withoutEmbeddedJPEG: [String] = []
        public var notRaw: [String] = []
        public var failed: [Item] = []
        public var cancelled = false
        public var destination: URL?

        public init() {}
        public var hasProblems: Bool {
            !withoutEmbeddedJPEG.isEmpty || !notRaw.isEmpty || !failed.isEmpty || !makerNoteSkipped.isEmpty || !attributeWarnings.isEmpty
        }
    }

    /// Extracts one file into `folder`. Never overwrites: a taken name gets `-1`, `-2`... The file appears whole or not at all.
    /// `sidecar` is the photo's XMP sidecar, whose rating and label go into the JPEG's XMP.
    public static func extract(_ source: URL, into folder: URL, exactBytes: Bool = false, sidecar: URL? = nil) throws -> Extracted {
        let token = Perf.begin(.extractFile)
        defer { Perf.end(token) }
        if let format = PhotoFormat(pathExtension: source.pathExtension), !format.isRaw { throw Failure.notRaw }
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        guard let found = PreviewLocator.locate(in: data), let best = found.largest else { throw Failure.noEmbeddedJPEG }
        var bytes = PreviewLocator.bytes(of: best, in: data)

        var exifAdded = false, xmpAdded = false, noteSkipped = false
        if !exactBytes {
            let orientation = best.header.exifOrientation ?? best.containerOrientation ?? found.info.orientation
            var exif: Data?
            var embeddedXMP: Data?
            if let t = ExifTransplant.segment(fromRAW: data, previewWidth: best.width, previewHeight: best.height, orientation: orientation) {
                exif = t.segment
                embeddedXMP = t.embeddedXMP
                noteSkipped = t.hadMakerNote && !t.makerNoteCopied
            } else if !best.header.hasExif {
                // A container whose Exif is not read (RAF keeps its own in the preview): the few fields the RAW states.
                var fields = ExifSegment.Fields(make: found.info.make, model: found.info.model, orientation: orientation)
                fields.dateTimeOriginal = CaptureTime.read(from: source).map(exifDate)
                exif = ExifSegment.build(fields)
            }
            let packet = sidecar.flatMap { try? Data(contentsOf: $0) } ?? embeddedXMP
            let xmp = packet.flatMap(JPEGSegments.xmpSegment)
            if exif != nil || xmp != nil, let rewritten = JPEGSegments.rewriting(bytes, exif: exif, xmp: xmp) {
                bytes = rewritten
                exifAdded = exif != nil
                xmpAdded = xmp != nil && !(JPEGSegments.list(PreviewLocator.bytes(of: best, in: data))?.contains { $0.isXMP } ?? false)
            }
        }

        // Written to a hidden temporary file, then renamed with RENAME_EXCL: the final name appears whole, and an
        // existing file is never replaced, even by something that appeared a moment ago.
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).oxys-partial")
        var warnings: [String] = []
        do {
            try bytes.write(to: temporary)
            warnings = FileAttributes.copy(from: source, to: temporary)
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
                return Extracted(output: target, renamed: attempt > 0, exifAdded: exifAdded, xmpAdded: xmpAdded,
                                 makerNoteSkipped: noteSkipped, attributeWarnings: warnings)
            }
            let code = errno
            guard code == EEXIST, attempt < 9_999 else {
                try? FileManager.default.removeItem(at: temporary)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            attempt += 1
        }
    }

    /// Runs the job and returns when it is done. Files are worked on by `parallelism` threads (the work is syscalls and
    /// small copies, so it scales); files whose names would collide (`IMG_1.ARW`, `IMG_1.NEF`) stay in one thread, in
    /// order, so the suffixes do not depend on timing. `isCancelled` is checked before each file; a file is written whole,
    /// so a cancel leaves no partial `.jpg`. `progress` gets the number of files done, from any thread.
    public static func run(_ sources: [URL], into folder: URL, exactBytes: Bool = false, sidecars: [URL: URL] = [:],
                           parallelism: Int = min(4, ProcessInfo.processInfo.activeProcessorCount),
                           progress: @Sendable (Int) -> Void = { _ in }, isCancelled: @Sendable () -> Bool = { false }) -> Summary {
        enum Outcome { case done(Extracted), noJPEG, notRaw, failed(String), skipped }
        let outcomes = Mutex([Outcome?](repeating: nil, count: sources.count))
        let finished = Mutex(0)

        var groups: [String: [Int]] = [:]
        for (i, url) in sources.enumerated() { groups[url.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(i) }
        let work = Array(groups.values).sorted { $0[0] < $1[0] }

        let next = Mutex(0)
        let workers = max(1, min(parallelism, work.count))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                let g = next.withLock { n -> Int in defer { n += 1 }; return n }
                guard g < work.count else { return }
                for i in work[g] {
                    guard !isCancelled() else { continue }
                    let outcome: Outcome
                    do {
                        outcome = .done(try extract(sources[i], into: folder, exactBytes: exactBytes, sidecar: sidecars[sources[i]]))
                    } catch Failure.notRaw {
                        outcome = .notRaw
                    } catch Failure.noEmbeddedJPEG {
                        outcome = .noJPEG
                    } catch {
                        outcome = .failed(error.localizedDescription)
                    }
                    outcomes.withLock { $0[i] = outcome }
                    progress(finished.withLock { $0 += 1; return $0 })
                }
            }
        }

        var summary = Summary()
        summary.total = sources.count
        summary.destination = folder
        for (i, source) in sources.enumerated() {
            let name = source.lastPathComponent
            switch outcomes.withLock({ $0[i] }) {
            case nil, .skipped: summary.cancelled = true
            case .done(let result):
                summary.written += 1
                if result.exifAdded { summary.exifAdded += 1 }
                if result.xmpAdded { summary.xmpAdded += 1 }
                if result.makerNoteSkipped { summary.makerNoteSkipped.append(name) }
                if !result.attributeWarnings.isEmpty {
                    summary.attributeWarnings.append(.init(name: name, detail: result.attributeWarnings.joined(separator: ", ")))
                }
                if result.renamed { summary.renamed.append(.init(name: name, detail: result.output.lastPathComponent)) }
            case .noJPEG: summary.withoutEmbeddedJPEG.append(name)
            case .notRaw: summary.notRaw.append(name)
            case .failed(let message): summary.failed.append(.init(name: name, detail: message))
            }
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
