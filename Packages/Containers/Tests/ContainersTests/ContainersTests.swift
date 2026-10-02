import Foundation
import Testing
@testable import Containers

// MARK: - Synthetic file builders (no camera files are committed)

/// A minimal JPEG: SOI, optional Exif orientation, optional ICC marker, SOF0, SOS, EOI.
private func makeJPEG(width: Int, height: Int, orientation: UInt16? = nil, icc: Bool = false, sof: UInt8 = 0xC0) -> Data {
    var d = Data([0xFF, 0xD8])
    if let orientation {
        var tiff = Data("MM".utf8) + Data([0, 42, 0, 0, 0, 8])
        tiff += Data([0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, UInt8(orientation >> 8), UInt8(orientation & 0xFF), 0, 0, 0, 0, 0, 0])
        let body = Data("Exif\0\0".utf8) + tiff
        d += Data([0xFF, 0xE1, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)]) + body
    }
    if icc {
        let body = Data("ICC_PROFILE\0".utf8) + Data([1, 1, 0, 0])
        d += Data([0xFF, 0xE2, 0, UInt8(body.count + 2)]) + body
    }
    d += Data([0xFF, sof, 0, 11, 8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 1, 1, 0x11, 0])
    d += Data([0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0x12, 0x34, 0xFF, 0xD9])
    return d
}

private struct TIFFBuilder {
    struct Entry { var tag: UInt16; var type: UInt16 = 4; var value: UInt32 }
    var data = Data("II".utf8) + Data([42, 0, 8, 0, 0, 0])   // little-endian, first IFD at 8

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }

    /// Writes an IFD at the current end of the data; returns its offset. `next` links the chain.
    mutating func appendIFD(_ entries: [Entry], next: UInt32 = 0) -> Int {
        let offset = data.count
        data += le16(UInt16(entries.count))
        for e in entries.sorted(by: { $0.tag < $1.tag }) {
            data += le16(e.tag) + le16(e.type) + le32(1) + (e.type == 3 ? le16(UInt16(e.value)) + Data([0, 0]) : le32(e.value))
        }
        data += le32(next)
        return offset
    }

    mutating func appendBlob(_ blob: Data) -> Int {
        let offset = data.count
        data += blob
        return offset
    }

    mutating func patch32(at offset: Int, _ v: UInt32) { data.replaceSubrange(offset..<offset + 4, with: le32(v)) }
}

// MARK: - TIFF

@Test func tiffFindsJPEGInterchangeFormatInIFD1() throws {
    var t = TIFFBuilder()
    let thumb = makeJPEG(width: 160, height: 120)
    // IFD0 is placed first; IFD1 and its blob follow, so IFD0's next pointer is patched afterwards.
    let ifd0 = t.appendIFD([.init(tag: 0x0112, type: 3, value: 6)])
    let blob = t.appendBlob(thumb)
    let ifd1 = t.appendIFD([.init(tag: 0x0201, value: UInt32(blob)), .init(tag: 0x0202, value: UInt32(thumb.count))])
    t.patch32(at: ifd0 + 2 + 12, UInt32(ifd1))   // IFD0's next-IFD pointer follows its single entry

    let found = try #require(TIFFPreviewLocator.locate(in: t.data))
    #expect(found.previews.count == 1)
    let p = try #require(found.previews.first)
    #expect(p.location == "IFD1")
    #expect(p.width == 160 && p.height == 120)
    #expect(p.offset == blob && p.length == thumb.count)
    #expect(found.info.orientation == 6)
}

