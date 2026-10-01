import Foundation

/// Locates embedded JPEGs in TIFF-based RAW files (ARW, DNG, and by the same structure CR2,
/// NEF, ORF, RW2, PEF) by walking the IFD chain, SubIFDs and the Exif and Interop IFDs.
/// Only headers are touched; the JPEG bytes are not read beyond the marker scan for the size.
public enum TIFFPreviewLocator {
    private enum Tag {
        static let newSubfileType: UInt16 = 0x00FE
        static let compression: UInt16 = 0x0103
        static let photometric: UInt16 = 0x0106
        static let make: UInt16 = 0x010F
        static let model: UInt16 = 0x0110
        static let stripOffsets: UInt16 = 0x0111
        static let orientation: UInt16 = 0x0112
        static let stripByteCounts: UInt16 = 0x0117
        static let subIFDs: UInt16 = 0x014A
        static let tileWidth: UInt16 = 0x0142
        static let jpegInterchangeFormat: UInt16 = 0x0201
        static let jpegInterchangeFormatLength: UInt16 = 0x0202
        static let panasonicJpgFromRaw: UInt16 = 0x002E
        static let exifIFD: UInt16 = 0x8769
        static let colorSpace: UInt16 = 0xA001
        static let interopIFD: UInt16 = 0xA005
        static let interopIndex: UInt16 = 0x0001
    }

