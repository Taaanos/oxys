import Containers
import Foundation
import Testing
@testable import Metadata

/// V-13: the RAW's Exif is carried into the extracted JPEG's APP1 segment.
@Suite struct ExifTransplantTests {
    let le = TIFFFixture()

    private func sonyRaw(make: String = "SONY", note: Bool = true) -> Data {
        le.file(make: make, orientation: 6,
                exif: [le.ascii(0xA434, "Viltrox 20mm F2.8 FE"), le.ascii(0x9003, "2026:09:30 14:05:09"),
                       le.longs(0xA002, [7008]), le.longs(0xA003, [4672]), le.rationals(0x829A, [(1, 250)])],
                ifd0Extra: [le.longs(0x0111, [123_456]), le.longs(0x0100, [7008]), le.ascii(0x0110, "ZV-1"), le.ascii(0x8298, "Me")],
                note: note ? { position in
                    Array("SONY DSC ".utf8) + [0, 0, 0] + le.ifd([le.shorts(0x2027, [7008, 4672, 3810, 2423])], origin: position + 12, base: 0).bytes
                } : nil)
    }

    private func exifIFD(_ ifd0: TIFFDirectory) throws -> TIFFDirectory {
        let at = try #require(ifd0.integers(0x8769).first)
        return try #require(TIFFDirectory(reader: ifd0.reader, at: at, base: 0))
    }

    private func tiff(_ r: ExifTransplant.Result) -> Data { Data(r.segment.dropFirst(10)) }

    @Test func keepsDescriptiveTagsAndDropsWhatDescribesTheRAW() throws {
        let r = try #require(ExifTransplant.segment(fromRAW: sonyRaw(), previewWidth: 1616, previewHeight: 1080, orientation: 8))
        let ifd0 = try #require(TIFFDirectory.firstDirectory(in: tiff(r), at: 0))
        #expect(ifd0.string(0x010F) == "SONY" && ifd0.string(0x0110) == "ZV-1" && ifd0.string(0x8298) == "Me")
        #expect(ifd0.integers(0x0112) == [8])
        #expect(ifd0.entry(0x0111) == nil && ifd0.entry(0x0100) == nil)
        let exif = try exifIFD(ifd0)
        #expect(exif.string(0xA434) == "Viltrox 20mm F2.8 FE" && exif.string(0x9003) == "2026:09:30 14:05:09")
        #expect(exif.rationals(0x829A) == [1.0 / 250])
        #expect(exif.integers(0xA002) == [1616] && exif.integers(0xA003) == [1080])   // the preview's size, not the RAW's
    }

    @Test func sonyMakerNoteIsMovedAndStillReads() throws {
        let r = try #require(ExifTransplant.segment(fromRAW: sonyRaw(), previewWidth: 1616, previewHeight: 1080, orientation: 6))
        #expect(r.hadMakerNote && r.makerNoteCopied)
        let info = try #require(MakerNoteReader.read(from: tiff(r)))
        let p = try #require(info.afPoints.first)
        #expect(abs(p.x - 3810.0 / 7008) < 1e-9 && abs(p.y - 2423.0 / 4672) < 1e-9)
        #expect(info.lens == "Viltrox 20mm F2.8 FE")
    }

    @Test func aBrandWhoseNoteCannotBeMovedKeepsEverythingElse() throws {
        let r = try #require(ExifTransplant.segment(fromRAW: sonyRaw(make: "ACME"), previewWidth: 100, previewHeight: 100, orientation: nil))
        #expect(r.hadMakerNote && !r.makerNoteCopied)
        let ifd0 = try #require(TIFFDirectory.firstDirectory(in: tiff(r), at: 0))
        let exif = try exifIFD(ifd0)
        #expect(exif.entry(0x927C) == nil)
        #expect(exif.string(0x9003) == "2026:09:30 14:05:09")
        #expect(ifd0.entry(0x0112) == nil)
    }

    @Test func aFileWithoutExifIsRefused() {
        #expect(ExifTransplant.segment(fromRAW: Data("not a raw".utf8), previewWidth: 1, previewHeight: 1, orientation: 1) == nil)
    }

    // MARK: V-22, remove location and serial numbers

