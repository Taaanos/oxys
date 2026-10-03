import Containers
import CoreGraphics
import Diagnostics
import Foundation
import ImageIO

public enum PreviewError: Error, Equatable, Sendable {
    /// The file could not be opened or mapped.
    case unreadable(String)
    /// A RAW with no embedded JPEG (or one this reader cannot decode).
    case noPreview
    /// The bytes are there but ImageIO could not decode them: a truncated or corrupt file.
    case corrupt
}

extension PreviewError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "Can't read this file: \(reason)"
        case .noPreview: "This file has no embedded preview."
        case .corrupt: "This file is damaged or incomplete."
        }
    }
}

/// What a decoded preview needs on screen: pixels plus the orientation still to apply.
public struct DecodedPreview: @unchecked Sendable {
    public let image: CGImage
    /// EXIF orientation (1...8) to apply when drawing. The pixels are stored unrotated.
    public let orientation: CGImagePropertyOrientation
    /// Size of the full preview in pixels as stored, before any downscaling to `maxPixelSize`.
    public let sourceWidth: Int
    public let sourceHeight: Int

    /// The size as displayed: width and height swap for the four rotated orientations.
    public var displaySize: (width: Int, height: Int) {
        orientation.swapsAxes ? (image.height, image.width) : (image.width, image.height)
    }
    public var sourceDisplaySize: (width: Int, height: Int) {
        orientation.swapsAxes ? (sourceHeight, sourceWidth) : (sourceWidth, sourceHeight)
    }
}

extension CGImagePropertyOrientation {
    var swapsAxes: Bool { rawValue >= 5 }
}

/// One file's embedded images. Opening maps the file (reads it, on a removable or remote volume: B-3) and reads headers only; pixels are decoded on request
/// and nothing is cached here (M-04 owns caching). Value type, safe to use from any thread.
public struct PreviewSource: Sendable {
    public enum Kind: Sendable, Equatable {
        /// A RAW container: show its embedded JPEG.
        case raw
        /// JPEG, HEIC or TIFF: the file is its own preview.
        case original
    }

    public let url: URL
    public let kind: Kind
    public let located: LocatedPreviews?
    private let data: Data

    /// Below this long edge a TIFF-container image is a thumbnail, not evidence that the file is a RAW.
    static let minimumRawPreviewLongEdge = 512

    /// Maps `url` and locates its embedded previews. `isRaw` is the caller's guess from the extension;
    /// a file named `.tiff` that really is a DNG, PEF or NEF is detected here by its content.
    public static func open(_ url: URL, isRaw: Bool) throws(PreviewError) -> PreviewSource {
        let token = Perf.begin(.previewRead)
        defer { Perf.end(token) }
        let data: Data
        do { data = try FileBytes.load(url) } catch {
            throw .unreadable(error.localizedDescription)
        }
        let located = PreviewLocator.locate(in: data)
        let rawByContent = located?.previews.contains { $0.longEdge >= minimumRawPreviewLongEdge } == true
        if isRaw || rawByContent {
            guard let located, !located.previews.isEmpty else { throw .noPreview }
            return PreviewSource(url: url, kind: .raw, located: located, data: data)
        }
        return PreviewSource(url: url, kind: .original, located: located, data: data)
    }

    /// The embedded JPEG Loupe shows (RAW only; originals show themselves).
    public var loupePreview: EmbeddedJPEG? { located?.largest }

    /// Long edge in pixels of the Loupe image, upright, without decoding it. Nil when unknown (an original).
    public var loupePixelSize: (width: Int, height: Int)? {
        guard kind == .raw, let p = loupePreview else { return nil }
        return Self.orientation(of: p, in: located?.info).swapsAxes ? (p.height, p.width) : (p.width, p.height)
    }

    /// Long edge in pixels of the Loupe image as stored, read from headers only (no decode). Nil when unknown.
    public var loupeLongEdge: Int? {
        switch kind {
        case .raw:
            return loupePreview?.longEdge
        case .original:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            return max(width, height)
        }
    }

    /// Decodes the Loupe image, at most `maxPixelSize` on its long edge (nil: full size).
    ///
    /// `deferred` (P-02): when the image needs no downscaling, the result is not decoded yet. ImageIO decodes it
    /// into whatever bitmap the caller draws it into, so a caller that draws it once (the texture upload) never
    /// holds a second full-size copy. A deferred image decodes on every draw; draw it once. A corrupt file shows
    /// up at that draw, as a blank image, instead of here.
    public func decodeLoupe(maxPixelSize: Int? = nil, deferred: Bool = false) throws(PreviewError) -> DecodedPreview {
        try decode(wanting: nil, maxPixelSize: maxPixelSize, deferred: deferred)
    }

    /// P-03: the Loupe image at 1/`factor` of its size (2, 4 or 8), cut down by the JPEG decoder itself. Like a
    /// `deferred` image it is not decoded yet: ImageIO decodes it, at the reduced size, into the bitmap the caller
    /// draws it into, so there is no intermediate copy. Nil when the image is not one ImageIO can subsample (not a
    /// JPEG): the caller then loads in one step.
    public func decodeLoupe(subsampledBy factor: Int) throws(PreviewError) -> DecodedPreview? {
        let token = Perf.begin(.decode)
        defer { Perf.end(token) }
        let decoded: DecodedPreview
        switch kind {
        case .raw:
            guard let located, let preview = located.largest else { throw .noPreview }
            decoded = try decodeEmbedded(preview, info: located.info, maxPixelSize: nil, deferred: false, subsample: factor)
        case .original:
            decoded = try decodeOriginal(gridEdge: nil, maxPixelSize: nil, deferred: false, subsample: factor)
        }
        // A file that cannot be subsampled comes back at full size.
        let expected = (max(decoded.sourceWidth, decoded.sourceHeight) + factor - 1) / factor
        return abs(max(decoded.image.width, decoded.image.height) - expected) <= 1 ? decoded : nil
    }

