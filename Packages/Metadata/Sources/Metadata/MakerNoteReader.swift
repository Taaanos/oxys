import Containers
import Foundation

/// Reads the lens name and the AF point from a camera's maker note (V-01). Sony, Canon, Nikon and Fujifilm; any
/// other brand, and bodies whose layout is not read, give a result without AF points. The tag layouts are written
/// from the formats' public documentation, one decoder per brand, and every read is bounds-checked.
///
/// Where each brand keeps it: ARW, CR2, NEF and DNG have the maker note in the Exif IFD (tag 0x927C); CR3 keeps it as
/// a small TIFF in its own `CMT3` box; RAF has it in the Exif of its embedded JPEG.
public enum MakerNoteReader {
    private enum Tag {
        static let make: UInt16 = 0x010F
        static let orientation: UInt16 = 0x0112
        static let dngPrivateData: UInt16 = 0xC634
        static let exifIFD: UInt16 = 0x8769
        static let makerNote: UInt16 = 0x927C
        static let exifWidth: UInt16 = 0xA002
        static let exifHeight: UInt16 = 0xA003
        static let lensInfo: UInt16 = 0xA432
        static let lensModel: UInt16 = 0xA434
    }

    public static func read(from url: URL) -> MakerNoteInfo? {
        guard let data = try? FileBytes.load(url) else { return nil }
        return read(from: data)
    }

    public static func read(from data: Data) -> MakerNoteInfo? {
        if let ifd0 = TIFFDirectory.firstDirectory(in: data, at: 0) { return decode(ifd0: ifd0) }
        let reader = ByteReader(data: data)
        if reader.bytes(0, 16) == Data("FUJIFILMCCD-RAW ".utf8) { return readRAF(reader, data: data) }
        if reader.bytes(4, 4) == Data("ftyp".utf8), reader.bytes(8, 4) == Data("crx ".utf8) { return readCR3(reader, data: data) }
        return nil
    }

    // MARK: containers

    /// RAF: the embedded JPEG's Exif carries the maker note.
    private static func readRAF(_ reader: ByteReader, data: Data) -> MakerNoteInfo? {
        guard let jpeg = reader.u32(0x54).map(Int.init), reader.u16(jpeg) == 0xFFD8 else { return nil }
        var position = jpeg + 2
        for _ in 0..<64 {
            guard reader.u8(position) == 0xFF, let marker = reader.u8(position + 1), let length = reader.u16(position + 2) else { return nil }
            if marker == 0xE1, reader.bytes(position + 4, 6) == Data("Exif\0\0".utf8) {
                guard let ifd0 = TIFFDirectory.firstDirectory(in: data, at: position + 10) else { return nil }
                return decode(ifd0: ifd0)
            }
            if marker == 0xDA { return nil }
            position += 2 + Int(length)
        }
        return nil
    }

    /// CR3: `CMT1` is IFD0, `CMT2` the Exif IFD and `CMT3` the Canon maker note, each a small TIFF.
    private static func readCR3(_ reader: ByteReader, data: Data) -> MakerNoteInfo? {
        var cmt: [String: Int] = [:]
        func visit(_ range: Range<Int>, depth: Int) {
            var pos = range.lowerBound
            while pos + 8 <= range.upperBound {
                guard let size32 = reader.u32(pos), let name = reader.bytes(pos + 4, 4) else { break }
                var size = Int(size32)
                var payload = pos + 8
                if size == 1 {
                    guard let big = reader.u64(pos + 8) else { break }
                    size = Int(clamping: big); payload = pos + 16
                } else if size == 0 {
                    size = range.upperBound - pos
                }
                let (end, overflowed) = pos.addingReportingOverflow(size)
                guard size >= payload - pos, !overflowed, end <= range.upperBound else { break }
                let type = String(decoding: name, as: UTF8.self)
                switch type {
                case "moov": if depth < 4 { visit(payload..<end, depth: depth + 1) }
                case "uuid":
                    // Canon's metadata box: a 16-byte id, then the CMT boxes.
                    if depth < 4, reader.bytes(payload, 4) == Data([0x85, 0xC0, 0xB6, 0x87]) { visit((payload + 16)..<end, depth: depth + 1) }
                case "CMT1", "CMT2", "CMT3": cmt[type] = payload
                default: break
                }
                pos = end
            }
        }
        visit(0..<reader.count, depth: 0)
        guard let one = cmt["CMT1"], let ifd0 = TIFFDirectory.firstDirectory(in: data, at: one) else { return nil }
        let exif = cmt["CMT2"].flatMap { TIFFDirectory.firstDirectory(in: data, at: $0) }
        let canon = cmt["CMT3"].flatMap { TIFFDirectory.firstDirectory(in: data, at: $0) }
        return decode(ifd0: ifd0, exif: exif, makerNote: canon)
    }

    // MARK: one file

