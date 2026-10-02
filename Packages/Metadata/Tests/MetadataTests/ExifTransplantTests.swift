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
}
