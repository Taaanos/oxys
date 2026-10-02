import Foundation
import Testing
@testable import Metadata

/// Maker-note reading (V-01) on small built files. The corpus check against a reference extractor is `ExifCheck`
/// with PREVIEW_ORACLE; these tests need no camera files.
@Suite struct MakerNoteTests {
    let le = TIFFFixture()
    let be = TIFFFixture(bigEndian: true)

    // MARK: Sony

    private func sonyFile(orientation: Int = 1, location: [Int] = [7008, 4672, 3810, 2423], header: Bool = true) -> Data {
        le.file(make: "SONY", orientation: orientation, exif: [le.ascii(0xA434, "Viltrox 20mm F2.8 FE")]) { position in
            let prefix: [UInt8] = header ? Array("SONY DSC ".utf8) + [0, 0, 0] : []
            return prefix + le.ifd([le.shorts(0x2027, location)], origin: position + prefix.count, base: 0).bytes
        }
    }

    @Test func sonyFocusLocationBecomesAFraction() throws {
        let info = try #require(MakerNoteReader.read(from: sonyFile()))
        let p = try #require(info.afPoints.first)
        #expect(abs(p.x - 3810.0 / 7008) < 1e-9 && abs(p.y - 2423.0 / 4672) < 1e-9)
        #expect(info.afFrameWidth == 7008 && info.afFrameHeight == 4672)
        #expect(info.lens == "Viltrox 20mm F2.8 FE")
    }

    @Test func sonyNoteWithoutItsHeaderIsRead() throws {
        let info = try #require(MakerNoteReader.read(from: sonyFile(header: false)))
        #expect(info.afPoints.count == 1)
    }

    @Test func sonyZeroSizedFrameGivesNoPoint() throws {
        let info = try #require(MakerNoteReader.read(from: sonyFile(location: [0, 0, 0, 0])))
        #expect(info.afPoints.isEmpty)
        #expect(info.focusAnchor == nil)
    }

    @Test func sonyPointOutsideTheFrameIsRejected() throws {
        let info = try #require(MakerNoteReader.read(from: sonyFile(location: [100, 100, 500, 50])))
        #expect(info.afPoints.isEmpty)
    }

    @Test func theAnchorIsInTheUprightPicture() throws {
        // Orientation 8 (rotate 270 CW): the sensor's right edge is the picture's top.
        let info = try #require(MakerNoteReader.read(from: sonyFile(orientation: 8)))
        let anchor = try #require(info.focusAnchor)
        #expect(abs(anchor.x - 2423.0 / 4672) < 1e-9)
        #expect(abs(anchor.y - (1 - 3810.0 / 7008)) < 1e-9)
    }

    @Test(arguments: [
        (1, 0.25, 0.1), (2, 0.75, 0.1), (3, 0.75, 0.9), (4, 0.25, 0.9),
        (5, 0.1, 0.25), (6, 0.9, 0.25), (7, 0.9, 0.75), (8, 0.1, 0.75),
    ])
    func everyOrientationMapsTheSensorPointUpright(orientation: Int, x: Double, y: Double) {
        let p = AFPoint(x: 0.25, y: 0.1).upright(orientation: orientation)
        #expect(abs(p.x - x) < 1e-9 && abs(p.y - y) < 1e-9)
    }

    @Test func rotatedOrientationsSwapTheAreaSize() {
        let p = AFPoint(x: 0.5, y: 0.5, width: 0.1, height: 0.2).upright(orientation: 6)
        #expect(p.width == 0.2 && p.height == 0.1)
    }

    // MARK: Canon

    /// A 19-point body like the EOS 7D: points in a grid, the one at bit `inFocus` selected.
    private func canonAFInfo2(inFocus: Int, mode: Int = 9) -> [Int] {
        let n = 19
        let xs = [-1373, -881, -881, -881, -393, -393, -393, 0, 0, 0, 0, 0, 393, 393, 393, 881, 881, 881, 1373]
        let ys = [0, 393, 0, -393, 393, 0, -393, 743, 393, 0, -393, -743, 393, 0, -393, 393, 0, -393, 0]
        func u16(_ v: Int) -> Int { v & 0xFFFF }
        var a = [0, mode, n, n, 5184, 3456, 5184, 3456]
        a += [Int](repeating: 222, count: n) + [Int](repeating: 266, count: n) + xs.map(u16) + ys.map(u16)
        let mask = [1 << (inFocus % 16), 0]
        a += inFocus < 16 ? mask : [0, 1 << (inFocus % 16)]
        a += mask + [0, 0]
        a[0] = a.count * 2
        return a
    }

