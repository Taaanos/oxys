import Foundation

/// Metadata carried by a JPEG's APP1 Exif segment. Only present on ``JPEGHeader`` when an APP1 Exif segment exists.
public struct JPEGExifInfo: Sendable, Equatable {
    public var orientation: ExifOrientation?
    /// The Exif `InteroperabilityIndex` (`R98` sRGB, `R03` Adobe RGB), when the JPEG's own Exif has one.
    public var interopIndex: String?

    public init(orientation: ExifOrientation? = nil, interopIndex: String? = nil) {
        self.orientation = orientation
        self.interopIndex = interopIndex
    }
}

/// What a JPEG's marker segments say, read without decoding any pixels.
public struct JPEGHeader: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var componentCount: Int
    /// The SOFn marker byte. Lossless modes (SOF3, 7, 11, 15) are how raw sensor data is stored in
    /// CR2, CR3 and DNG, never a picture to show.
    public var sofMarker: UInt8
    public var isLossless: Bool { [0xC3, 0xC7, 0xCB, 0xCF].contains(sofMarker) }
    /// An APP2 `ICC_PROFILE` segment is present.
    public var hasICCProfile: Bool
    /// Present when an APP1 Exif segment is present; eliminates `(hasExif: false, orientation: some)`.
    public var exif: JPEGExifInfo?
    /// Adobe APP14 marker; some previews use it to flag their color transform.
    public var hasAdobeMarker: Bool

    public var hasExif: Bool { exif != nil }
    public var exifOrientation: ExifOrientation? { exif?.orientation }
    public var exifInteropIndex: String? { exif?.interopIndex }

    public init(width: Int, height: Int, componentCount: Int, sofMarker: UInt8 = 0xC0,
                hasICCProfile: Bool = false, exif: JPEGExifInfo? = nil, hasAdobeMarker: Bool = false) {
        self.width = width
        self.height = height
        self.componentCount = componentCount
        self.sofMarker = sofMarker
        self.hasICCProfile = hasICCProfile
        self.exif = exif
        self.hasAdobeMarker = hasAdobeMarker
    }

    /// Parses markers up to the start of scan. Returns nil if `reader` does not begin with
    /// a JPEG (SOI) at `offset` or no frame header is found.
    public static func parse(_ reader: ByteReader, at offset: Int) -> JPEGHeader? {
        guard reader.u8(offset) == 0xFF, reader.u8(offset + 1) == 0xD8 else { return nil }
        var frame: (width: Int, height: Int, componentCount: Int, sofMarker: UInt8)?
        var hasICCProfile = false
        var exif: JPEGExifInfo?
        var hasAdobeMarker = false
        var pos = offset + 2
        while let prefix = reader.u8(pos), prefix == 0xFF {
            guard let marker = reader.u8(pos + 1) else { break }
            if marker == 0xFF { pos += 1; continue }          // fill byte
            if marker == 0x01 || (0xD0...0xD9).contains(marker) { pos += 2; continue }
            var be = reader
            be.order = .big
            guard let length = be.u16(pos + 2).map(Int.init), length >= 2 else { break }
            let body = pos + 4
            switch marker {
            case 0xC0...0xCF where marker != 0xC4 && marker != 0xC8 && marker != 0xCC:
                guard length >= 8,
                      let height = be.u16(body + 1).map(Int.init),
                      let width = be.u16(body + 3).map(Int.init),
                      let componentCount = be.u8(body + 5).map(Int.init),
                      width > 0, height > 0, componentCount > 0 else { return nil }
                frame = (
                    width: width,
                    height: height,
                    componentCount: componentCount,
                    sofMarker: marker
                )
            case 0xE1:
                if be.bytes(body, 6) == Data("Exif\0\0".utf8) {
                    let parsedOrientation = exifOrientation(be, tiffStart: body + 6)
                    let parsedInterop = exifInteropIndex(be, tiffStart: body + 6)
                    if var existing = exif {
                        existing.orientation = parsedOrientation ?? existing.orientation
                        existing.interopIndex = parsedInterop ?? existing.interopIndex
                        exif = existing
                    } else {
                        exif = JPEGExifInfo(orientation: parsedOrientation, interopIndex: parsedInterop)
                    }
                }
            case 0xE2:
                if be.bytes(body, 12) == Data("ICC_PROFILE\0".utf8) { hasICCProfile = true }
            case 0xEE:
                if be.bytes(body, 5) == Data("Adobe".utf8) { hasAdobeMarker = true }
            case 0xDA:
                guard let frame else { return nil }
                return JPEGHeader(width: frame.width, height: frame.height, componentCount: frame.componentCount,
                                  sofMarker: frame.sofMarker, hasICCProfile: hasICCProfile, exif: exif,
                                  hasAdobeMarker: hasAdobeMarker)
            default:
                break
            }
            pos += 2 + length
        }
        guard let frame else { return nil }
        return JPEGHeader(width: frame.width, height: frame.height, componentCount: frame.componentCount,
                          sofMarker: frame.sofMarker, hasICCProfile: hasICCProfile, exif: exif,
                          hasAdobeMarker: hasAdobeMarker)
    }

    private static func exifOrientation(_ reader: ByteReader, tiffStart: Int) -> ExifOrientation? {
        var r = reader
        switch r.u16(tiffStart) {
        case 0x4949: r.order = .little
        case 0x4D4D: r.order = .big
        default: return nil
        }
        guard let ifd = r.u32(tiffStart + 4).map(Int.init), let n = r.u16(tiffStart + ifd) else { return nil }
        for i in 0..<Int(n) {
            let e = tiffStart + ifd + 2 + i * 12
            if r.u16(e) == 0x0112 { return r.u16(e + 8).flatMap(ExifOrientation.init(rawValue:)) }
        }
        return nil
    }

    /// IFD0 → Exif IFD (0x8769) → Interoperability IFD (0xA005) → tag 0x0001, a 4-byte ASCII value stored inline.
    private static func exifInteropIndex(_ reader: ByteReader, tiffStart: Int) -> String? {
        var r = reader
        switch r.u16(tiffStart) {
        case 0x4949: r.order = .little
        case 0x4D4D: r.order = .big
        default: return nil
        }
        func find(_ tag: UInt16, inIFD ifd: Int) -> Int? {
            guard let n = r.u16(tiffStart + ifd) else { return nil }
            for i in 0..<Int(n) {
                let e = tiffStart + ifd + 2 + i * 12
                if r.u16(e) == tag { return e + 8 }
            }
            return nil
        }
        guard let ifd0 = r.u32(tiffStart + 4).map(Int.init),
              let exifField = find(0x8769, inIFD: ifd0), let exif = r.u32(exifField).map(Int.init),
              let interopField = find(0xA005, inIFD: exif), let interop = r.u32(interopField).map(Int.init),
              let valueField = find(0x0001, inIFD: interop),
              let bytes = r.bytes(valueField, 3) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
