import Foundation

/// Builds a small Exif APP1 segment and puts it into a JPEG that has none (V-13). The picture data after the
/// segment is not touched: the output is the input with one segment added.
public enum ExifSegment {
    /// What the RAW knows that its embedded preview often does not.
    public struct Fields: Sendable, Equatable {
        public var make: String?
        public var model: String?
        /// 1...8; nil when the RAW has none.
        public var orientation: UInt16?
        /// EXIF's `yyyy:MM:dd HH:mm:ss`.
        public var dateTimeOriginal: String?

        public init(make: String? = nil, model: String? = nil, orientation: UInt16? = nil, dateTimeOriginal: String? = nil) {
            self.make = make
            self.model = model
            self.orientation = orientation
            self.dateTimeOriginal = dateTimeOriginal
        }

        public var isEmpty: Bool { make == nil && model == nil && orientation == nil && dateTimeOriginal == nil }
    }

    /// The whole segment: `FF E1`, length, `Exif\0\0`, then a little-endian TIFF with IFD0 (make, model, orientation,
    /// a pointer to the Exif IFD) and the Exif IFD (`DateTimeOriginal`). Nil when `fields` is empty.
    public static func build(_ fields: Fields) -> Data? {
        guard !fields.isEmpty else { return nil }

        struct Entry { var tag: UInt16; var type: UInt16; var count: UInt32; var value: Data }
        func ascii(_ tag: UInt16, _ text: String) -> Entry {
            var bytes = Data(text.utf8.filter { $0 != 0 })
            bytes.append(0)
            return Entry(tag: tag, type: 2, count: UInt32(bytes.count), value: bytes)
        }
        var ifd0: [Entry] = []
        if let make = fields.make { ifd0.append(ascii(0x010F, make)) }
        if let model = fields.model { ifd0.append(ascii(0x0110, model)) }
        if let o = fields.orientation, (1...8).contains(o) {
            ifd0.append(Entry(tag: 0x0112, type: 3, count: 1, value: le16(o)))
        }
        var exif: [Entry] = []
        if let date = fields.dateTimeOriginal { exif.append(ascii(0x9003, date)) }
        if !exif.isEmpty { ifd0.append(Entry(tag: 0x8769, type: 4, count: 1, value: Data(count: 4))) }
        guard !ifd0.isEmpty else { return nil }

        // Layout: header (8), IFD0, IFD0's long values, Exif IFD, its long values. Offsets count from the TIFF header.
        func size(_ entries: [Entry]) -> Int { 2 + entries.count * 12 + 4 }
        func extra(_ entries: [Entry]) -> Int { entries.reduce(0) { $0 + ($1.value.count > 4 ? ($1.value.count + 1) & ~1 : 0) } }
        let ifd0Start = 8
        let exifStart = ifd0Start + size(ifd0) + extra(ifd0)
        if let i = ifd0.firstIndex(where: { $0.tag == 0x8769 }) { ifd0[i].value = le32(UInt32(exifStart)) }

        func write(_ entries: [Entry], at start: Int) -> Data {
            var table = le16(UInt16(entries.count))
            var values = Data()
            let valuesStart = start + size(entries)
            for e in entries {
                table += le16(e.tag) + le16(e.type) + le32(e.count)
                if e.value.count <= 4 {
                    table += e.value + Data(count: 4 - e.value.count)
                } else {
                    table += le32(UInt32(valuesStart + values.count))
                    values += e.value
                    if values.count % 2 == 1 { values.append(0) }
                }
            }
            return table + le32(0) + values
        }

        var tiff = Data([0x49, 0x49, 0x2A, 0x00]) + le32(UInt32(ifd0Start))
        tiff += write(ifd0, at: ifd0Start)
        if !exif.isEmpty { tiff += write(exif, at: exifStart) }

        let length = 2 + 6 + tiff.count
        guard length <= 0xFFFF else { return nil }
        return Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + Data("Exif\0\0".utf8) + tiff
    }

    /// `jpeg` with `segment` after the SOI (and after a JFIF APP0, which must come first). Nil if `jpeg` is not a JPEG.
    public static func insert(_ segment: Data, into jpeg: Data) -> Data? {
        let base = jpeg.startIndex
        guard jpeg.count > 4, jpeg[base] == 0xFF, jpeg[base + 1] == 0xD8 else { return nil }
        var at = 2
        if jpeg[base + 2] == 0xFF, jpeg[base + 3] == 0xE0, jpeg.count > 6 {
            let length = Int(jpeg[base + 4]) << 8 | Int(jpeg[base + 5])
            if length >= 2, at + 2 + length <= jpeg.count { at += 2 + length }
        }
        var out = Data(capacity: jpeg.count + segment.count)
        out.append(jpeg[base..<(base + at)])
        out.append(segment)
        out.append(jpeg[(base + at)...])
        return out
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
}