    private func canonFile(afInfo: [Int], lens: String? = nil, orientation: Int = 1, exifLens: String? = "EF-S15-85mm f/3.5-5.6 IS USM") -> Data {
        le.file(make: "Canon", orientation: orientation, exif: exifLens.map { [le.ascii(0xA434, $0)] } ?? []) { position in
            var entries = [le.shorts(0x0026, afInfo)]
            if let lens { entries.append(le.ascii(0x0095, lens)) }
            return le.ifd(entries, origin: position, base: 0).bytes
        }
    }

    @Test func canonAFInfo2GivesThePointInFocus() throws {
        let info = try #require(MakerNoteReader.read(from: canonFile(afInfo: canonAFInfo2(inFocus: 10))))
        let p = try #require(info.afPoints.first)
        #expect(info.afPoints.count == 1)
        // Bit 10 is 393 units below the middle of a 3456 high AF image (y counts up).
        #expect(abs(p.x - 0.5) < 1e-9 && abs(p.y - (0.5 + 393.0 / 3456)) < 1e-9)
        #expect(abs((p.width ?? 0) - 222.0 / 5184) < 1e-9)
        #expect(info.afMode == "Spot AF")
    }

    @Test func canonPointSelectedButNotInFocusStillCounts() throws {
        var a = canonAFInfo2(inFocus: 3)
        let words = 2, n = 19
        a[8 + 4 * n] = 0   // nothing in focus; the selected mask keeps its bit
        a[8 + 4 * n + words] = 1 << 3
        let info = try #require(MakerNoteReader.read(from: canonFile(afInfo: a)))
        let p = try #require(info.afPoints.first)
        #expect(abs(p.x - (0.5 - 881.0 / 5184)) < 1e-9 && abs(p.y - (0.5 + 393.0 / 3456)) < 1e-9)
    }

    @Test func canonPointsInTheSecondMaskWordAreFound() throws {
        let info = try #require(MakerNoteReader.read(from: canonFile(afInfo: canonAFInfo2(inFocus: 17))))
        let p = try #require(info.afPoints.first)
        #expect(abs(p.x - (0.5 + 881.0 / 5184)) < 1e-9)
    }

    @Test func canonLensNameFallsBackToTheMakerNote() throws {
        let info = try #require(MakerNoteReader.read(from: canonFile(afInfo: canonAFInfo2(inFocus: 9), lens: "EF 50mm f/1.8 II", exifLens: nil)))
        #expect(info.lens == "EF 50mm f/1.8 II")
    }

    @Test func canonTruncatedAFInfoGivesNoPoints() throws {
        let info = try #require(MakerNoteReader.read(from: canonFile(afInfo: Array(canonAFInfo2(inFocus: 9).prefix(30)))))
        #expect(info.afPoints.isEmpty)
    }

    // MARK: Nikon

    /// A type 3 Nikon note: "Nikon\0", version, two pad bytes, then a TIFF header that its offsets count from.
    private func nikonFile(afInfo: [UInt8]?, lens: Bool = true) -> Data {
        be.file(make: "NIKON CORPORATION", orientation: 1) { position in
            let start = position + 10
            var entries: [TIFFFixture.Entry] = []
            if lens { entries.append(be.rationals(0x0084, [(240, 10), (700, 10), (28, 10), (28, 10)])) }
            if let afInfo { entries.append(be.blob(0x00B7, afInfo)) }
            let note = be.ifd(entries, origin: start + 8, base: start).bytes
            return Array("Nikon\0".utf8) + [2, 0x10, 0, 0] + be.header + note
        }
    }