    private static func decode(ifd0: TIFFDirectory, exif exifOverride: TIFFDirectory? = nil, makerNote noteOverride: TIFFDirectory? = nil) -> MakerNoteInfo? {
        var info = MakerNoteInfo()
        if let o = ifd0.integers(Tag.orientation).first, (1...8).contains(o) { info.orientation = o }
        let exif = exifOverride ?? ifd0.integers(Tag.exifIFD).first.flatMap {
            TIFFDirectory(reader: ifd0.reader, at: ifd0.base + $0, base: ifd0.base)
        }
        info.lens = exif?.string(Tag.lensModel) ?? exif.flatMap { lens(from: $0.rationals(Tag.lensInfo, limit: 4)) }

        let make = (ifd0.string(Tag.make) ?? "").uppercased()
        let note = noteOverride ?? locateNote(make: make, exif: exif, ifd0: ifd0)
        guard let note else { return info }
        if make.contains("SONY") {
            decodeSony(note, into: &info)
        } else if make.contains("CANON") {
            decodeCanon(note, into: &info)
        } else if make.contains("NIKON") {
            decodeNikon(note, into: &info)
        } else if make.contains("FUJIFILM") {
            decodeFuji(note, exif: exif, into: &info)
        }
        return info
    }

    /// The maker note in the Exif IFD, or, in a DNG, the copy Adobe keeps in DNGPrivateData.
    private static func locateNote(make: String, exif: TIFFDirectory?, ifd0: TIFFDirectory) -> TIFFDirectory? {
        if let exif, let e = exif.entry(Tag.makerNote), let start = exif.valuePosition(e) {
            return makerNoteDirectory(make: make, reader: exif.reader, start: start, base: exif.base)
        }
        // "Adobe\0", then blocks of a 4-letter name, a big-endian length and the data. "MakN" holds the note's byte order,
        // the offset it had in the original file (always big-endian), and the note. Its offsets still count from the original file.
        guard let e = ifd0.entry(Tag.dngPrivateData), let start = ifd0.valuePosition(e), e.count > 14,
              ifd0.reader.bytes(start, 6) == Data("Adobe\0".utf8) else { return nil }
        let end = start + min(e.count, 1 << 24)
        var pos = start + 6
        var big = ifd0.reader
        big.order = .big
        while pos + 8 <= end, let name = big.bytes(pos, 4), let length = big.u32(pos + 4).map(Int.init) {
            let payload = pos + 8
            if name == Data("MakN".utf8), length > 6, payload + length <= end {
                var reader = ifd0.reader
                switch reader.u16(payload) {
                case 0x4949: reader.order = .little
                case 0x4D4D: reader.order = .big
                default: return nil
                }
                guard let original = big.u32(payload + 2).map(Int.init) else { return nil }
                return makerNoteDirectory(make: make, reader: reader, start: payload + 6, base: payload + 6 - original)
            }
            pos = payload + length
        }
        return nil
    }

    /// Where the maker note's IFD is, given the brand's header (or none) in front of it.
    private static func makerNoteDirectory(make: String, reader: ByteReader, start: Int, base: Int) -> TIFFDirectory? {
        if make.contains("SONY") {
            let header = reader.bytes(start, 4) == Data("SONY".utf8) ? 12 : 0
            return TIFFDirectory(reader: reader, at: start + header, base: base)
        }
        if make.contains("CANON") {
            return TIFFDirectory(reader: reader, at: start, base: base)
        }
        if make.contains("NIKON") {
            guard reader.bytes(start, 6) == Data("Nikon\0".utf8), let version = reader.u8(start + 6) else { return nil }
            if version == 2 {
                // Type 3: an embedded TIFF header 10 bytes in; offsets count from it.
                return TIFFDirectory.firstDirectory(in: reader.data, at: start + 10)
            }
            return TIFFDirectory(reader: reader, at: start + 8, base: base)
        }
        if make.contains("FUJIFILM") {
            // "FUJIFILM", then the IFD's offset from the note's start. Always little-endian.
            var little = reader
            little.order = .little
            guard little.bytes(start, 8) == Data("FUJIFILM".utf8), let offset = little.u32(start + 8) else { return nil }
            return TIFFDirectory(reader: little, at: start + Int(offset), base: start)
        }
        return nil
    }

    // MARK: Sony

    /// 0x2027 FocusLocation: the frame's width and height, then the focus point in that frame.
    private static func decodeSony(_ note: TIFFDirectory, into info: inout MakerNoteInfo) {
        let v = note.integers(0x2027, limit: 4)
        guard v.count == 4, v[0] > 0, v[1] > 0, v[2] >= 0, v[3] >= 0, v[2] <= v[0], v[3] <= v[1] else { return }
        info.afFrameWidth = v[0]
        info.afFrameHeight = v[1]
        info.afPoints = [AFPoint(x: Double(v[2]) / Double(v[0]), y: Double(v[3]) / Double(v[1]))]
    }

    // MARK: Canon

    private static let canonAreaModes: [Int: String] = [
        0: "Off (manual focus)", 1: "AF point expansion (surround)", 2: "Single-point AF", 4: "Auto", 5: "Face detect AF",
        6: "Face + tracking", 7: "Zone AF", 8: "AF point expansion (4 point)", 9: "Spot AF",
        10: "AF point expansion (8 point)", 11: "Flexizone multi", 12: "Flexizone single", 13: "Large zone AF",
    ]

