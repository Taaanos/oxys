import Foundation

/// Rewrites the marker segments in front of a JPEG's scan (V-13): takes out Exif, adds Exif and XMP. The scan data and
/// every other segment are copied byte for byte.
public enum JPEGSegments {
    public struct Segment: Sendable, Equatable {
        public var marker: UInt8
        /// Offsets of the whole segment, marker included.
        public var range: Range<Int>
        public var isExif: Bool
        public var isXMP: Bool
        public var isICC = false
    }

    static let xmpHeader = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
    static let iccHeader = Data("ICC_PROFILE\0".utf8)

    /// The segments from after the SOI up to the start of scan. Nil if `jpeg` does not start with SOI.
    public static func list(_ jpeg: Data) -> [Segment]? {
        let base = jpeg.startIndex
        guard jpeg.count > 4, jpeg[base] == 0xFF, jpeg[base + 1] == 0xD8 else { return nil }
        var out: [Segment] = []
        var pos = 2
        while pos + 4 <= jpeg.count, jpeg[base + pos] == 0xFF {
            let marker = jpeg[base + pos + 1]
            if marker == 0xFF { pos += 1; continue }
            if marker == 0xDA || marker == 0xD9 { break }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { pos += 2; continue }
            let length = Int(jpeg[base + pos + 2]) << 8 | Int(jpeg[base + pos + 3])
            guard length >= 2, pos + 2 + length <= jpeg.count else { break }
            let body = base + pos + 4
            let exif = marker == 0xE1 && length >= 8 && jpeg[body..<(body + 6)].elementsEqual(Data("Exif\0\0".utf8))
            let xmp = marker == 0xE1 && length >= 2 + xmpHeader.count && jpeg[body..<(body + xmpHeader.count)].elementsEqual(xmpHeader)
            let icc = marker == 0xE2 && length >= 2 + iccHeader.count && jpeg[body..<(body + iccHeader.count)].elementsEqual(iccHeader)
            out.append(Segment(marker: marker, range: pos..<(pos + 2 + length), isExif: exif, isXMP: xmp, isICC: icc))
            pos += 2 + length
        }
        return out
    }

    /// `jpeg` without its Exif segments and with `exif`, `xmp` and `icc` (whole segments, marker included) after the
    /// JFIF APP0, if there is one. An `xmp` or `icc` is added only when the JPEG has none of its own. Nil if `jpeg` is
    /// not a JPEG.
    ///
    /// `droppingXMPAndIPTC` (V-22) also takes out the JPEG's own XMP and its Photoshop/IPTC segment (APP13), which can
    /// hold a place name or contact details; `xmp`, if given, is then added.
    public static func rewriting(_ jpeg: Data, exif: Data?, xmp: Data?, icc: Data? = nil, droppingXMPAndIPTC: Bool = false) -> Data? {
        guard let segments = list(jpeg) else { return nil }
        let base = jpeg.startIndex
        let hasXMP = !droppingXMPAndIPTC && segments.contains { $0.isXMP }
        let hasICC = segments.contains { $0.isICC }
        var out = Data(capacity: jpeg.count + (exif?.count ?? 0) + (xmp?.count ?? 0) + (icc?.count ?? 0))
        out.append(jpeg[base..<(base + 2)])
        var cursor = 2
        var inserted = false
        func insert() {
            guard !inserted else { return }
            inserted = true
            if let exif { out.append(exif) }
            if let xmp, !hasXMP { out.append(xmp) }
            if let icc, !hasICC { out.append(icc) }
        }
        for (i, s) in segments.enumerated() {
            if i == 0, s.marker == 0xE0 {
                out.append(jpeg[(base + cursor)..<(base + s.range.upperBound)])
                cursor = s.range.upperBound
                insert()
                continue
            }
            insert()
            if s.isExif || (droppingXMPAndIPTC && (s.isXMP || s.marker == 0xED)) {
                out.append(jpeg[(base + cursor)..<(base + s.range.lowerBound)])
                cursor = s.range.upperBound
            }
        }
        insert()
        out.append(jpeg[(base + cursor)...])
        return out
    }

    /// An XMP APP1 segment around a packet. Nil when the packet does not fit in one segment (65,502 bytes).
    public static func xmpSegment(_ packet: Data) -> Data? {
        let length = 2 + xmpHeader.count + packet.count
        guard !packet.isEmpty, length <= 0xFFFF else { return nil }
        return Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + xmpHeader + packet
    }

    /// An ICC APP2 segment around a whole profile. Nil when the profile does not fit in one segment (65,519 bytes),
    /// which no display profile does.
    public static func iccSegment(_ profile: Data) -> Data? {
        let length = 2 + iccHeader.count + 2 + profile.count
        guard !profile.isEmpty, length <= 0xFFFF else { return nil }
        return Data([0xFF, 0xE2, UInt8(length >> 8), UInt8(length & 0xFF)]) + iccHeader + Data([1, 1]) + profile
    }
}