@Test func tiffSkipsRawSamplesMasksAndTiledJPEG() throws {
    var t = TIFFBuilder()
    let preview = makeJPEG(width: 1024, height: 683, orientation: 8, icc: true)
    let mask = makeJPEG(width: 32, height: 32)

    // Build SubIFDs first, then IFD0 pointing at them through a SubIFDs array stored out of line.
    let previewBlob = t.appendBlob(preview)
    let maskBlob = t.appendBlob(mask)
    let sub0 = t.appendIFD([   // CFA raw, tiled lossless JPEG
        .init(tag: 0x0103, type: 3, value: 7), .init(tag: 0x0106, type: 3, value: 32803), .init(tag: 0x0142, value: 256),
        .init(tag: 0x0111, value: UInt32(previewBlob)), .init(tag: 0x0117, value: UInt32(preview.count)),
    ])
    let sub1 = t.appendIFD([   // reduced-resolution JPEG preview
        .init(tag: 0x00FE, value: 1), .init(tag: 0x0103, type: 3, value: 7), .init(tag: 0x0106, type: 3, value: 6),
        .init(tag: 0x0111, value: UInt32(previewBlob)), .init(tag: 0x0117, value: UInt32(preview.count)),
    ])
    let sub2 = t.appendIFD([   // Apple-style semantic mask: JPEG-compressed but not a picture
        .init(tag: 0x00FE, value: 4), .init(tag: 0x0103, type: 3, value: 34892), .init(tag: 0x0106, type: 3, value: 52527),
        .init(tag: 0x0111, value: UInt32(maskBlob)), .init(tag: 0x0117, value: UInt32(mask.count)),
    ])
    let array = t.data.count
    for o in [sub0, sub1, sub2] { t.data += Data([UInt8(o & 0xFF), UInt8((o >> 8) & 0xFF), UInt8((o >> 16) & 0xFF), 0]) }
    let ifd0 = t.appendIFD([.init(tag: 0x014A, type: 4, value: UInt32(array))])
    // Point the header at IFD0 and give the SubIFDs entry count 3.
    t.patch32(at: 4, UInt32(ifd0))
    t.patch32(at: ifd0 + 2 + 4, 3)   // the entry's count field

    let found = try #require(TIFFPreviewLocator.locate(in: t.data))
    #expect(found.previews.map(\.location) == ["SubIFD1"])
    #expect(found.previews.first?.header.hasICCProfile == true)
    #expect(found.previews.first?.header.exifOrientation == 8)
    #expect(found.skipped.map(\.location) == ["SubIFD", "SubIFD2"])
    #expect(found.skipped.map(\.reason) == ["raw samples", "semantic mask"])
}

@Test func tiffRejectsGarbageAndTruncation() {
    #expect(TIFFPreviewLocator.locate(in: Data()) == nil)
    #expect(TIFFPreviewLocator.locate(in: Data("not a tiff".utf8)) == nil)
    // Header only, IFD offset past the end: no crash, no previews.
    let truncated = Data("II".utf8) + Data([42, 0, 0xFF, 0xFF, 0, 0])
    #expect(TIFFPreviewLocator.locate(in: truncated)?.previews.isEmpty == true)
}

@Test func tiffIFDLoopTerminates() {
    // IFD0 whose next pointer points back at itself.
    var t = TIFFBuilder()
    let ifd0 = t.appendIFD([])
    t.patch32(at: ifd0 + 2, UInt32(ifd0))
    #expect(TIFFPreviewLocator.locate(in: t.data)?.previews.isEmpty == true)
}

@Test func previewChoice() {
    func p(_ loc: String, _ w: Int, _ h: Int) -> EmbeddedJPEG {
        EmbeddedJPEG(location: loc, offset: 0, length: 1, width: w, height: h, containerOrientation: nil,
                     header: JPEGHeader(width: w, height: h, componentCount: 3, sofMarker: 0xC0, hasICCProfile: false, hasExif: false, exifOrientation: nil, hasAdobeMarker: false))
    }
    let found = LocatedPreviews(format: "TIFF", info: ContainerInfo(),
                                previews: [p("IFD1", 160, 120), p("IFD0", 1616, 1080), p("IFD2", 7008, 4672)], skipped: [])
    #expect(found.largest?.location == "IFD2")
    #expect(found.smallestAdequate(longEdge: 320)?.location == "IFD0")
    #expect(found.smallestAdequate(longEdge: 100)?.location == "IFD1")
    #expect(found.smallestAdequate(longEdge: 99999)?.location == "IFD2")   // nothing big enough: fall back to the largest
}

// MARK: - JPEG header

@Test func jpegHeaderReadsSizeIccAndOrientation() throws {
    let data = makeJPEG(width: 4032, height: 3024, orientation: 6, icc: true)
    let h = try #require(JPEGHeader.parse(ByteReader(data: data), at: 0))
    #expect(h.width == 4032 && h.height == 3024 && h.componentCount == 1)
    #expect(h.hasICCProfile && h.hasExif && h.exifOrientation == 6)
    #expect(JPEGHeader.parse(ByteReader(data: Data([1, 2, 3])), at: 0) == nil)
}

// MARK: - RAF and CR3