    private func nikonAF(version: String = "0101", frame: (Int, Int) = (6016, 4016), x: Int = 3008, y: Int = 1000, area: (Int, Int) = (200, 150)) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 0x20)
        b.replaceSubrange(0..<4, with: Array(version.utf8))
        for (offset, value) in [(0x10, frame.0), (0x12, frame.1), (0x14, x), (0x16, y), (0x18, area.0), (0x1A, area.1)] {
            b.replaceSubrange(offset..<offset + 2, with: be.u16(value))
        }
        return b
    }

    @Test func nikonAFInfo2GivesThePointAndTheArea() throws {
        let info = try #require(MakerNoteReader.read(from: nikonFile(afInfo: nikonAF())))
        let p = try #require(info.afPoints.first)
        #expect(abs(p.x - 3008.0 / 6016) < 1e-9 && abs(p.y - 1000.0 / 4016) < 1e-9)
        #expect(abs((p.width ?? 0) - 200.0 / 6016) < 1e-9)
    }

    @Test func nikonLensComesFromTheMakerNoteWhenExifHasNone() throws {
        let info = try #require(MakerNoteReader.read(from: nikonFile(afInfo: nil)))
        #expect(info.lens == "24-70mm f/2.8")
        #expect(info.afPoints.isEmpty)
    }

    @Test func nikonVersionsThatAreNotReadGiveNoPoint() throws {
        let info = try #require(MakerNoteReader.read(from: nikonFile(afInfo: nikonAF(version: "0300"))))
        #expect(info.afPoints.isEmpty)
    }

    @Test func nikonPointOutsideTheFrameIsRejected() throws {
        let info = try #require(MakerNoteReader.read(from: nikonFile(afInfo: nikonAF(x: 9000))))
        #expect(info.afPoints.isEmpty)
    }

    // MARK: Fujifilm

    private func fujiTIFF(focus: [Int]) -> [UInt8] {
        // The note's IFD sits 12 bytes in; its offsets count from the start of the note.
        let exif = [le.longs(0xA002, [1920]), le.longs(0xA003, [1280])]
        return Array(le.file(make: "FUJIFILM", exif: exif) { position in
            Array("FUJIFILM".utf8) + le.u32(12) + le.ifd([le.shorts(0x1023, focus)], origin: position + 12, base: position).bytes
        })
    }

    @Test func fujiTIFFFocusPixelUsesTheExifImageSize() throws {
        let info = try #require(MakerNoteReader.read(from: Data(fujiTIFF(focus: [480, 320]))))
        let p = try #require(info.afPoints.first)
        #expect(abs(p.x - 0.25) < 1e-9 && abs(p.y - 0.25) < 1e-9)
    }

    @Test func rafKeepsItsExifInsideTheEmbeddedJPEG() throws {
        let tiff = fujiTIFF(focus: [960, 640])
        let segment = Array("Exif\0\0".utf8) + tiff
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1] + [UInt8((segment.count + 2) >> 8), UInt8((segment.count + 2) & 0xFF)] + segment + [0xFF, 0xD9]
        var raf = Array("FUJIFILMCCD-RAW ".utf8) + [UInt8](repeating: 0, count: 0x100 - 16)
        raf.replaceSubrange(0x54..<0x58, with: [0, 0, 1, 0])
        raf.replaceSubrange(0x58..<0x5C, with: [0, 0, UInt8(jpeg.count >> 8), UInt8(jpeg.count & 0xFF)])
        let info = try #require(MakerNoteReader.read(from: Data(raf + jpeg)))
        let p = try #require(info.afPoints.first)
        #expect(abs(p.x - 0.5) < 1e-9 && abs(p.y - 0.5) < 1e-9)
    }

    // MARK: containers

    @Test func cr3KeepsItsNoteInTheCMT3Box() throws {
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let size = payload.count + 8
            return [0, 0, UInt8(size >> 8), UInt8(size & 0xFF)] + Array(type.utf8) + payload
        }
        let cmt1 = Array(le.file(make: "Canon", orientation: 6, note: nil))
        let cmt2 = le.header + le.ifd([le.ascii(0xA434, "RF24-105mm F4 L IS USM")], origin: 8, base: 0).bytes
        let cmt3 = le.header + le.ifd([le.shorts(0x0026, canonAFInfo2(inFocus: 9))], origin: 8, base: 0).bytes
        let canonID: [UInt8] = [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48]
        let moov = box("moov", box("uuid", canonID + box("CMT1", cmt1) + box("CMT2", cmt2) + box("CMT3", cmt3)))
        let ftyp = box("ftyp", Array("crx ".utf8) + [0, 0, 0, 1] + Array("crx isom".utf8))
        let info = try #require(MakerNoteReader.read(from: Data(ftyp + moov)))
        #expect(info.lens == "RF24-105mm F4 L IS USM")
        #expect(info.orientation == 6)
        let p = try #require(info.afPoints.first)
        #expect(abs(p.x - 0.5) < 1e-9 && abs(p.y - 0.5) < 1e-9)
    }

    @Test func dngKeepsTheNoteInAdobeMakerNoteData() throws {
        // "Adobe\0MakN", a big-endian length, the note's byte order and its offset in the original file (big-endian),
        // then the note, whose offsets still count from the original file.
        let originalOffset = 0x13F8
        let note = le.ifd([le.shorts(0x2027, [7008, 4672, 3504, 2336])], origin: originalOffset, base: 0).bytes
        let payload = Array("II".utf8) + [0, 0, 0x13, 0xF8] + note
        let private_ = Array("Adobe\0MakN".utf8) + [0, 0, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
        let data = le.file(make: "SONY", orientation: 1, ifd0Extra: [le.blob(0xC634, private_)], note: nil)
        let info = try #require(MakerNoteReader.read(from: data))
        let p = try #require(info.afPoints.first)
        #expect(abs(p.x - 0.5) < 1e-9 && abs(p.y - 0.5) < 1e-9)
    }

    @Test func otherBrandsStillGiveTheLens() throws {
        let data = le.file(make: "Panasonic", exif: [le.ascii(0xA434, "LEICA DG 12-60mm")], note: nil)
        let info = try #require(MakerNoteReader.read(from: data))
        #expect(info.lens == "LEICA DG 12-60mm")
        #expect(info.focusAnchor == nil)
        #expect(info.afFields.last == ExifInfo.Field("AF point", "AF data not available"))
    }

    @Test func lensInfoIsUsedWhenThereIsNoLensName() throws {
        let data = le.file(make: "Panasonic", exif: [le.rationals(0xA432, [(94, 10), (257, 10), (18, 10), (28, 10)])], note: nil)
        #expect(try #require(MakerNoteReader.read(from: data)).lens == "9.4-25.7mm f/1.8-2.8")
    }

    @Test func lensTextFromFocalLengthsAndApertures() {
        #expect(MakerNoteReader.lens(from: [20, 20, 2.8, 2.8]) == "20mm f/2.8")
        #expect(MakerNoteReader.lens(from: [24, 70, 2.8, 2.8]) == "24-70mm f/2.8")
        #expect(MakerNoteReader.lens(from: [70, 200, 4, 5.6]) == "70-200mm f/4-5.6")
        #expect(MakerNoteReader.lens(from: [50, 50, 0, 0]) == "50mm")
        #expect(MakerNoteReader.lens(from: [0, 0, 0, 0]) == nil)
        #expect(MakerNoteReader.lens(from: [70, 24, 2.8, 2.8]) == nil)
        #expect(MakerNoteReader.lens(from: [.nan, 70, 2.8, 2.8]) == nil)
    }

    // MARK: display

    @Test func inspectorRowsShowTheModeAndThePoint() throws {
        let info = try #require(MakerNoteReader.read(from: canonFile(afInfo: canonAFInfo2(inFocus: 9))))
        #expect(info.afFields.map(\.label) == ["AF mode", "AF point"])
        #expect(info.afFields.last?.value == "50%, 50% from the top left (2592, 1728 in 5184 × 3456)")
    }

    // MARK: hostile files

    @Test func damagedFilesNeverTrap() {
        let seeds = [sonyFile(), canonFile(afInfo: canonAFInfo2(inFocus: 10)), nikonFile(afInfo: nikonAF()), Data(fujiTIFF(focus: [1, 1]))]
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        for seed in seeds {
            for _ in 0..<400 {
                var bytes = Array(seed)
                for _ in 0..<(1 + next() % 6) { bytes[next() % bytes.count] = UInt8(truncatingIfNeeded: next()) }
                if next() % 4 == 0 { bytes.removeLast(next() % bytes.count) }
                _ = MakerNoteReader.read(from: Data(bytes))
            }
        }
        for length in 0..<64 { _ = MakerNoteReader.read(from: Data(repeating: 0xFF, count: length)) }
    }

    @Test func notAnImageGivesNil() {
        #expect(MakerNoteReader.read(from: Data("hello".utf8)) == nil)
        #expect(MakerNoteReader.read(from: Data()) == nil)
    }
}