    private struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: Int
        var valueOffset: Int   // file offset of the 4-byte value/offset field
    }

    private struct Walker {
        var reader: ByteReader
        var previews: [EmbeddedJPEG] = []
        var skipped: [SkippedImage] = []
        var info = ContainerInfo()
        var visited: Set<Int> = []
        var subIFDCount = 0

        func entries(at ifd: Int) -> [Entry]? {
            guard let n = reader.u16(ifd), n < 4096 else { return nil }
            return (0..<Int(n)).compactMap { i in
                let e = ifd + 2 + i * 12
                guard let tag = reader.u16(e), let type = reader.u16(e + 2), let count = reader.u32(e + 4) else { return nil }
                return Entry(tag: tag, type: type, count: Int(count), valueOffset: e + 8)
            }
        }

        static func typeSize(_ type: UInt16) -> Int {
            switch type {
            case 1, 2, 6, 7: 1
            case 3, 8: 2
            case 4, 9, 11, 13: 4
            case 5, 10, 12: 8
            default: 0
            }
        }

        /// Integer values of a BYTE, SHORT, LONG or IFD entry. Capped so a corrupt count can't allocate wildly.
        func values(_ e: Entry) -> [Int] {
            let size = Self.typeSize(e.type)
            guard size > 0, size <= 4, e.count > 0, e.count <= 1024 else { return [] }
            let total = size * e.count
            let start: Int
            if total <= 4 {
                start = e.valueOffset
            } else {
                guard let p = reader.u32(e.valueOffset) else { return [] }
                start = Int(p)
            }
            return (0..<e.count).compactMap { i in
                switch size {
                case 1: reader.u8(start + i).map(Int.init)
                case 2: reader.u16(start + i * 2).map(Int.init)
                default: reader.u32(start + i * 4).map(Int.init)
                }
            }
        }

        func string(_ e: Entry) -> String? {
            guard e.type == 2, e.count > 0, e.count < 256 else { return nil }
            let start: Int
            if e.count <= 4 { start = e.valueOffset } else {
                guard let p = reader.u32(e.valueOffset) else { return nil }
                start = Int(p)
            }
            guard let raw = reader.bytes(start, e.count) else { return nil }
            let trimmed = raw.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }

        mutating func walkChain(from first: Int, name: (Int) -> String) {
            var ifd = first
            var index = 0
            while ifd > 0, visited.insert(ifd).inserted, let es = entries(at: ifd) {
                walk(ifd: ifd, entries: es, name: name(index))
                guard let n = reader.u16(ifd), let next = reader.u32(ifd + 2 + Int(n) * 12) else { break }
                ifd = Int(next)
                index += 1
            }
        }

        mutating func walk(ifd: Int, entries es: [Entry], name: String) {
            let reading = self
            let first: (UInt16) -> Int? = { tag in es.first { $0.tag == tag }.flatMap { reading.values($0).first } }
            let isMainIFD = name == "IFD0"
            if isMainIFD {
                info.make = es.first { $0.tag == Tag.make }.flatMap(string)
                info.model = es.first { $0.tag == Tag.model }.flatMap(string)
                info.orientation = first(Tag.orientation).map { UInt16($0) }
            }
            classify(es, name: name, first: first, reading: reading)

            for e in es {
                switch e.tag {
                case Tag.subIFDs:
                    for offset in values(e) {
                        guard visited.insert(offset).inserted, let sub = entries(at: offset) else { continue }
                        let subName = subIFDCount == 0 ? "SubIFD" : "SubIFD\(subIFDCount)"
                        subIFDCount += 1
                        walk(ifd: offset, entries: sub, name: subName)
                    }
                case Tag.exifIFD:
                    if let offset = values(e).first, visited.insert(offset).inserted, let exif = entries(at: offset) {
                        walkExif(exif)
                    }
                default:
                    break
                }
            }
        }

        mutating func walkExif(_ es: [Entry]) {
            if let cs = es.first(where: { $0.tag == Tag.colorSpace }), let v = values(cs).first {
                info.exifColorSpace = UInt16(v)
            }
            if let ie = es.first(where: { $0.tag == Tag.interopIFD }), let offset = values(ie).first,
               let interop = entries(at: offset),
               let idx = interop.first(where: { $0.tag == Tag.interopIndex }) {
                info.interopIndex = string(idx)
            }
        }

        mutating func classify(_ es: [Entry], name: String, first: (UInt16) -> Int?, reading: Walker) {
            let compression = first(Tag.compression)
            let photometric = first(Tag.photometric)
            let subfileType = first(Tag.newSubfileType) ?? 0
            let tiled = es.contains { $0.tag == Tag.tileWidth }
            let orientation = first(Tag.orientation).map { UInt16($0) }

            // Photometric 32803 is CFA and 34892 Linear Raw: those carry raw samples even when
            // the strips or tiles are JPEG-compressed (lossless JPEG in DNG). 52527 is a
            // semantic mask (Apple's portrait mattes), not a picture.
            if let photometric, [32803, 34892, 52527].contains(photometric) {
                let what = photometric == 52527 ? "semantic mask" : "raw samples"
                if first(Tag.jpegInterchangeFormat) != nil || compression != nil {
                    skipped.append(SkippedImage(location: name, reason: what))
                }
                return
            }
            if subfileType & 0x4 != 0 {
                skipped.append(SkippedImage(location: name, reason: "mask subfile"))
                return
            }

            var offset: Int?
            var length: Int?
            if let blob = es.first(where: { $0.tag == Tag.panasonicJpgFromRaw && $0.type == 7 && $0.count > 4 }),
               let o = reading.reader.u32(blob.valueOffset) {
                // RW2 keeps its JPEG as an undefined-type blob in IFD0: count is the length, the value the offset.
                offset = Int(o); length = blob.count
            } else if let o = first(Tag.jpegInterchangeFormat), let l = first(Tag.jpegInterchangeFormatLength) {
                offset = o; length = l
            } else if let compression {
                switch compression {
                case 6, 7, 34892:
                    guard !tiled else { skipped.append(SkippedImage(location: name, reason: "tiled JPEG (raw data)")); return }
                    let offs = es.first { $0.tag == Tag.stripOffsets }.map(values) ?? []
                    let lens = es.first { $0.tag == Tag.stripByteCounts }.map(values) ?? []
                    if offs.count == 1, lens.count == 1 { offset = offs[0]; length = lens[0] }
                    else if !offs.isEmpty { skipped.append(SkippedImage(location: name, reason: "multi-strip JPEG")) }
                case 52546:
                    skipped.append(SkippedImage(location: name, reason: "JPEG XL"))
                case 1:
                    skipped.append(SkippedImage(location: name, reason: "uncompressed pixels"))
                default:
                    break
                }
            }
            guard let offset, let length, length > 4, offset >= 0, offset + length <= reader.count else { return }
            guard let header = JPEGHeader.parse(reader, at: offset) else {
                skipped.append(SkippedImage(location: name, reason: "not a JPEG at offset \(offset)"))
                return
            }
            if header.isLossless {
                skipped.append(SkippedImage(location: name, reason: "lossless JPEG (raw data)"))
                return
            }
            previews.append(EmbeddedJPEG(location: name, offset: offset, length: length,
                                         width: header.width, height: header.height,
                                         containerOrientation: orientation, header: header))
        }
    }

    public static func locate(in data: Data) -> LocatedPreviews? {
        var reader = ByteReader(data: data)
        switch reader.u16(0) {
        case 0x4949: reader.order = .little
        case 0x4D4D: reader.order = .big
        default: return nil
        }
        // 42 is TIFF; 0x4F52/0x5352 are Olympus ORF; 0x55 is Panasonic RW2.
        guard let magic = reader.u16(2), [42, 0x4F52, 0x5352, 0x55].contains(magic),
              let first = reader.u32(4) else { return nil }
        var walker = Walker(reader: reader)
        walker.walkChain(from: Int(first)) { "IFD\($0)" }
        return LocatedPreviews(format: "TIFF", info: walker.info, previews: walker.previews, skipped: walker.skipped)
    }
}
