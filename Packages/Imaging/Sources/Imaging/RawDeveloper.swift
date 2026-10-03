import CoreImage
import Foundation

public enum RawDevelopError: Error, Equatable {
    case unreadable
    /// The system decoder gave no image, or only the embedded thumbnail, for this file.
    case unsupported
}

/// Sets up `CIRAWFilter` for V-02: the neutral settings F-06 chose, and the container sniffing F-06 asked for.
public enum RawDeveloper {
    /// Type identifiers tried, in order, for a TIFF-named file. raw.pixls.us serves DNG, PEF and NEF as `.tiff`,
    /// and `CIRAWFilter` trusts the extension, so it gives only the thumbnail for them.
    static let tiffHints = ["com.adobe.raw-image", "com.nikon.raw-image", "com.pentax.raw-image"]

    /// A filter for `url` with every detail control at 0 and lens correction off, so that 1:1 shows the
    /// demosaiced sensor pixels with nothing added or resampled. Tone and white balance stay at the decoder's
    /// defaults (F-06/Q1). The output is already upright. `minLongEdge` is the long edge of the largest embedded
    /// preview: a decode smaller than that is only the thumbnail, so the next container hint is tried.
    public static func neutralFilter(for url: URL, minLongEdge: Int) throws(RawDevelopError) -> CIRAWFilter {
        try filter(for: url, minLongEdge: minLongEdge, neutral: true)
    }

    /// A filter at the decoder's defaults (V-21): as-shot white balance, default tone, and the camera's normal
    /// sharpening, noise reduction and lens correction. This is the look of a file made to be shared.
    public static func defaultFilter(for url: URL, minLongEdge: Int) throws(RawDevelopError) -> CIRAWFilter {
        try filter(for: url, minLongEdge: minLongEdge, neutral: false)
    }

    static func filter(for url: URL, minLongEdge: Int, neutral: Bool) throws(RawDevelopError) -> CIRAWFilter {
        var candidates: [CIRAWFilter?] = [CIRAWFilter(imageURL: url)]
        if ["tif", "tiff"].contains(url.pathExtension.lowercased()),
           let data = try? Data(contentsOf: url, options: .alwaysMapped) {
            candidates += tiffHints.map { CIRAWFilter(imageData: data, identifierHint: $0) }
        }
        for case let filter? in candidates {
            let native = filter.nativeSize
            guard max(native.width, native.height) >= CGFloat(minLongEdge), native.width > 0 else { continue }
            if neutral { neutralize(filter) }
            return filter
        }
        throw .unsupported
    }

    /// Every detail-processing control at 0 where the camera supports it (an unsupported control already
    /// defaults to 0), and lens correction off.
    public static func neutralize(_ f: CIRAWFilter) {
        if f.isSharpnessSupported { f.sharpnessAmount = 0 }
        if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = 0 }
        if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = 0 }
        if f.isDetailSupported { f.detailAmount = 0 }
        if f.isLocalToneMapSupported { f.localToneMapAmount = 0 }
        if f.isMoireReductionSupported { f.moireReductionAmount = 0 }
        if f.isLensCorrectionSupported { f.isLensCorrectionEnabled = false }
    }
}
