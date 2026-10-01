import Foundation

/// What a JPEG's marker segments say, read without decoding any pixels.
public struct JPEGHeader: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var componentCount: Int
    /// The SOFn marker byte. Lossless modes (SOF3, 7, 11, 15) are how raw sensor data is stored in
    /// CR2, CR3 and DNG, never a picture to show.
    public var sofMarker: UInt8 = 0
    public var isLossless: Bool { [0xC3, 0xC7, 0xCB, 0xCF].contains(sofMarker) }
    /// An APP2 `ICC_PROFILE` segment is present.
    public var hasICCProfile: Bool
    /// An APP1 Exif segment is present, and the orientation it carries (nil if it has none).
    public var hasExif: Bool
    public var exifOrientation: UInt16?
    /// Adobe APP14 marker; some previews use it to flag their color transform.
    public var hasAdobeMarker: Bool

    /// Parses markers up to the start of scan. Returns nil if `reader` does not begin with
    /// a JPEG (SOI) at `offset` or no frame header is found.
    public static func parse(_ reader: ByteReader, at offset: Int) -> JPEGHeader? {
        guard reader.u8(offset) == 0xFF, reader.u8(offset + 1) == 0xD8 else { return nil }
        var header = JPEGHeader(width: 0, height: 0, componentCount: 0, sofMarker: 0, hasICCProfile: false,
                                hasExif: false, exifOrientation: nil, hasAdobeMarker: false)
        var pos = offset + 2
        var sawFrame = false
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
                header.height = Int(be.u16(body + 1) ?? 0)
                header.width = Int(be.u16(body + 3) ?? 0)
                header.componentCount = Int(be.u8(body + 5) ?? 0)
                header.sofMarker = marker
                sawFrame = true
            case 0xE1:
                if be.bytes(body, 6) == Data("Exif\0\0".utf8) {
                    header.hasExif = true
                    header.exifOrientation = exifOrientation(be, tiffStart: body + 6)
                }
            case 0xE2:
                if be.bytes(body, 12) == Data("ICC_PROFILE\0".utf8) { header.hasICCProfile = true }
            case 0xEE:
                if be.bytes(body, 5) == Data("Adobe".utf8) { header.hasAdobeMarker = true }
            case 0xDA:
                return sawFrame ? header : nil
            default:
                break
            }
            pos += 2 + length
        }
        return sawFrame ? header : nil
    }

    private static func exifOrientation(_ reader: ByteReader, tiffStart: Int) -> UInt16? {
        var r = reader
        switch r.u16(tiffStart) {
        case 0x4949: r.order = .little
        case 0x4D4D: r.order = .big
        default: return nil
        }
        guard let ifd = r.u32(tiffStart + 4).map(Int.init), let n = r.u16(tiffStart + ifd) else { return nil }
        for i in 0..<Int(n) {
            let e = tiffStart + ifd + 2 + i * 12
            if r.u16(e) == 0x0112 { return r.u16(e + 8) }
        }
        return nil
    }
}
