import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A format a developed RAW can be exported in (V-21).
public enum DevelopedFormat: String, Sendable, CaseIterable {
    /// 8-bit sRGB.
    case jpeg
    /// 10-bit Display P3.
    case heic

    public var type: UTType { self == .jpeg ? .jpeg : .heic }
    public var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
    /// The color space the pixels are rendered in and the profile that is embedded.
    var colorSpaceName: CFString { self == .jpeg ? CGColorSpace.sRGB : CGColorSpace.displayP3 }
    /// 16 bits per channel for HEIC: the encoder then writes 10-bit samples, not 8.
    var pixelFormat: CIFormat { self == .jpeg ? .RGBA8 : .RGBA16 }
    /// Default `kCGImageDestinationLossyCompressionQuality`.
    public var defaultQuality: Double { self == .jpeg ? 0.92 : 0.8 }
}

public enum DevelopedError: Error, Equatable {
    case cannotRender
    case cannotEncode
}

/// Develops a RAW at the decoder's defaults and encodes it to JPEG or HEIC (V-21). It has its own `CIContext`, so it
/// never touches the viewer's GPU context or its one-frame develop slot. Metadata is not its job: it gets the
/// properties and XMP to write (see ``ExportMetadata``) and the caller finishes the file.
public final class DevelopedRenderer: @unchecked Sendable {
    // `CIContext` is documented as safe to use from several threads.
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
        .cacheIntermediates: false,
    ])

    public init() {}

    /// Whether this system can write `format`. HEIC needs the hardware or software HEVC encoder.
    public static func isSupported(_ format: DevelopedFormat) -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(format.type.identifier) ?? false
    }

    /// The developed image, upright, with the decoder's own sharpening, noise reduction and lens correction.
    /// `minLongEdge` is the long edge of the largest embedded preview; a decode smaller than that is only the
    /// thumbnail (see ``RawDeveloper``).
    public func develop(_ url: URL, minLongEdge: Int) throws(RawDevelopError) -> CIImage {
        let filter = try RawDeveloper.defaultFilter(for: url, minLongEdge: minLongEdge)
        guard let image = filter.outputImage, !image.extent.isInfinite, !image.extent.isEmpty else { throw .unsupported }
        return image
    }

    /// Renders to pixels in the format's color space.
    public func render(_ image: CIImage, as format: DevelopedFormat) throws(DevelopedError) -> CGImage {
        guard let space = CGColorSpace(name: format.colorSpaceName),
              let cg = context.createCGImage(image, from: image.extent, format: format.pixelFormat, colorSpace: space)
        else { throw .cannotRender }
        return cg
    }

    /// Encodes with `properties` (from ``ExportMetadata/properties(from:width:height:)``) and, if given, `xmp`.
    public static func encode(_ image: CGImage, as format: DevelopedFormat, quality: Double,
                              properties: [CFString: Any] = [:], xmp: CGImageMetadata? = nil) throws(DevelopedError) -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.type.identifier as CFString, 1, nil) else {
            throw .cannotEncode
        }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.05), 1)
        if let xmp {
            CGImageDestinationAddImageAndMetadata(destination, image, xmp, options as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw .cannotEncode }
        return output as Data
    }
}
