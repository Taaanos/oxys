import Containers
import Foundation

/// Builds an Exif APP1 segment that carries what a RAW file knows: IFD0's descriptive tags (camera, date, copyright,
/// serial number...), the whole Exif IFD, the GPS IFD, the interoperability IFD and the maker note (V-13). Values are
/// copied as bytes in the RAW's own byte order. What describes the RAW's pixels (size, strips, compression, CFA,
/// DNG tags) is left out, the thumbnail IFD is left out, and the pixel size is the preview's.
///
/// Maker notes keep offsets inside themselves. For Sony and Canon (offsets from the TIFF header) they are moved by the
/// distance the note moved; Nikon type 3 and Fujifilm notes carry their own base and are copied as they are. A brand
/// that is not known is tried as one whose IFD starts the note and whose offsets count from the TIFF header; a note
/// that does not fit that, or whose offsets leave the note, is not copied, and the result says so.
public enum ExifTransplant {
    public struct Result: Sendable, Equatable {
        public var segment: Data
        public var hadMakerNote: Bool
        public var makerNoteCopied: Bool
        /// The RAW's own XMP packet (tag 0x02BC), for a DNG.
        public var embeddedXMP: Data?
    }

    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var value: Data
        /// Where the value was in the source TIFF (out-of-line values only).
        var sourcePosition: Int?
    }

    /// The pieces of a RAW's metadata, wherever the container keeps them.
    struct Source {
        var order: ByteOrder
        var ifd0: [Entry] = []
        var exif: [Entry] = []
        var gps: [Entry] = []
        var interop: [Entry] = []
        /// The maker note's bytes, and the offset, in the TIFF its offsets count from, where they started.
        var note: Data?
        var noteStart = 0
    }

    /// `raw` is a whole RAW file (TIFF-based, or CR3). Nil for other containers and for files without Exif.
    /// `removePrivate` leaves out what says where the photo was taken and which gear made it (V-22): the GPS IFD, the
    /// camera owner name, the body and lens serial numbers, the image unique ID and the whole maker note (it holds
    /// serial numbers in a form that differs from brand to brand). The result then reports no maker note.
    public static func segment(fromRAW raw: Data, previewWidth: Int, previewHeight: Int, orientation: UInt16?,
                               removePrivate: Bool = false) -> Result? {
        guard let source = readTIFF(raw) ?? readCR3(raw) else { return nil }
        return build(source, previewWidth: previewWidth, previewHeight: previewHeight, orientation: orientation,
                     removePrivate: removePrivate)
    }

    /// The same, from the Exif APP1 segment of a JPEG (marker and length included). It is how a JPEG's own Exif gets
    /// the clean-up of `removePrivate` when the RAW's container is not read (V-22).
    public static func segment(fromExifSegment segment: Data, previewWidth: Int, previewHeight: Int, orientation: UInt16?,
                               removePrivate: Bool = false) -> Result? {
        guard segment.count > 10 else { return nil }
        guard let source = readTIFF(Data(segment.dropFirst(10))) else { return nil }
        return build(source, previewWidth: previewWidth, previewHeight: previewHeight, orientation: orientation,
                     removePrivate: removePrivate)
    }

    // MARK: reading

    private static func unit(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12: 8
        default: 0
        }
    }

    private static func reader(_ data: Data, at start: Int) -> ByteReader? {
        var r = ByteReader(data: data)
        switch r.u16(start) {
        case 0x4949: r.order = .little
        case 0x4D4D: r.order = .big
        default: return nil
        }
        guard r.u16(start + 2) == 42 else { return nil }
        return r
    }

    /// The entries of one IFD. `base` is where its offsets count from.
    private static func entries(_ r: ByteReader, at position: Int, base: Int) -> [Entry]? {
        guard position >= 0, let n = r.u16(position), n > 0, n < 1024 else { return nil }
        var out: [Entry] = []
        for i in 0..<Int(n) {
            let e = position + 2 + i * 12
            guard let tag = r.u16(e), let type = r.u16(e + 2), let count = r.u32(e + 4) else { break }
            let u = unit(type)
            let (size, overflow) = u.multipliedReportingOverflow(by: Int(count))
            guard u > 0, !overflow, size <= 1 << 21 else { continue }
            if size <= 4 {
                guard let v = r.bytes(e + 8, size) else { continue }
                out.append(Entry(tag: tag, type: type, count: count, value: v, sourcePosition: nil))
            } else {
                guard let offset = r.u32(e + 8), let v = r.bytes(base + Int(offset), size) else { continue }
                out.append(Entry(tag: tag, type: type, count: count, value: v, sourcePosition: base + Int(offset)))
            }
        }
        return out
    }

    private static func pointer(_ list: [Entry], _ tag: UInt16, _ r: ByteReader) -> Int? {
        guard let e = list.first(where: { $0.tag == tag }), e.value.count == 4 else { return nil }
        return ByteReader(data: e.value, order: r.order).u32(0).map(Int.init)
    }

    private static func readTIFF(_ raw: Data) -> Source? {
        guard let r = reader(raw, at: 0), let first = r.u32(4),
              let ifd0 = entries(r, at: Int(first), base: 0) else { return nil }
        var s = Source(order: r.order, ifd0: ifd0)
        if let p = pointer(ifd0, 0x8769, r), let list = entries(r, at: p, base: 0) {
            s.exif = list
            if let q = pointer(list, 0xA005, r) { s.interop = entries(r, at: q, base: 0) ?? [] }
        }
        if let p = pointer(ifd0, 0x8825, r) { s.gps = entries(r, at: p, base: 0) ?? [] }
        if let note = s.exif.first(where: { $0.tag == 0x927C }), let at = note.sourcePosition {
            s.note = note.value
            s.noteStart = at
        }
        return s
    }

    /// CR3: `CMT1` is IFD0, `CMT2` the Exif IFD, `CMT3` the Canon maker note and `CMT4` the GPS IFD; each is a small TIFF
    /// whose offsets count from its own header.
    private static func readCR3(_ data: Data) -> Source? {
        let r = ByteReader(data: data)
        guard r.bytes(4, 4) == Data("ftyp".utf8), r.bytes(8, 4) == Data("crx ".utf8) else { return nil }
        var boxes: [String: Range<Int>] = [:]
        func visit(_ range: Range<Int>, depth: Int) {
            var pos = range.lowerBound
            while pos + 8 <= range.upperBound {
                guard let size32 = r.u32(pos), let name = r.bytes(pos + 4, 4) else { break }
                var size = Int(size32), payload = pos + 8
                if size == 1 {
                    guard let big = r.u64(pos + 8) else { break }
                    size = Int(clamping: big); payload = pos + 16
                } else if size == 0 {
                    size = range.upperBound - pos
                }
                let (end, overflow) = pos.addingReportingOverflow(size)
                guard size >= payload - pos, !overflow, end <= range.upperBound else { break }
                switch String(decoding: name, as: UTF8.self) {
                case "moov": if depth < 4 { visit(payload..<end, depth: depth + 1) }
                case "uuid":
                    if depth < 4, r.bytes(payload, 4) == Data([0x85, 0xC0, 0xB6, 0x87]) { visit((payload + 16)..<end, depth: depth + 1) }
                case let t where ["CMT1", "CMT2", "CMT3", "CMT4"].contains(t): boxes[t] = payload..<end
                default: break
                }
                pos = end
            }
        }
        visit(0..<r.count, depth: 0)

        func tiff(_ key: String) -> (ByteReader, Int, [Entry])? {
            guard let range = boxes[key], let tr = reader(data, at: range.lowerBound), let first = tr.u32(range.lowerBound + 4),
                  let list = entries(tr, at: range.lowerBound + Int(first), base: range.lowerBound) else { return nil }
            return (tr, range.lowerBound, list)
        }
        guard let (ir, _, ifd0) = tiff("CMT1") else { return nil }
        var s = Source(order: ir.order, ifd0: ifd0)
        if let (_, _, list) = tiff("CMT2") { s.exif = list.filter { $0.tag != 0xA005 } }
        if let (_, _, list) = tiff("CMT4") { s.gps = list }
        // The note is the IFD without the TIFF header (offsets count from the header, which is 8 bytes before the IFD).
        if let range = boxes["CMT3"], reader(data, at: range.lowerBound) != nil, range.count > 8 {
            s.note = data.subdata(in: (range.lowerBound + 8)..<range.upperBound)
            s.noteStart = 8
        }
        return s
    }

    // MARK: writing

    private static let ifd0Keep: Set<UInt16> = [
        0x010E, 0x010F, 0x0110, 0x011A, 0x011B, 0x0128, 0x0131, 0x0132, 0x013B, 0x013E, 0x013F,
        0x0211, 0x0213, 0x0214, 0x8298, 0xC62F, 0xC614, 0xA430, 0xA431,
    ]
    /// Pointers are written by us; the thumbnail and the sizes are the preview's, not the RAW's.
    private static let exifDrop: Set<UInt16> = [0xA005, 0x927C, 0xA002, 0xA003, 0x8769]
    /// Tags that name the owner or the gear (V-22): IFD0 DNG camera serial `0xC62F`; Exif camera owner `0xA430`, body
    /// serial `0xA431`, lens serial `0xA435` and image unique ID `0xA420`. Artist and Copyright stay: they are the
    /// credit the photographer chose to publish.
    static let privateTags: Set<UInt16> = [0xC62F, 0xA430, 0xA431, 0xA435, 0xA420]

    private static func build(_ source: Source, previewWidth: Int, previewHeight: Int, orientation: UInt16?,
                              removePrivate: Bool) -> Result? {
        var source = source
        if removePrivate {
            source.gps = []
            source.note = nil
            source.ifd0.removeAll { privateTags.contains($0.tag) }
            source.exif.removeAll { privateTags.contains($0.tag) }
        }
        let order = source.order
        func u16(_ v: Int) -> Data { order == .little ? Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) : Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        func u32(_ v: Int) -> Data {
            let b = (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) }
            return Data(order == .little ? b : b.reversed())
        }
        func long(_ tag: UInt16, _ v: Int) -> Entry { Entry(tag: tag, type: 4, count: 1, value: u32(v), sourcePosition: nil) }

        var ifd0 = source.ifd0.filter { ifd0Keep.contains($0.tag) }
        if let o = orientation, (1...8).contains(o) {
            ifd0.append(Entry(tag: 0x0112, type: 3, count: 1, value: u16(Int(o)), sourcePosition: nil))
        }
        // A JPEG's IFD0 must have this one; a RAW often does not.
        if !ifd0.contains(where: { $0.tag == 0x0213 }) { ifd0.append(Entry(tag: 0x0213, type: 3, count: 1, value: u16(1), sourcePosition: nil)) }
        let embeddedXMP = source.ifd0.first { $0.tag == 0x02BC }?.value
        guard !ifd0.isEmpty || !source.exif.isEmpty else { return nil }

        func assemble(includeNote: Bool, userComment: Bool) -> (Data, Int?)? {
            var exif = source.exif.filter { !exifDrop.contains($0.tag) && (userComment || $0.tag != 0x9286) }
            if previewWidth > 0, previewHeight > 0 { exif += [long(0xA002, previewWidth), long(0xA003, previewHeight)] }
            var noteTag: UInt16?
            if includeNote, let n = source.note {
                exif.append(Entry(tag: 0x927C, type: 7, count: UInt32(n.count), value: n, sourcePosition: nil))
                noteTag = 0x927C
            }
            var chain: [[Entry]] = []
            var i0 = ifd0
            var x = exif
            var gps = source.gps
            var interop = source.interop
            if !interop.isEmpty { x.append(long(0xA005, 0)) }
            if !x.isEmpty { i0.append(long(0x8769, 0)) }
            if !gps.isEmpty { i0.append(long(0x8825, 0)) }
            chain = [i0, x, gps, interop]
            for k in chain.indices { chain[k].sort { $0.tag < $1.tag } }
            gps = chain[2]; interop = chain[3]

            // Layout: header, then IFD0, Exif, GPS, Interop; each IFD is followed by its out-of-line values.
            func size(_ list: [Entry]) -> Int {
                list.isEmpty ? 0 : 2 + list.count * 12 + 4 + list.reduce(0) { $0 + ($1.value.count > 4 ? ($1.value.count + 1) & ~1 : 0) }
            }
            var starts: [Int] = []
            var at = 8
            for list in chain { starts.append(at); at += size(list) }
            func setPointer(_ list: inout [Entry], _ tag: UInt16, _ value: Int) {
                if let k = list.firstIndex(where: { $0.tag == tag }) { list[k].value = u32(value) }
            }
            setPointer(&chain[0], 0x8769, starts[1])
            setPointer(&chain[0], 0x8825, starts[2])
            setPointer(&chain[1], 0xA005, starts[3])

            var out = Data(order == .little ? [0x49, 0x49, 0x2A, 0x00] : [0x4D, 0x4D, 0x00, 0x2A]) + u32(8)
            var noteOffset: Int?
            for (k, list) in chain.enumerated() where !list.isEmpty {
                var table = u16(list.count)
                var values = Data()
                let valuesStart = starts[k] + 2 + list.count * 12 + 4
                for e in list {
                    table += u16(Int(e.tag)) + u16(Int(e.type)) + u32(Int(e.count))
                    if e.value.count <= 4 {
                        table += e.value + Data(count: 4 - e.value.count)
                    } else {
                        let position = valuesStart + values.count
                        if e.tag == noteTag, k == 1 { noteOffset = position }
                        table += u32(position)
                        values += e.value
                        if values.count % 2 == 1 { values.append(0) }
                    }
                }
                out += table + u32(0) + values
            }
            return (out, noteOffset)
        }

        func wrap(_ tiff: Data) -> Data? {
            let length = 2 + 6 + tiff.count
            guard length <= 0xFFFF else { return nil }
            return Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + Data("Exif\0\0".utf8) + tiff
        }

        let make = String(decoding: (source.ifd0.first { $0.tag == 0x010F }?.value ?? Data()).prefix { $0 != 0 }, as: UTF8.self).uppercased()
        let hadNote = source.note != nil
        if let note = source.note, let (placed, offset) = assemble(includeNote: true, userComment: true), let offset,
           let moved = rebase(note, make: make, order: order, from: source.noteStart, to: offset),
           let final = replacingNote(in: placed, at: offset, with: moved), let segment = wrap(final) {
            return Result(segment: segment, hadMakerNote: true, makerNoteCopied: true, embeddedXMP: embeddedXMP)
        }
        // Without the note, and then without the user comment, until the segment fits in 64 KB.
        for userComment in [true, false] {
            if let (tiff, _) = assemble(includeNote: false, userComment: userComment), let segment = wrap(tiff) {
                return Result(segment: segment, hadMakerNote: hadNote, makerNoteCopied: false, embeddedXMP: embeddedXMP)
            }
        }
        return nil
    }

    private static func replacingNote(in tiff: Data, at offset: Int, with note: Data) -> Data? {
        guard offset + note.count <= tiff.count else { return nil }
        var out = tiff
        out.replaceSubrange(offset..<(offset + note.count), with: note)
        return out
    }

    /// The note with its internal offsets moved for a new place, or nil when it cannot be moved safely.
    /// `from` and `to` are positions in the TIFF their offsets count from.
    static func rebase(_ note: Data, make: String, order: ByteOrder, from: Int, to: Int) -> Data? {
        let r = ByteReader(data: note, order: order)
        func ifdStart() -> Int? {
            if make.contains("SONY") { return r.bytes(0, 4) == Data("SONY".utf8) ? 12 : 0 }
            // Canon, and any brand not known: the IFD starts the note and its offsets count from the TIFF header. For a
            // brand not known that is a guess, which the checks below turn down when the note does not fit it.
            return 0
        }
        if make.contains("FUJIFILM") { return note }
        if make.contains("NIKON") {
            // Type 3 has its own TIFF header 10 bytes in: nothing to move. Older types are not copied.
            return r.bytes(0, 6) == Data("Nikon\0".utf8) && r.u8(6) == 2 ? note : nil
        }
        guard let ifd = ifdStart(), let n = r.u16(ifd), n > 0, n < 1024 else { return nil }
        let delta = to - from
        var out = note
        func put(_ v: Int, at p: Int) {
            let b = (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) }
            out.replaceSubrange(p..<(p + 4), with: order == .little ? b : b.reversed())
        }
        for i in 0..<Int(n) {
            let e = ifd + 2 + i * 12
            guard let type = r.u16(e + 2), let count = r.u32(e + 4) else { return nil }
            let u = unit(type)
            guard u > 0 else { return nil }
            let (size, overflow) = u.multipliedReportingOverflow(by: Int(count))
            guard !overflow else { return nil }
            if size <= 4 { continue }
            guard let offset = r.u32(e + 8).map(Int.init) else { return nil }
            // The value must lie inside the note; otherwise the note needs more than it carries.
            guard offset >= from, offset - from + size <= note.count, offset + delta >= 0 else { return nil }
            put(offset + delta, at: e + 8)
        }
        // Canon ends its note with a footer: a TIFF header and the offset the note had in the file.
        if make.contains("CANON"), note.count >= 8, r.u16(note.count - 8) == (order == .little ? 0x4949 : 0x4D4D),
           r.u32(note.count - 4).map(Int.init) == from {
            put(to, at: note.count - 4)
        }
        return out
    }
}
