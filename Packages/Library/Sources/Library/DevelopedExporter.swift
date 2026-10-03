import Containers
import Diagnostics
import Foundation
import ImageIO
import Imaging
import Metadata

/// Develops each RAW at the decoder's defaults and writes a JPEG (8-bit sRGB) or a HEIC (10-bit Display P3) into a
/// folder (V-21). The file keeps the RAW's metadata:
///
/// - **JPEG**: the Exif is the one V-13 builds from the RAW (camera, lens, exposure, date, GPS, maker note), with
///   orientation 1 and the developed size. If the RAW's container is not read, ImageIO's copy of the Exif stays.
/// - **HEIC**: ImageIO writes the Exif, GPS and IPTC. It cannot write a maker note, so a HEIC has none.
/// - **XMP**: the Oxys sidecar's packet (rating and label), or a DNG's own, without its develop settings.
/// - **File**: dates, permissions and extended attributes, as in V-13.
public enum DevelopedExporter {
    /// Develops and writes one file. Never overwrites: a taken name gets `-1`, `-2`... The file appears whole or not at
    /// all. `isCancelled` is checked after the render, the slow step; a render that has started cannot be stopped.
    public static func export(_ source: URL, into folder: URL, as format: DevelopedFormat, quality: Double? = nil,
                              sidecar: URL? = nil, renderer: DevelopedRenderer,
                              isCancelled: () -> Bool = { false }) throws -> ExportedFile {
        if let known = PhotoFormat(pathExtension: source.pathExtension), !known.isRaw { throw ExportFailure.notRaw }
        let data = try FileBytes.load(source)
        let preview = PreviewLocator.locate(in: data)?.largest
        let minLongEdge = max(512, preview.map { max($0.width, $0.height) } ?? 0)

        let developToken = Perf.begin(.exportDevelop)
        let pixels: CGImage
        do {
            pixels = try renderer.render(try renderer.develop(source, minLongEdge: minLongEdge), as: format)
        } catch {
            Perf.end(developToken)
            throw ExportFailure.cannotDevelop(describe(error))
        }
        Perf.end(developToken)
        if isCancelled() { throw CancellationError() }

        let encodeToken = Perf.begin(.exportEncode)
        defer { Perf.end(encodeToken) }
        let sourceProperties = CGImageSourceCreateWithURL(source as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let properties = ExportMetadata.properties(from: sourceProperties, width: pixels.width, height: pixels.height)
        let transplant = ExifTransplant.segment(fromRAW: data, previewWidth: pixels.width, previewHeight: pixels.height, orientation: 1)
        let packet = sidecar.flatMap { try? Data(contentsOf: $0) } ?? transplant?.embeddedXMP
        let xmp = packet.flatMap(ExportMetadata.developedXMP)
        let quality = quality ?? format.defaultQuality

        var bytes: Data
        var noteSkipped = false  // a JPEG whose maker note could not be moved (as in V-13)
        do {
            switch format {
            case .heic:
                bytes = try DevelopedRenderer.encode(pixels, as: .heic, quality: quality, properties: properties, xmp: xmp)
                // ImageIO has no way to write a maker note. This is known for the format, so the summary says it once
                // and does not list every file.
            case .jpeg:
                bytes = try DevelopedRenderer.encode(pixels, as: .jpeg, quality: quality, properties: properties)
                let xmpSegment = xmp.flatMap(ExportMetadata.packet(of:)).flatMap(JPEGSegments.xmpSegment)
                // sRGB has no profile in ImageIO's output; say so in the file, whatever the RAW's Exif ColorSpace says.
                let profile = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData().flatMap { JPEGSegments.iccSegment($0 as Data) }
                if let rewritten = JPEGSegments.rewriting(bytes, exif: transplant?.segment, xmp: xmpSegment, icc: profile) {
                    bytes = rewritten
                }
                noteSkipped = transplant.map { $0.hadMakerNote && !$0.makerNoteCopied } ?? false
            }
        } catch {
            throw ExportFailure.cannotDevelop(describe(error))
        }

        let placed = try SafeWrite.place(bytes, in: folder, stem: source.deletingPathExtension().lastPathComponent,
                                         ext: format.fileExtension, attributesFrom: source)
        return ExportedFile(output: placed.output, renamed: placed.renamed,
                            exifAdded: transplant != nil || sourceProperties[kCGImagePropertyExifDictionary] != nil,
                            xmpAdded: xmp != nil, makerNoteSkipped: noteSkipped,
                            xmpSkipped: packet != nil && xmp == nil, attributeWarnings: placed.warnings)
    }

    /// Runs the job and returns when it is done (see ``ExportRunner``). One file at a time by default: a develop of a
    /// 61 MP RAW holds about half a gigabyte of pixels, and the decoder already uses every core.
    public static func run(_ sources: [URL], into folder: URL, as format: DevelopedFormat, quality: Double? = nil,
                           sidecars: [URL: URL] = [:], parallelism: Int = 1,
                           progress: @Sendable (Int) -> Void = { _ in }, isCancelled: @Sendable () -> Bool = { false }) -> ExportSummary {
        let renderer = DevelopedRenderer()
        return ExportRunner.run(sources, into: folder, parallelism: parallelism, progress: progress, isCancelled: isCancelled) { source in
            // Core Image and ImageIO hand back autoreleased objects, and a worker's loop never returns to a run loop
            // to drain them: without a pool per file the pixels of every file stay in memory until the job ends.
            try autoreleasepool {
                try export(source, into: folder, as: format, quality: quality, sidecar: sidecars[source], renderer: renderer, isCancelled: isCancelled)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case RawDevelopError.unsupported: "The system cannot develop this RAW"
        case RawDevelopError.unreadable: "The file cannot be read"
        case DevelopedError.cannotRender: "The image could not be rendered"
        case DevelopedError.cannotEncode: "The image could not be encoded"
        default: error.localizedDescription
        }
    }
}
