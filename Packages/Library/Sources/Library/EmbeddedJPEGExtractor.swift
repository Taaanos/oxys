import Containers
import Diagnostics
import Foundation
import Metadata

/// Copies each RAW's largest embedded JPEG into a folder (V-13). The picture data is never re-encoded: it is the
/// bytes of the embedded stream. By default the file also keeps the RAW's metadata: all of its Exif (camera, lens,
/// exposure, date, GPS, maker note), its XMP (the Oxys sidecar's rating and label, or a DNG's own packet), and, as
/// file attributes, its dates, permissions and extended attributes (Finder tags, comments, where-from, quarantine).
/// "Exact bytes" leaves the embedded JPEG untouched; the file attributes are copied in both modes.
public enum EmbeddedJPEGExtractor {
    public typealias Extracted = ExportedFile
    public typealias Failure = ExportFailure
    public typealias Summary = ExportSummary

    /// Extracts one file into `folder`. Never overwrites: a taken name gets `-1`, `-2`... The file appears whole or not at all.
    /// `sidecar` is the photo's XMP sidecar, whose rating and label go into the JPEG's XMP.
    public static func extract(_ source: URL, into folder: URL, exactBytes: Bool = false, sidecar: URL? = nil) throws -> Extracted {
        let token = Perf.begin(.extractFile)
        defer { Perf.end(token) }
        if let format = PhotoFormat(pathExtension: source.pathExtension), !format.isRaw { throw Failure.notRaw }
        let data = try FileBytes.load(source)
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

        let placed = try SafeWrite.place(bytes, in: folder, stem: source.deletingPathExtension().lastPathComponent,
                                         ext: "jpg", attributesFrom: source)
        return Extracted(output: placed.output, renamed: placed.renamed, exifAdded: exifAdded, xmpAdded: xmpAdded,
                         makerNoteSkipped: noteSkipped, attributeWarnings: placed.warnings)
    }

    /// Runs the job and returns when it is done (see ``ExportRunner``). The work is syscalls and small copies, so it
    /// scales with `parallelism`.
    public static func run(_ sources: [URL], into folder: URL, exactBytes: Bool = false, sidecars: [URL: URL] = [:],
                           parallelism: Int = min(4, ProcessInfo.processInfo.activeProcessorCount),
                           progress: @Sendable (Int) -> Void = { _ in }, isCancelled: @Sendable () -> Bool = { false }) -> Summary {
        ExportRunner.run(sources, into: folder, parallelism: parallelism, progress: progress, isCancelled: isCancelled) {
            try extract($0, into: folder, exactBytes: exactBytes, sidecar: sidecars[$0])
        }
    }

    static func exifDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: date)
    }
}