    /// 0x0095 is the lens name. 0x0026 (AFInfo2) is an array of 16-bit values: size, area mode, point count, valid
    /// count, two image sizes, the AF image size, then widths, heights, x and y of every point (x and y from the
    /// middle of the AF image, y up), then bit masks of the points in focus and selected.
    private static func decodeCanon(_ note: TIFFDirectory, into info: inout MakerNoteInfo) {
        if info.lens == nil { info.lens = note.string(0x0095) }
        let a = note.integers(0x0026)
        guard a.count > 8 else { return }
        let n = a[2], valid = a[3]
        let frameW = a[6], frameH = a[7]
        guard n > 0, n <= 256, valid > 0, valid <= n, frameW > 0, frameH > 0 else { return }
        let words = (n + 15) / 16
        guard a.count >= 8 + 4 * n + 2 * words else { return }
        info.afMode = canonAreaModes[a[1]]
        func signed(_ v: Int) -> Int { Int(Int16(truncatingIfNeeded: v)) }
        func bits(from start: Int) -> [Int] {
            (0..<n).filter { a[start + $0 / 16] >> ($0 % 16) & 1 == 1 }
        }
        let inFocus = bits(from: 8 + 4 * n)
        let chosen = inFocus.isEmpty ? bits(from: 8 + 4 * n + words) : inFocus
        info.afFrameWidth = frameW
        info.afFrameHeight = frameH
        info.afPoints = chosen.compactMap { i in
            guard i < valid else { return nil }
            let w = Double(a[8 + i]), h = Double(a[8 + n + i])
            let x = Double(signed(a[8 + 2 * n + i])), y = Double(signed(a[8 + 3 * n + i]))
            return AFPoint(x: 0.5 + x / Double(frameW), y: 0.5 - y / Double(frameH),
                           width: w / Double(frameW), height: h / Double(frameH))
        }
    }

    // MARK: Nikon

    /// 0x0084 is the lens as four rationals. 0x00B7 (AFInfo2) in version 01xx: the AF image size and the area's
    /// middle, width and height at fixed offsets. Version 03xx (Z cameras) is not read.
    private static func decodeNikon(_ note: TIFFDirectory, into info: inout MakerNoteInfo) {
        if info.lens == nil { info.lens = lens(from: note.rationals(0x0084, limit: 4)) }
        guard let af = note.bytes(0x00B7), af.count >= 0x1C, af.prefix(2) == Data("01".utf8) else { return }
        let r = ByteReader(data: af, order: note.reader.order)
        guard let w = r.u16(0x10).map(Int.init), let h = r.u16(0x12).map(Int.init),
              let x = r.u16(0x14).map(Int.init), let y = r.u16(0x16).map(Int.init),
              let aw = r.u16(0x18).map(Int.init), let ah = r.u16(0x1A).map(Int.init),
              w > 0, h > 0, x <= w, y <= h, x > 0 || y > 0 else { return }
        info.afFrameWidth = w
        info.afFrameHeight = h
        info.afPoints = [AFPoint(x: Double(x) / Double(w), y: Double(y) / Double(h), width: Double(aw) / Double(w), height: Double(ah) / Double(h))]
    }

    // MARK: Fujifilm

    /// 0x1023 FocusPixel: x and y in the pixels of the Exif image size.
    private static func decodeFuji(_ note: TIFFDirectory, exif: TIFFDirectory?, into info: inout MakerNoteInfo) {
        let v = note.integers(0x1023, limit: 2)
        guard v.count == 2, let exif,
              let w = exif.integers(Tag.exifWidth, limit: 1).first, let h = exif.integers(Tag.exifHeight, limit: 1).first,
              w > 0, h > 0, v[0] >= 0, v[1] >= 0, v[0] <= w, v[1] <= h else { return }
        info.afFrameWidth = w
        info.afFrameHeight = h
        info.afPoints = [AFPoint(x: Double(v[0]) / Double(w), y: Double(v[1]) / Double(h))]
    }

    // MARK: lens text

    /// "24-70mm f/2.8" from EXIF LensInfo: shortest and longest focal length, then the apertures at both ends.
    static func lens(from info: [Double]) -> String? {
        guard info.count == 4, info[0].isFinite, info[0] > 0, info[1].isFinite, info[1] >= info[0] else { return nil }
        func num(_ v: Double) -> String {
            let one = (v * 10).rounded() / 10
            return one == one.rounded() ? String(Int(one)) : String(one)
        }
        var text = info[0] == info[1] ? "\(num(info[0]))mm" : "\(num(info[0]))-\(num(info[1]))mm"
        if info[2].isFinite, info[2] > 0 {
            let wide = info[2], tele = info[3].isFinite && info[3] > 0 ? info[3] : info[2]
            text += wide == tele ? " f/\(num(wide))" : " f/\(num(wide))-\(num(tele))"
        }
        return text
    }
}
