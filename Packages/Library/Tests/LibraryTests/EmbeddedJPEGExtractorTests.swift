import Containers
import Foundation
import Testing
@testable import Library

private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
private func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }

/// A small JPEG, with or without an Exif orientation.
private func jpeg(width: Int, height: Int, exifOrientation: UInt16? = nil) -> Data {
    var d = Data([0xFF, 0xD8])
    if let o = exifOrientation {
        let body = Data("Exif\0\0".utf8) + Data("MM".utf8) + Data([0, 42, 0, 0, 0, 8])
            + Data([0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, UInt8(o >> 8), UInt8(o & 0xFF), 0, 0, 0, 0, 0, 0])
        d += Data([0xFF, 0xE1, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)]) + body
    }
    d += Data([0xFF, 0xC0, 0, 11, 8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 1, 1, 0x11, 0])
    d += Data([0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0x12, 0x34, 0xFF, 0xD9])
    return d
}

/// A TIFF-based "RAW": IFD0 holds the orientation, IFD1 points at `preview`.
private func fakeRaw(orientation: UInt16, preview: Data) -> Data {
    var d = Data("II".utf8) + Data([42, 0, 8, 0, 0, 0])
    // IFD0 at 8: one entry (orientation), next-IFD = 8 + 2 + 12 + 4 = 26.
    d += le16(1) + le16(0x0112) + le16(3) + le32(1) + le16(orientation) + Data([0, 0]) + le32(26)
    // IFD1 at 26: two entries, then the blob at 26 + 2 + 24 + 4 = 56.
    d += le16(2) + le16(0x0201) + le16(4) + le32(1) + le32(56) + le16(0x0202) + le16(4) + le32(1) + le32(UInt32(preview.count)) + le32(0)
    d += preview
    return d
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("extract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func exactBytesCopiesTheEmbeddedStreamUnchanged() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let preview = jpeg(width: 160, height: 120)
    let source = dir.appendingPathComponent("A.ARW")
    try fakeRaw(orientation: 6, preview: preview).write(to: source)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try EmbeddedJPEGExtractor.extract(source, into: out, exactBytes: true)
    #expect(result.output.lastPathComponent == "A.jpg")
    #expect(!result.exifAdded)
    #expect(try Data(contentsOf: result.output) == preview)
}

@Test func defaultAddsOrientationAndKeepsTheImageData() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let preview = jpeg(width: 160, height: 120)
    let source = dir.appendingPathComponent("A.ARW")
    try fakeRaw(orientation: 6, preview: preview).write(to: source)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try EmbeddedJPEGExtractor.extract(source, into: out)
    #expect(result.exifAdded)
    let data = try Data(contentsOf: result.output)
    let header = try #require(JPEGHeader.parse(ByteReader(data: data), at: 0))
    #expect(header.exifOrientation == 6)
    #expect(data.suffix(preview.count - 2) == preview.suffix(preview.count - 2))
}

@Test func aPreviewWithItsOwnExifIsLeftAlone() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let preview = jpeg(width: 160, height: 120, exifOrientation: 8)
    let source = dir.appendingPathComponent("A.ARW")
    try fakeRaw(orientation: 6, preview: preview).write(to: source)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try EmbeddedJPEGExtractor.extract(source, into: out)
    #expect(!result.exifAdded)
    #expect(try Data(contentsOf: result.output) == preview)
}

@Test func takenNamesGetASuffixAndNothingIsOverwritten() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("IMG_1.ARW"), b = dir.appendingPathComponent("IMG_1.NEF")
    try fakeRaw(orientation: 1, preview: jpeg(width: 160, height: 120)).write(to: a)
    try fakeRaw(orientation: 1, preview: jpeg(width: 320, height: 240)).write(to: b)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }
    let existing = out.appendingPathComponent("IMG_1.jpg")
    try Data("mine".utf8).write(to: existing)

    let summary = EmbeddedJPEGExtractor.run([a, b], into: out, exactBytes: true)
    #expect(summary.written == 2)
    #expect(summary.renamed.map(\.detail) == ["IMG_1-1.jpg", "IMG_1-2.jpg"])
    #expect(try Data(contentsOf: existing) == Data("mine".utf8))
}

@Test func summaryListsFilesWithoutAJPEGAndNonRawOriginals() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let none = dir.appendingPathComponent("B.ARW"), camera = dir.appendingPathComponent("C.JPG"), missing = dir.appendingPathComponent("D.ARW")
    try Data("not an image".utf8).write(to: none)
    try jpeg(width: 10, height: 10).write(to: camera)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let summary = EmbeddedJPEGExtractor.run([none, camera, missing], into: out)
    #expect(summary.written == 0)
    #expect(summary.withoutEmbeddedJPEG == ["B.ARW"])
    #expect(summary.notRaw == ["C.JPG"])
    #expect(summary.failed.map(\.name) == ["D.ARW"])
    #expect(summary.hasProblems)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
}

@Test func cancelStopsBetweenFilesAndLeavesNoTemporaryFile() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    var sources: [URL] = []
    for i in 0..<5 {
        let url = dir.appendingPathComponent("F\(i).ARW")
        try fakeRaw(orientation: 1, preview: jpeg(width: 160, height: 120)).write(to: url)
        sources.append(url)
    }
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }
    var done = 0
    let summary = EmbeddedJPEGExtractor.run(sources, into: out, exactBytes: true, progress: { done = $0 }, isCancelled: { done >= 2 })
    #expect(summary.cancelled)
    #expect(summary.written == 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["F0.jpg", "F1.jpg"])
}
