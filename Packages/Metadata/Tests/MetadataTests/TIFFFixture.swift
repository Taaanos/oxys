import Foundation

/// Builds small TIFF-structured files for the maker-note tests: IFDs with entries, values placed after each IFD,
/// offsets counted from a base the caller picks (a maker note may count from its own start).
struct TIFFFixture {
    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: Int
        var data: [UInt8]
    }

    var bigEndian = false

    func u16(_ v: Int) -> [UInt8] {
        let b = [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
        return bigEndian ? b.reversed() : b
    }

    func u32(_ v: Int) -> [UInt8] {
        let b = (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) }
        return bigEndian ? b.reversed() : b
    }

    func shorts(_ tag: UInt16, _ values: [Int], signed: Bool = false) -> Entry {
        Entry(tag: tag, type: signed ? 8 : 3, count: values.count, data: values.flatMap(u16))
    }

    func longs(_ tag: UInt16, _ values: [Int]) -> Entry {
        Entry(tag: tag, type: 4, count: values.count, data: values.flatMap(u32))
    }

    func ascii(_ tag: UInt16, _ text: String) -> Entry {
        Entry(tag: tag, type: 2, count: text.utf8.count + 1, data: Array(text.utf8) + [0])
    }

    func rationals(_ tag: UInt16, _ values: [(Int, Int)]) -> Entry {
        Entry(tag: tag, type: 5, count: values.count, data: values.flatMap { u32($0.0) + u32($0.1) })
    }

    func blob(_ tag: UInt16, _ bytes: [UInt8]) -> Entry {
        Entry(tag: tag, type: 7, count: bytes.count, data: bytes)
    }

    /// One IFD at file position `origin`, offsets counted from `base`. `blobs` says where each large value landed.
    func ifd(_ entries: [Entry], origin: Int, base: Int) -> (bytes: [UInt8], blobs: [UInt16: Int]) {
        let sorted = entries.sorted { $0.tag < $1.tag }
        var head = u16(sorted.count)
        var tail: [UInt8] = []
        var blobs: [UInt16: Int] = [:]
        let dataStart = 2 + sorted.count * 12 + 4
        for e in sorted {
            head += u16(Int(e.tag)) + u16(Int(e.type)) + u32(e.count)
            if e.data.count <= 4 {
                head += e.data + [UInt8](repeating: 0, count: 4 - e.data.count)
            } else {
                let position = origin + dataStart + tail.count
                head += u32(position - base)
                blobs[e.tag] = position
                tail += e.data
                if tail.count % 2 == 1 { tail.append(0) }
            }
        }
        head += u32(0)
        return (head + tail, blobs)
    }

    var header: [UInt8] { (bigEndian ? Array("MM".utf8) : Array("II".utf8)) + u16(42) + u32(8) }

    /// A whole TIFF file: IFD0 with `make` and `orientation`, an Exif IFD with `exif` entries, and a maker note placed by
    /// `note`, which gets the position its bytes will have and returns them. `ifd0Extra` adds entries to IFD0.
    func file(make: String, orientation: Int = 1, exif: [Entry] = [], ifd0Extra: [Entry] = [],
              noteTag: UInt16 = 0x927C, note: ((_ position: Int) -> [UInt8])?) -> Data {
        let probeNote = note?(0) ?? []
        func ifd0(exifAt: Int) -> [Entry] {
            [ascii(0x010F, make), shorts(0x0112, [orientation]), longs(0x8769, [exifAt])] + ifd0Extra
        }
        let ifd0Size = ifd(ifd0(exifAt: 0), origin: 8, base: 0).bytes.count
        let exifOrigin = 8 + ifd0Size
        var exifEntries = exif
        if note != nil { exifEntries.append(blob(noteTag, probeNote)) }
        let position = ifd(exifEntries, origin: exifOrigin, base: 0).blobs[noteTag] ?? 0
        if let note {
            exifEntries.removeAll { $0.tag == noteTag }
            exifEntries.append(blob(noteTag, note(position)))
        }
        return Data(header + ifd(ifd0(exifAt: exifOrigin), origin: 8, base: 0).bytes + ifd(exifEntries, origin: exifOrigin, base: 0).bytes)
    }
}