@Test func rafHeaderOffsets() throws {
    let jpeg = makeJPEG(width: 6000, height: 4000, orientation: 1)
    var raf = Data("FUJIFILMCCD-RAW ".utf8) + Data(repeating: 0, count: 0x54 - 16)
    let offset = 0x100
    for v in [offset, jpeg.count] { raf += Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    raf += Data(repeating: 0, count: offset - raf.count) + jpeg
    let found = try #require(RAFPreviewLocator.locate(in: raf))
    #expect(found.previews.first?.offset == offset && found.previews.first?.length == jpeg.count)
    #expect(found.previews.first?.width == 6000)
}

@Test func cr3FindsPRVWInCanonUUIDBox() throws {
    func box(_ type: String, _ payload: Data) -> Data {
        let size = UInt32(payload.count + 8)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)]) + Data(type.utf8) + payload
    }
    let jpeg = makeJPEG(width: 1620, height: 1080)
    let uuid = Data([0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88, 0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16])
    let prvw = box("PRVW", Data(repeating: 0, count: 12) + jpeg)
    // Real files put 8 bytes (version, count) between the UUID and the child boxes.
    let file = box("ftyp", Data("crx ".utf8) + Data(repeating: 0, count: 8)) + box("uuid", uuid + Data([0, 0, 0, 0, 0, 0, 0, 1]) + prvw)
    let found = try #require(CR3PreviewLocator.locate(in: file))
    let p = try #require(found.previews.first)
    #expect(p.location == "PRVW" && p.width == 1620)
    #expect(PreviewLocator.bytes(of: p, in: file) == jpeg)
}

@Test func cr3FindsFullSizeJPEGThroughTrackSampleTables() throws {
    func be32(_ v: Int) -> Data { Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    func box(_ type: String, _ payload: Data) -> Data { be32(payload.count + 8) + Data(type.utf8) + payload }
    let jpeg = makeJPEG(width: 4320, height: 2880)
    let head = box("ftyp", Data("crx ".utf8) + Data(repeating: 0, count: 8))
    // moov size depends on the co64 offset, which depends on moov size: build once to measure.
    func moov(offset: Int) -> Data {
        let stsz = box("stsz", Data(repeating: 0, count: 4) + be32(jpeg.count) + be32(1))
        let co64 = box("co64", Data(repeating: 0, count: 4) + be32(1) + be32(0) + be32(offset))
        return box("moov", box("trak", box("mdia", box("minf", box("stbl", stsz + co64)))))
    }
    let offset = head.count + moov(offset: 0).count
    let file = head + moov(offset: offset) + jpeg
    let found = try #require(CR3PreviewLocator.locate(in: file))
    let p = try #require(found.previews.first)
    #expect(p.location == "Track1" && p.width == 4320 && p.offset == offset && p.length == jpeg.count)
}

@Test func losslessJPEGIsNotAPreview() throws {
    let raw = makeJPEG(width: 5184, height: 3456, sof: 0xC3)
    let h = try #require(JPEGHeader.parse(ByteReader(data: raw), at: 0))
    #expect(h.isLossless)
    #expect(try #require(JPEGHeader.parse(ByteReader(data: makeJPEG(width: 8, height: 8)), at: 0)).isLossless == false)

    // A CR2-style IFD whose JPEG-compressed strip is the raw: located but skipped.
    var t = TIFFBuilder()
    let blob = t.appendBlob(raw)
    let ifd = t.appendIFD([.init(tag: 0x0103, type: 3, value: 6), .init(tag: 0x0111, value: UInt32(blob)), .init(tag: 0x0117, value: UInt32(raw.count))])
    t.patch32(at: 4, UInt32(ifd))
    let found = try #require(TIFFPreviewLocator.locate(in: t.data))
    #expect(found.previews.isEmpty)
    #expect(found.skipped.map(\.reason) == ["lossless JPEG (raw data)"])
}

@Test func hostileSizesDoNotTrap() {
    func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    let ftyp = be32(24) + Data("ftyp".utf8) + Data("crx ".utf8) + Data(repeating: 0, count: 12)
    // 64-bit largesize of UInt64.max, then a trak whose co64 offset is UInt64.max.
    let huge = be32(1) + Data("free".utf8) + Data(repeating: 0xFF, count: 8)
    #expect(CR3PreviewLocator.locate(in: ftyp + huge) == nil)

    func box(_ type: String, _ payload: Data) -> Data { be32(UInt32(payload.count + 8)) + Data(type.utf8) + payload }
    let stsz = box("stsz", Data(repeating: 0, count: 4) + be32(0xFFFF_FFFF) + be32(1))
    let co64 = box("co64", Data(repeating: 0, count: 4) + be32(1) + Data(repeating: 0xFF, count: 8))
    let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsz + co64)))))
    #expect(CR3PreviewLocator.locate(in: ftyp + moov) == nil)
}

