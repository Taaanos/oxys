import Containers
import Foundation

/// One TIFF image file directory: the entries, and where its offsets count from. Every read is bounds-checked
/// (the bytes come from files we do not control) and returns nil or an empty list instead of trapping.
struct TIFFDirectory {
    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        /// Absolute position of the entry's 4-byte value-or-offset field.
        let field: Int
    }

    let reader: ByteReader
    /// Offsets in this directory count from here (the TIFF header; a maker note may use its own start).
    let base: Int
    private let entries: [UInt16: Entry]

    init?(reader: ByteReader, at position: Int, base: Int) {
        guard position >= 0, let n = reader.u16(position), n > 0, n < 1024 else { return nil }
        var map: [UInt16: Entry] = [:]
        for i in 0..<Int(n) {
            let e = position + 2 + i * 12
            guard let tag = reader.u16(e), let type = reader.u16(e + 2), let count = reader.u32(e + 4) else { break }
            map[tag] = Entry(tag: tag, type: type, count: Int(count), field: e + 8)
        }
        self.reader = reader
        self.base = base
        self.entries = map
    }

    /// The directory of a TIFF header at `start` (II or MM, 42, offset of the first directory).
    static func firstDirectory(in data: Data, at start: Int) -> TIFFDirectory? {
        var reader = ByteReader(data: data)
        switch reader.u16(start) {
        case 0x4949: reader.order = .little
        case 0x4D4D: reader.order = .big
        default: return nil
        }
        guard reader.u16(start + 2) == 42, let first = reader.u32(start + 4) else { return nil }
        return TIFFDirectory(reader: reader, at: start + Int(first), base: start)
    }

    func entry(_ tag: UInt16) -> Entry? { entries[tag] }

    private static func unitSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12: 8
        default: 0
        }
    }

    /// Absolute position of the entry's value bytes: in the field itself when it fits in four bytes.
    func valuePosition(_ e: Entry) -> Int? {
        let unit = Self.unitSize(e.type)
        guard unit > 0, e.count >= 0, e.count <= 1 << 24 else { return nil }
        if unit * e.count <= 4 { return e.field }
        guard let offset = reader.u32(e.field) else { return nil }
        return base + Int(offset)
    }

    /// Integer values of BYTE, SHORT, LONG and their signed kinds, up to `limit` of them.
    func integers(_ tag: UInt16, limit: Int = 4096) -> [Int] {
        guard let e = entry(tag), let start = valuePosition(e) else { return [] }
        let unit = Self.unitSize(e.type)
        guard [1, 3, 4, 6, 7, 8, 9].contains(e.type) else { return [] }
        return (0..<min(e.count, limit)).compactMap { i in
            let p = start + i * unit
            switch e.type {
            case 1, 7: return reader.u8(p).map(Int.init)
            case 6: return reader.u8(p).map { Int(Int8(bitPattern: $0)) }
            case 3: return reader.u16(p).map(Int.init)
            case 8: return reader.u16(p).map { Int(Int16(bitPattern: $0)) }
            case 4: return reader.u32(p).map(Int.init)
            default: return reader.u32(p).map { Int(Int32(bitPattern: $0)) }
            }
        }
    }

    /// RATIONAL and SRATIONAL values; a zero denominator gives `.nan`.
    func rationals(_ tag: UInt16, limit: Int = 16) -> [Double] {
        guard let e = entry(tag), e.type == 5 || e.type == 10, let start = valuePosition(e) else { return [] }
        return (0..<min(e.count, limit)).compactMap { i in
            let p = start + i * 8
            guard let n = reader.u32(p), let d = reader.u32(p + 4) else { return nil }
            guard d != 0 else { return .nan }
            return e.type == 5 ? Double(n) / Double(d) : Double(Int32(bitPattern: n)) / Double(Int32(bitPattern: d))
        }
    }

    func string(_ tag: UInt16) -> String? {
        guard let e = entry(tag), e.type == 2 || e.type == 7, e.count > 0, e.count < 512,
              let start = valuePosition(e), let raw = reader.bytes(start, e.count) else { return nil }
        let text = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The raw bytes of a value (an UNDEFINED blob such as a maker note), capped at 64 KB.
    func bytes(_ tag: UInt16, limit: Int = 1 << 16) -> Data? {
        guard let e = entry(tag), let start = valuePosition(e) else { return nil }
        return reader.bytes(start, min(Self.unitSize(e.type) * e.count, limit))
    }
}
