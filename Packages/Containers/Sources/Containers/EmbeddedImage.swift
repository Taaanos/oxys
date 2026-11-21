import Foundation

/// One JPEG inside a RAW container, located but not read.
public struct EmbeddedJPEG: Sendable, Equatable {
    /// Where it was found, named after the reference extractor's groups (`IFD0`, `SubIFD1`, `PRVW`, ...)
    /// so the oracle comparison can address it directly.
    public var location: String
    public var offset: Int
    public var length: Int
    /// The container's orientation tag for this image (1...8), nil when absent.
    public var containerOrientation: ExifOrientation?
    public var header: JPEGHeader

    /// Pixel size from the JPEG's own frame header (single source of truth; cannot diverge from `header`).
    public var width: Int { header.width }
    public var height: Int { header.height }
    public var pixelCount: Int { width * height }
    public var longEdge: Int { max(width, height) }

    public init(location: String, offset: Int, length: Int, containerOrientation: ExifOrientation?, header: JPEGHeader) {
        self.location = location
        self.offset = offset
        self.length = length
        self.containerOrientation = containerOrientation
        self.header = header
    }
}

/// Something in the container that looks like an image but is not offered as a preview.
public struct SkippedImage: Sendable, Equatable {
    public var location: String
    public var reason: String
}

/// File-level facts the preview consumer needs to render colors and rotation honestly.
public struct ContainerInfo: Sendable, Equatable {
    public var make: String?
    public var model: String?
    /// `InteroperabilityIndex`: `R98` is sRGB, `R03` is Adobe RGB.
    public var interopIndex: String?
    /// EXIF `ColorSpace`: 1 is sRGB, 0xFFFF is uncalibrated.
    public var exifColorSpace: UInt16?
    /// Orientation of the main image (IFD0), when present.
    public var orientation: ExifOrientation?
}

public struct LocatedPreviews: Sendable, Equatable {
    public var format: String
    public var info: ContainerInfo
    public var previews: [EmbeddedJPEG]
    public var skipped: [SkippedImage]

    /// Largest by pixel count: the preview Loupe shows.
    public var largest: EmbeddedJPEG? { previews.max { $0.pixelCount < $1.pixelCount } }

    /// Smallest whose long edge is at least `longEdge`, falling back to the largest: Grid thumbnails.
    public func smallestAdequate(longEdge: Int) -> EmbeddedJPEG? {
        previews.filter { $0.longEdge >= longEdge }.min { $0.pixelCount < $1.pixelCount } ?? largest
    }
}