// MARK: - JPEG Exif interoperability

@Test func jpegHeaderReadsInteropIndexFromItsOwnExif() throws {
    // Little-endian TIFF: IFD0 {ExifIFD → 26}, Exif IFD {InteropIFD → 44}, Interop IFD {index "R03"}.
    func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    func le32(_ v: UInt32) -> Data { le16(UInt16(v & 0xFFFF)) + le16(UInt16(v >> 16)) }
    var tiff = Data("II".utf8) + le16(42) + le32(8)
    tiff += le16(1) + le16(0x8769) + le16(4) + le32(1) + le32(26) + le32(0)          // IFD0 at 8, 18 bytes
    tiff += le16(1) + le16(0xA005) + le16(4) + le32(1) + le32(44) + le32(0)          // Exif IFD at 26
    tiff += le16(1) + le16(0x0001) + le16(2) + le32(4) + Data("R03\0".utf8) + le32(0) // Interop IFD at 44
    let body = Data("Exif\0\0".utf8) + tiff
    var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)]) + body
    jpeg += Data([0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0xFF, 0xD9])
    let header = try #require(JPEGHeader.parse(ByteReader(data: jpeg), at: 0))
    #expect(header.exifInteropIndex == "R03")
    #expect(header.width == 8)
}

// MARK: - Exif segment (V-13)

@Test func exifSegmentRoundTripsThroughTheHeaderReader() throws {
    let jpeg = makeJPEG(width: 160, height: 120)
    let segment = try #require(ExifSegment.build(.init(make: "SONY", model: "ZV-1", orientation: 6, dateTimeOriginal: "2026:10:02 12:35:49")))
    let out = try #require(ExifSegment.insert(segment, into: jpeg))
    let header = try #require(JPEGHeader.parse(ByteReader(data: out), at: 0))
    #expect(header.hasExif)
    #expect(header.exifOrientation == 6)
    #expect(header.width == 160 && header.height == 120)
    // Only a segment was added: the rest of the stream is the same bytes.
    #expect(out.count == jpeg.count + segment.count)
    #expect(out.suffix(jpeg.count - 2) == jpeg.suffix(jpeg.count - 2))
}

@Test func exifSegmentNeedsSomethingToSayAndFitsTheMarker() throws {
    #expect(ExifSegment.build(.init()) == nil)
    #expect(ExifSegment.build(.init(orientation: 9)) == nil)
    #expect(ExifSegment.build(.init(make: String(repeating: "x", count: 70_000))) == nil)
}

@Test func exifIsInsertedAfterJFIFAndRefusesNonJPEG() throws {
    let jfif = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0x4A, 0x46, 0xFF, 0xDA, 0, 2, 0xFF, 0xD9])
    let segment = try #require(ExifSegment.build(.init(orientation: 3)))
    let out = try #require(ExifSegment.insert(segment, into: jfif))
    #expect(out.prefix(8) == jfif.prefix(8))
    #expect(out.dropFirst(8).prefix(segment.count) == segment)
    #expect(ExifSegment.insert(segment, into: Data("not a jpeg".utf8)) == nil)
}

@Test func rewritingReplacesExifAddsXMPAndKeepsTheRest() throws {
    let jpeg = makeJPEG(width: 160, height: 120, orientation: 8, icc: true)
    let exif = try #require(ExifSegment.build(.init(make: "SONY", orientation: 6)))
    let xmp = try #require(JPEGSegments.xmpSegment(Data("<x:xmpmeta/>".utf8)))
    let out = try #require(JPEGSegments.rewriting(jpeg, exif: exif, xmp: xmp))
    let header = try #require(JPEGHeader.parse(ByteReader(data: out), at: 0))
    #expect(header.exifOrientation == 6)          // the old Exif is gone, the new one is in
    #expect(header.hasICCProfile)
    let segments = try #require(JPEGSegments.list(out))
    #expect(segments.filter(\.isExif).count == 1)
    #expect(segments.filter(\.isXMP).count == 1)
    // Scan data (after the last segment) is the original's.
    #expect(out.suffix(14) == jpeg.suffix(14))
    // A JPEG with XMP keeps its own.
    let again = try #require(JPEGSegments.rewriting(out, exif: nil, xmp: xmp))
    #expect(try #require(JPEGSegments.list(again)).filter(\.isXMP).count == 1)
    #expect(JPEGSegments.xmpSegment(Data(count: 70_000)) == nil)
}