    /// A RAW whose IFD0 holds a camera serial (DNG tag `0xC62F`), whose Exif IFD holds the owner name, the body and lens
    /// serial numbers, the image unique ID and a maker note, and whose GPS IFD holds a position.
    private func rawWithPrivateFields() -> Data {
        func ifd0(exif: Int, gps: Int) -> [TIFFFixture.Entry] {
            [le.ascii(0x010F, "SONY"), le.ascii(0x0110, "ZV-1"), le.ascii(0xC62F, "CAM123"), le.ascii(0x8298, "Me"),
             le.longs(0x8769, [exif]), le.longs(0x8825, [gps])]
        }
        let exif = [le.ascii(0x9003, "2026:09:30 14:05:09"), le.ascii(0xA434, "Viltrox 20mm F2.8 FE"), le.ascii(0xA430, "Jane Doe"),
                    le.ascii(0xA431, "BODY999"), le.ascii(0xA435, "LENS777"), le.ascii(0xA420, "UNIQUE1"),
                    le.blob(0x927C, Array("SONY DSC ".utf8) + [0, 0, 0] + le.ifd([le.shorts(0x2027, [1, 2, 3, 4])], origin: 0, base: 0).bytes)]
        let gps = [le.ascii(0x0001, "N"), le.rationals(0x0002, [(47, 1), (49, 1), (18, 1)])]
        let exifAt = 8 + le.ifd(ifd0(exif: 0, gps: 0), origin: 8, base: 0).bytes.count
        let gpsAt = exifAt + le.ifd(exif, origin: exifAt, base: 0).bytes.count
        return Data(le.header + le.ifd(ifd0(exif: exifAt, gps: gpsAt), origin: 8, base: 0).bytes
                    + le.ifd(exif, origin: exifAt, base: 0).bytes + le.ifd(gps, origin: gpsAt, base: 0).bytes)
    }

    @Test func withoutTheSwitchTheLocationAndTheSerialNumbersTravel() throws {
        let r = try #require(ExifTransplant.segment(fromRAW: rawWithPrivateFields(), previewWidth: 100, previewHeight: 100, orientation: 1))
        let ifd0 = try #require(TIFFDirectory.firstDirectory(in: tiff(r), at: 0))
        #expect(ifd0.entry(0xC62F) != nil && ifd0.entry(0x8825) != nil)
        let exif = try exifIFD(ifd0)
        for tag: UInt16 in [0xA430, 0xA431, 0xA435, 0xA420] { #expect(exif.entry(tag) != nil) }
        #expect(r.hadMakerNote)
    }

    @Test func theSwitchTakesOutEveryPrivateTagAndTheMakerNoteAndKeepsTheRest() throws {
        let r = try #require(ExifTransplant.segment(fromRAW: rawWithPrivateFields(), previewWidth: 100, previewHeight: 100,
                                                    orientation: 1, removePrivate: true))
        let ifd0 = try #require(TIFFDirectory.firstDirectory(in: tiff(r), at: 0))
        #expect(ifd0.entry(0xC62F) == nil)      // camera serial
        #expect(ifd0.entry(0x8825) == nil)      // GPS IFD pointer
        let exif = try exifIFD(ifd0)
        for tag: UInt16 in [0xA430, 0xA431, 0xA435, 0xA420, 0x927C] { #expect(exif.entry(tag) == nil, "tag \(tag)") }
        // What describes the photo, and the credit the photographer chose, stays.
        #expect(ifd0.string(0x010F) == "SONY" && ifd0.string(0x0110) == "ZV-1" && ifd0.string(0x8298) == "Me")
        #expect(exif.string(0x9003) == "2026:09:30 14:05:09" && exif.string(0xA434) == "Viltrox 20mm F2.8 FE")
        // No private text is left in the bytes, whatever IFD it was in.
        for text in ["Jane Doe", "BODY999", "LENS777", "UNIQUE1", "CAM123"] { #expect(r.segment.range(of: Data(text.utf8)) == nil) }
        // A note that is left out on purpose is not a note that failed.
        #expect(!r.hadMakerNote && !r.makerNoteCopied)
    }

    @Test func aJPEGsOwnExifGetsTheSameCleanUp() throws {
        let raw = rawWithPrivateFields()
        let length = 2 + 6 + raw.count
        let segment = Data([0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + Data("Exif\0\0".utf8) + raw
        let r = try #require(ExifTransplant.segment(fromExifSegment: segment, previewWidth: 100, previewHeight: 100,
                                                    orientation: 1, removePrivate: true))
        let ifd0 = try #require(TIFFDirectory.firstDirectory(in: tiff(r), at: 0))
        #expect(ifd0.entry(0x8825) == nil && ifd0.entry(0xC62F) == nil)
        #expect(try exifIFD(ifd0).entry(0xA431) == nil)
        #expect(ExifTransplant.segment(fromExifSegment: Data("short".utf8), previewWidth: 1, previewHeight: 1, orientation: 1) == nil)
    }
}