    /// Decodes the smallest image whose long edge is at least `longEdge`, downscaled to exactly that long edge
    /// when it is larger.
    public func decodeGrid(longEdge: Int) throws(PreviewError) -> DecodedPreview {
        try decode(wanting: longEdge, maxPixelSize: longEdge)
    }

    private func decode(wanting gridEdge: Int?, maxPixelSize: Int?, deferred: Bool = false) throws(PreviewError) -> DecodedPreview {
        let token = Perf.begin(.decode)
        defer { Perf.end(token) }
        switch kind {
        case .raw:
            guard let located else { throw .noPreview }
            let chosen = gridEdge.map(located.smallestAdequate) ?? located.largest
            guard let preview = chosen else { throw .noPreview }
            return try decodeEmbedded(preview, info: located.info, maxPixelSize: maxPixelSize, deferred: deferred)
        case .original:
            return try decodeOriginal(gridEdge: gridEdge, maxPixelSize: maxPixelSize, deferred: deferred)
        }
    }

    // MARK: Embedded JPEG

    private func decodeEmbedded(_ preview: EmbeddedJPEG, info: ContainerInfo, maxPixelSize: Int?,
                                deferred: Bool, subsample: Int? = nil) throws(PreviewError) -> DecodedPreview {
        let bytes = PreviewLocator.bytes(of: preview, in: data)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let decoded = Self.thumbnail(of: source, maxPixelSize: maxPixelSize.map { min($0, preview.longEdge) },
                                           fromEmbeddedThumbnail: false,
                                           deferringBelow: deferred ? preview.longEdge : nil, subsample: subsample)
        else { throw .corrupt }
        let space = Self.colorSpace(hasICC: preview.header.hasICCProfile,
                                    interop: preview.header.exifInteropIndex ?? info.interopIndex)
        let image = preview.header.hasICCProfile ? decoded : (decoded.copy(colorSpace: space) ?? decoded)
        return DecodedPreview(image: image, orientation: Self.orientation(of: preview, in: info),
                              sourceWidth: preview.width, sourceHeight: preview.height)
    }

    /// The preview's own Exif orientation, else its container's tag, else the main image's (DNG reduced previews).
    static func orientation(of preview: EmbeddedJPEG, in info: ContainerInfo?) -> CGImagePropertyOrientation {
        let value = preview.header.exifOrientation ?? preview.containerOrientation ?? info?.orientation ?? 1
        return CGImagePropertyOrientation(rawValue: UInt32(value)) ?? .up
    }

    /// An embedded ICC profile is honored by ImageIO. Without one, `R03` means Adobe RGB and anything else sRGB.
    static func colorSpace(hasICC: Bool, interop: String?) -> CGColorSpace {
        interop == "R03" ? CGColorSpace(name: CGColorSpace.adobeRGB1998)! : CGColorSpace(name: CGColorSpace.sRGB)!
    }

    // MARK: Originals

    private func decodeOriginal(gridEdge: Int?, maxPixelSize: Int?, deferred: Bool,
                                subsample: Int? = nil) throws(PreviewError) -> DecodedPreview {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw .corrupt }
        let raw = props[kCGImagePropertyOrientation] as? UInt32
        let orientation = raw.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        guard let decoded = Self.thumbnail(of: source, maxPixelSize: maxPixelSize.map { min($0, max(width, height)) },
                                           fromEmbeddedThumbnail: gridEdge != nil,
                                           deferringBelow: deferred ? max(width, height) : nil, subsample: subsample)
        else { throw .corrupt }
        // A JPEG with no ICC profile is sRGB, or Adobe RGB when its Exif says so. HEIC and TIFF carry their own.
        var image = decoded
        if let header = JPEGHeader.parse(ByteReader(data: data), at: 0), !header.hasICCProfile {
            let space = Self.colorSpace(hasICC: false, interop: header.exifInteropIndex)
            image = decoded.copy(colorSpace: space) ?? decoded
        }
        return DecodedPreview(image: image, orientation: orientation, sourceWidth: width, sourceHeight: height)
    }

    // MARK: ImageIO

    /// Decodes without applying orientation (callers get it separately). `fromEmbeddedThumbnail` lets ImageIO use
    /// the file's own thumbnail when it is big enough; if it is too small the full image is decoded instead.
    /// `deferringBelow`: the image's long edge when the caller wants an undecoded image; it applies only when
    /// `maxPixelSize` does not shrink the image.
    static func thumbnail(of source: CGImageSource, maxPixelSize: Int?, fromEmbeddedThumbnail: Bool,
                          deferringBelow fullEdge: Int? = nil, subsample: Int? = nil) -> CGImage? {
        if let subsample {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceSubsampleFactor: subsample,
                                                               kCGImageSourceShouldCache: false] as CFDictionary)
        }
        if let fullEdge, maxPixelSize.map({ $0 >= fullEdge }) ?? true {
            // No ImageIO cache either: the default would keep the decoded pixels after the first draw.
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if fromEmbeddedThumbnail {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            if let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               max(small.width, small.height) >= maxPixelSize { return small }
        }
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
