import Containers
import Diagnostics
import Foundation
import Imaging
import Metadata

/// Copies each RAW's largest embedded JPEG into a folder (V-13). The picture data is never re-encoded: it is the
/// bytes of the embedded stream. By default the file also keeps the RAW's metadata: all of its Exif (camera, lens,
/// exposure, date, GPS, maker note), its XMP (the Oxys sidecar's rating and label, or a DNG's own packet), and, as
/// file attributes, its dates, permissions and extended attributes (Finder tags, comments, where-from, quarantine).
/// "Exact bytes" leaves the embedded JPEG untouched; the file attributes are copied in both modes.
///
/// With `removePrivate` (V-22) the file holds no GPS value, no owner name, no serial number, no maker note and no IPTC
/// place or contact fields. That holds in "exact bytes" mode too: the picture data stays unchanged, but the preview's
/// own Exif, XMP and IPTC segments are rewritten without those fields, and the rating and label are not added.
public enum EmbeddedJPEGExtractor {
    public typealias Extracted = ExportedFile
    public typealias Failure = ExportFailure
    public typealias Summary = ExportSummary

    /// Extracts one file into `folder`. Never overwrites: a taken name gets `-1`, `-2`... The file appears whole or not at all.
    /// `sidecar` is the photo's XMP sidecar, whose rating and label go into the JPEG's XMP.
    public static func extract(_ source: URL, into folder: URL, exactBytes: Bool = false, sidecar: URL? = nil,
                               removePrivate: Bool = false) throws -> Extracted {
        let token = Perf.begin(.extractFile)
        defer { Perf.end(token) }
        if let format = PhotoFormat(pathExtension: source.pathExtension), !format.isRaw { throw Failure.notRaw }
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        guard let found = PreviewLocator.locate(in: data), let best = found.largest else { throw Failure.noEmbeddedJPEG }
        var bytes = PreviewLocator.bytes(of: best, in: data)

        var exifAdded = false, xmpAdded = false, noteSkipped = false, xmpSkipped = false
        if !exactBytes || removePrivate {
            let orientation = best.header.exifOrientation ?? best.containerOrientation ?? found.info.orientation
            var exif: Data?
            var embeddedXMP: Data?
            let ownExif = removePrivate ? JPEGSegments.list(bytes)?.first { $0.isExif }.map { bytes.subdata(in: (bytes.startIndex + $0.range.lowerBound)..<(bytes.startIndex + $0.range.upperBound)) } : nil
            if exactBytes {
                // Only the clean-up: the preview's own Exif, without the private fields. No Exif is better than a private one.
                exif = ownExif.flatMap {
                    ExifTransplant.segment(fromExifSegment: $0, previewWidth: best.width, previewHeight: best.height,
                                           orientation: orientation, removePrivate: true)?.segment
                }
            } else if let t = ExifTransplant.segment(fromRAW: data, previewWidth: best.width, previewHeight: best.height,
                                                     orientation: orientation, removePrivate: removePrivate) {
                exif = t.segment
                embeddedXMP = t.embeddedXMP
                noteSkipped = t.hadMakerNote && !t.makerNoteCopied
            } else if removePrivate, let ownExif,
                      let t = ExifTransplant.segment(fromExifSegment: ownExif, previewWidth: best.width, previewHeight: best.height,
                                                     orientation: orientation, removePrivate: true) {
                exif = t.segment   // the container is not read (RAF): the preview's own Exif, cleaned
            } else if !best.header.hasExif || removePrivate {
                // A container whose Exif is not read (RAF keeps its own in the preview): the few fields the RAW states.
                var fields = ExifSegment.Fields(make: found.info.make, model: found.info.model, orientation: orientation)
                fields.dateTimeOriginal = CaptureTime.read(from: source).map(exifDate)
                exif = ExifSegment.build(fields)
            }
            var xmp: Data?
            if !exactBytes {
                let packet = sidecar.flatMap { try? Data(contentsOf: $0) } ?? embeddedXMP
                if removePrivate, let packet {
                    if let clean = ExportMetadata.scrubbedPacket(packet) { xmp = JPEGSegments.xmpSegment(clean) } else { xmpSkipped = true }
                } else {
                    xmp = packet.flatMap(JPEGSegments.xmpSegment)
                }
            }
            if exif != nil || xmp != nil || removePrivate,
               let rewritten = JPEGSegments.rewriting(bytes, exif: exif, xmp: xmp, droppingXMPAndIPTC: removePrivate) {
                bytes = rewritten
                exifAdded = exif != nil
                xmpAdded = xmp != nil && (removePrivate || !(JPEGSegments.list(PreviewLocator.bytes(of: best, in: data))?.contains { $0.isXMP } ?? false))
            }
        }

        let placed = try SafeWrite.place(bytes, in: folder, stem: source.deletingPathExtension().lastPathComponent,
                                         ext: "jpg", attributesFrom: source)
        return Extracted(output: placed.output, renamed: placed.renamed, exifAdded: exifAdded, xmpAdded: xmpAdded,
                         makerNoteSkipped: noteSkipped, xmpSkipped: xmpSkipped, attributeWarnings: placed.warnings)
    }

    /// Runs the job and returns when it is done (see ``ExportRunner``). The work is syscalls and small copies, so it
    /// scales with `parallelism`.
    public static func run(_ sources: [URL], into folder: URL, exactBytes: Bool = false, sidecars: [URL: URL] = [:],
                           removePrivate: Bool = false, parallelism: Int = min(4, ProcessInfo.processInfo.activeProcessorCount),
                           progress: @Sendable (Int) -> Void = { _ in }, isCancelled: @Sendable () -> Bool = { false }) -> Summary {
        ExportRunner.run(sources, into: folder, parallelism: parallelism, removedPrivate: removePrivate, progress: progress, isCancelled: isCancelled) {
            try extract($0, into: folder, exactBytes: exactBytes, sidecar: sidecars[$0], removePrivate: removePrivate)
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
